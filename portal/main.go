// ============================================================================
// xui-portal —— 8080 节点门户（单文件、零第三方依赖、可静态编译）
// ----------------------------------------------------------------------------
// 职责：
//   1. 从 3x-ui 面板 API 拉取节点信息，渲染成客户可自助使用的门户页
//   2. 把 /sub/ /json/ /clash/ 反代到 3x-ui 订阅服务（客户端订阅统一走 8080）
//   3. 提供 8+ 客户端的 URL Scheme 一键导入
//
// 编译：CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o xui-portal .
// ============================================================================
package main

import (
	"crypto/rand"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"html/template"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed web/index.html
var webFS embed.FS

// ---------------------------------------------------------------- 配置
type Config struct {
	Listen      string `json:"listen"`      // ":8080"
	Panel       string `json:"panel"`       // "http://127.0.0.1:2053"
	BasePath    string `json:"basePath"`    // "/"
	APIToken    string `json:"apiToken"`    // 3x-ui Bearer token
	PublicHost  string `json:"publicHost"`  // "1.2.3.4" 或域名
	PortalToken string `json:"portalToken"` // 访问路径令牌
	SubUpstream string `json:"subUpstream"` // "http://127.0.0.1:2096"
	FixedSubID  string `json:"fixedSubId"`  // 主订阅 ID（为空则取第一个节点）
	Brand       string `json:"brand"`       // 页面标题
	Open        bool   `json:"open"`        // true = 不需要 /p/<token>
}

var (
	cfg     Config
	version = "dev"
)

// ---------------------------------------------------------------- 3x-ui 模型
type ClientStat struct {
	Email      string `json:"email"`
	Up         int64  `json:"up"`
	Down       int64  `json:"down"`
	Total      int64  `json:"total"`
	ExpiryTime int64  `json:"expiryTime"`
	Enable     bool   `json:"enable"`
}

type Inbound struct {
	ID          int             `json:"id"`
	Remark      string          `json:"remark"`
	Protocol    string          `json:"protocol"`
	Port        int             `json:"port"`
	Enable      bool            `json:"enable"`
	Settings    json.RawMessage `json:"settings"`
	Stream      json.RawMessage `json:"streamSettings"`
	ClientStats []ClientStat    `json:"clientStats"`
}

type apiEnvelope struct {
	Success bool            `json:"success"`
	Msg     string          `json:"msg"`
	Obj     json.RawMessage `json:"obj"`
}

type settingsShape struct {
	Clients []struct {
		Email string `json:"email"`
		SubID string `json:"subId"`
		ID    string `json:"id"`
	} `json:"clients"`
}

// decodeSettings 兼容两种 payload：settings 为对象，或为 JSON 字符串
// （3x-ui 的 model.Inbound.Settings 是 string，但 UnmarshalJSON 两种都吃）
func decodeSettings(raw json.RawMessage) settingsShape {
	var st settingsShape
	if len(raw) == 0 {
		return st
	}
	if raw[0] == '"' {
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			return st
		}
		_ = json.Unmarshal([]byte(s), &st)
		return st
	}
	_ = json.Unmarshal(raw, &st)
	return st
}

// ---------------------------------------------------------------- 视图模型
type NodeView struct {
	Remark   string
	Protocol string
	Port     int
	Host     string
	Link     string
	LinkSafe template.URL
	Badge    string
	Kind     string
	QR       string
}

type AppView struct {
	Name   string
	Scheme template.URL
	Note   string
	Abbr   string
}

type PageData struct {
	Brand      string
	Host       string
	PortalPath string
	Nodes      []NodeView
	Apps       []AppView
	SubURL     string
	ClashURL   string
	JSONURL    string
	SubQR      string
	ClashQR    string
	Used       string
	Total      string
	Expire     string
	Up         string
	Down       string
	Online     bool
	Now        string
}

// ---------------------------------------------------------------- 工具
func apiURL(path string) string {
	base := strings.TrimRight(cfg.Panel, "/")
	bp := cfg.BasePath
	if bp == "" || bp == "/" {
		return fmt.Sprintf("%s/panel/api/%s", base, path)
	}
	return fmt.Sprintf("%s%s/panel/api/%s", base, strings.Trim(bp, "/"), path)
}

var httpc = &http.Client{Timeout: 8 * time.Second}

func panelGET(path string, out any) error {
	req, err := http.NewRequest(http.MethodGet, apiURL(path), nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+cfg.APIToken)
	req.Header.Set("Accept", "application/json")
	resp, err := httpc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("panel api %s: http %d %s", path, resp.StatusCode, truncate(string(body), 200))
	}
	var env apiEnvelope
	if err := json.Unmarshal(body, &env); err != nil {
		return err
	}
	if !env.Success {
		return fmt.Errorf("panel api %s: %s", path, env.Msg)
	}
	if out == nil {
		return nil
	}
	return json.Unmarshal(env.Obj, out)
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

func humanBytes(b int64) string {
	if b <= 0 {
		return "0 B"
	}
	units := []string{"B", "KB", "MB", "GB", "TB", "PB"}
	div := int64(1)
	exp := 0
	for b/div >= 1024 && exp < len(units)-1 {
		div *= 1024
		exp++
	}
	return fmt.Sprintf("%.2f %s", float64(b)/float64(div), units[exp])
}

func b64(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }
func esc(s string) string { return url.QueryEscape(s) }

// frag 用于 URL fragment（# 之后）：空格必须是 %20，不能是 +
func frag(s string) string {
	return strings.ReplaceAll(url.QueryEscape(s), "+", "%20")
}

func qr(text string) string {
	return "https://api.qrserver.com/v1/create-qr-code/?size=220x220&margin=8&data=" + esc(text)
}

func protocolBadge(p string) string {
	switch strings.ToLower(p) {
	case "vless":
		return "VLESS"
	case "vmess":
		return "VMESS"
	case "trojan":
		return "TROJAN"
	case "shadowsocks":
		return "SS"
	case "hysteria":
		return "HY2"
	case "tuic":
		return "TUIC"
	case "wireguard":
		return "WG"
	case "mtproto":
		return "MTProto"
	default:
		return strings.ToUpper(p)
	}
}

// 从 share link 里取协议与备注
func splitLink(link string) (kind, remark string) {
	scheme := link
	if i := strings.Index(link, "://"); i > 0 {
		scheme = link[:i]
	}
	kind = scheme
	if i := strings.Index(link, "#"); i >= 0 {
		remark, _ = url.QueryUnescape(link[i+1:])
	}
	return
}

func hostFromLink(link string) string {
	// vless://uuid@host:port?...
	if i := strings.Index(link, "://"); i > 0 {
		rest := link[i+3:]
		if j := strings.Index(rest, "#"); j >= 0 {
			rest = rest[:j]
		}
		if j := strings.Index(rest, "?"); j >= 0 {
			rest = rest[:j]
		}
		if j := strings.LastIndex(rest, "@"); j >= 0 {
			rest = rest[j+1:]
		}
		return rest
	}
	return ""
}

func portFromHost(hp string) int {
	if i := strings.LastIndex(hp, ":"); i > 0 {
		if p, err := strconv.Atoi(hp[i+1:]); err == nil {
			return p
		}
	}
	return 0
}

// ---------------------------------------------------------------- 采样
type snapshot struct {
	Nodes    []NodeView
	SubID    string
	Up       int64
	Down     int64
	Total    int64
	Expire   int64
	UpStr    string
	DownStr  string
	UsedStr  string
	TotalStr string
	ExpireS  string
}

var (
	cacheMu   sync.RWMutex
	cacheSnap snapshot
	cacheAt   time.Time
)

const cacheTTL = 15 * time.Second

func loadSnapshot() (snapshot, error) {
	cacheMu.RLock()
	if time.Since(cacheAt) < cacheTTL && cacheSnap.SubID != "" {
		s := cacheSnap
		cacheMu.RUnlock()
		return s, nil
	}
	cacheMu.RUnlock()

	var inbounds []Inbound
	if err := panelGET("inbounds/list", &inbounds); err != nil {
		cacheMu.RLock()
		s := cacheSnap
		cacheMu.RUnlock()
		if s.SubID != "" {
			return s, nil // 面板短暂不可用时回退旧数据
		}
		return snapshot{}, err
	}

	var links []string
	_ = panelGET("inbounds/allLinks", &links)

	snap := snapshot{}
	seen := map[string]bool{}
	for _, l := range links {
		kind, remark := splitLink(l)
		if remark == "" {
			remark = strings.ToUpper(kind)
		}
		if seen[l] {
			continue
		}
		seen[l] = true
		hp := hostFromLink(l)
		snap.Nodes = append(snap.Nodes, NodeView{
			Remark:   remark,
			Protocol: kind,
			Badge:    protocolBadge(kind),
			Kind:     kind,
			Host:     hp,
			Port:     portFromHost(hp),
			Link:     l,
			LinkSafe: template.URL(l),
			QR:       qr(l),
		})
	}

	// 订阅 ID：优先配置里的 fixedSubId，否则取第一个节点的 subId
	snap.SubID = cfg.FixedSubID
	for _, ib := range inbounds {
		st := decodeSettings(ib.Settings)
		if snap.SubID == "" {
			for _, c := range st.Clients {
				if c.SubID != "" {
					snap.SubID = c.SubID
					break
				}
			}
		}
		// 流量汇总（同一 email 跨 inbound，逐个累加）
		for _, cs := range ib.ClientStats {
			snap.Up += cs.Up
			snap.Down += cs.Down
			if cs.Total > snap.Total {
				snap.Total = cs.Total
			}
			if cs.ExpiryTime > 0 && (snap.Expire == 0 || cs.ExpiryTime < snap.Expire) {
				snap.Expire = cs.ExpiryTime
			}
		}
	}

	snap.UpStr = humanBytes(snap.Up)
	snap.DownStr = humanBytes(snap.Down)
	snap.UsedStr = humanBytes(snap.Up + snap.Down)
	if snap.Total > 0 {
		snap.TotalStr = humanBytes(snap.Total)
	} else {
		snap.TotalStr = "不限"
	}
	if snap.Expire > 0 {
		snap.ExpireS = time.UnixMilli(snap.Expire).Format("2006-01-02")
	} else {
		snap.ExpireS = "长期有效"
	}

	cacheMu.Lock()
	cacheSnap = snap
	cacheAt = time.Now()
	cacheMu.Unlock()
	return snap, nil
}

// ---------------------------------------------------------------- 渲染
var tpl = template.Must(template.ParseFS(webFS, "web/index.html"))

func renderPortal(w http.ResponseWriter, r *http.Request, portalPath string) {
	snap, err := loadSnapshot()
	if err != nil {
		http.Error(w, "面板数据获取失败: "+err.Error(), http.StatusBadGateway)
		return
	}

	host := cfg.PublicHost
	subURL := fmt.Sprintf("http://%s%s/sub/%s", host, portalPortSuffix(), snap.SubID)
	clashURL := fmt.Sprintf("http://%s%s/clash/%s", host, portalPortSuffix(), snap.SubID)
	jsonURL := fmt.Sprintf("http://%s%s/json/%s", host, portalPortSuffix(), snap.SubID)
	name := cfg.Brand

	pd := PageData{
		Brand:      cfg.Brand,
		Host:       host,
		PortalPath: portalPath,
		Nodes:      snap.Nodes,
		SubURL:     subURL,
		ClashURL:   clashURL,
		JSONURL:    jsonURL,
		SubQR:      qr(subURL),
		ClashQR:    qr(clashURL),
		Used:       snap.UsedStr,
		Total:      snap.TotalStr,
		Expire:     snap.ExpireS,
		Up:         snap.UpStr,
		Down:       snap.DownStr,
		Online:     len(snap.Nodes) > 0,
		Now:        time.Now().Format("2006-01-02 15:04"),
	}

	// 客户端一键导入（scheme 来自 3x-ui 官方订阅页实现 + 社区通用值）
	add := func(name, scheme, note, abbr string) {
		pd.Apps = append(pd.Apps, AppView{Name: name, Scheme: template.URL(scheme), Note: note, Abbr: abbr})
	}
	add("v2rayNG", "v2rayng://install-config?url="+esc(subURL), "Android · Xray", "NG")
	add("V2Box", "v2box://install-sub?url="+esc(subURL)+"&name="+esc(name), "Android / iOS", "V2")
	add("Shadowrocket", "shadowrocket://add/sub://"+b64(subURL+"?flag=shadowrocket")+"?remark="+frag(name), "iOS · 小火箭", "SR")
	add("Sing-box", "sing-box://import-remote-profile?url="+esc(subURL)+"#"+frag(name), "iOS / macOS / Android", "SB")
	add("Streisand", "streisand://import/"+esc(subURL), "iOS / macOS", "ST")
	add("Happ", "happ://add/"+subURL, "iOS / Android / 桌面", "HP")
	add("V2RayTun", "v2raytun://import/"+subURL, "iOS / Android", "VT")
	add("Incy", "incy://add/"+subURL, "iOS / Android", "IN")
	add("Clash / Mihomo", "clash://install-config?url="+esc(clashURL), "Win / macOS / Android", "CL")
	add("Hiddify", "hiddify://install-config/?url="+esc(subURL), "全平台 · sing-box", "HD")
	add("Karing", "karing://install-config?url="+esc(subURL)+"&name="+esc(name), "全平台", "KR")
	add("NekoRay", "sn://subscription?url="+esc(subURL)+"&name="+esc(name), "Windows / Linux", "NK")

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	if err := tpl.Execute(w, pd); err != nil {
		log.Printf("render: %v", err)
	}
}

func portalPortSuffix() string {
	_, port, err := net.SplitHostPort(cfg.Listen)
	if err != nil || port == "" || port == "80" {
		return ""
	}
	return ":" + port
}

// ---------------------------------------------------------------- 反代
func newSubProxy(prefix, upstreamPath string) *httputil.ReverseProxy {
	target, err := url.Parse(cfg.SubUpstream)
	if err != nil {
		log.Fatalf("subUpstream 非法: %v", err)
	}
	p := httputil.NewSingleHostReverseProxy(target)
	orig := p.Director
	p.Director = func(r *http.Request) {
		orig(r)
		rest := strings.TrimPrefix(r.URL.Path, prefix)
		r.URL.Path = upstreamPath + rest
		r.Host = target.Host
		// 让 3x-ui 生成链接时拿到正确的对外地址
		r.Header.Set("X-Forwarded-Host", cfg.PublicHost+portalPortSuffix())
		r.Header.Set("X-Forwarded-Proto", "http")
		r.Header.Set("X-Real-IP", clientIP(r))
	}
	p.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		log.Printf("proxy %s: %v", r.URL.Path, err)
		http.Error(w, "subscription upstream unavailable", http.StatusBadGateway)
	}
	return p
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// ---------------------------------------------------------------- 路由
func main() {
	var cfgPath string
	flag.StringVar(&cfgPath, "config", "/etc/xui-onekey/portal.json", "配置文件路径")
	flag.Parse()

	raw, err := os.ReadFile(cfgPath)
	if err != nil {
		log.Fatalf("读取配置失败 %s: %v", cfgPath, err)
	}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		log.Fatalf("解析配置失败: %v", err)
	}
	if cfg.Listen == "" {
		cfg.Listen = ":8080"
	}
	if cfg.SubUpstream == "" {
		cfg.SubUpstream = "http://127.0.0.1:2096"
	}
	if cfg.Brand == "" {
		cfg.Brand = "NODE PORTAL"
	}
	if cfg.PortalToken == "" {
		b := make([]byte, 6)
		_, _ = rand.Read(b)
		cfg.PortalToken = hex.EncodeToString(b)
		log.Printf("未配置 portalToken，临时生成: %s", cfg.PortalToken)
	}

	mux := http.NewServeMux()

	// 订阅反代：/sub/<id> -> <upstream>/s/<id>
	mux.Handle("/sub/", newSubProxy("/sub/", "/s/"))
	mux.Handle("/json/", newSubProxy("/json/", "/json/"))
	mux.Handle("/clash/", newSubProxy("/clash/", "/clash/"))
	mux.Handle("/assets/", newSubProxy("/assets/", "/assets/"))

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	})

	// 门户页
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" || r.URL.Path == "" {
			if cfg.Open {
				renderPortal(w, r, "/")
				return
			}
			http.Redirect(w, r, "/p/"+cfg.PortalToken+"/", http.StatusFound)
			return
		}
		if cfg.Open {
			renderPortal(w, r, "/")
			return
		}
		want := "/p/" + cfg.PortalToken
		if r.URL.Path == want || r.URL.Path == want+"/" || r.URL.Path == want+"/index.html" {
			renderPortal(w, r, want+"/")
			return
		}
		// 未知路径不泄露信息
		http.NotFound(w, r)
	})

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           logging(mux),
		ReadHeaderTimeout: 10 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	log.Printf("xui-portal %s listening on %s (portal=/p/%s/, upstream=%s)", version, cfg.Listen, cfg.PortalToken, cfg.SubUpstream)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

func logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		// 订阅 URL 里含凭据，日志只记路径前缀
		path := r.URL.Path
		if i := strings.Index(path, "/sub/"); i == 0 {
			path = "/sub/***"
		}
		log.Printf("%s %s %s %s", clientIP(r), r.Method, path, time.Since(start).Round(time.Millisecond))
	})
}
