#!/usr/bin/env bash
# 交叉编译 8080 门户（无 CGO，多架构）
set -Eeuo pipefail
cd "$(dirname "$0")/../portal"
mkdir -p ../bin

VERSION="${VERSION:-$(date +%Y%m%d)}"
build_one() { # $1=goarch $2=goarm(可空) $3=输出名
  echo "[+] building linux/$3"
  CGO_ENABLED=0 GOOS=linux GOARCH="$1" GOARM="${2:-}" \
    go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" \
    -o "../bin/xui-portal-linux-$3" .
}
build_one amd64 ""    amd64
build_one arm64 ""    arm64
build_one arm   7     armv7
build_one 386   ""    386

# 顺手生成 sha256，install.sh 可以校验
( cd ../bin && shasum -a 256 xui-portal-linux-* 2>/dev/null || sha256sum xui-portal-linux-* ) > ../bin/SHA256SUMS
echo "[+] done: $(ls -1 ../bin | tr '\n' ' ')"
