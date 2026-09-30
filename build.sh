#!/bin/zsh
# 构建 Veil.app：swiftc -O -wmo，strip，ad-hoc 签名。
# 用法：./build.sh           仅构建到 build/Veil.app
#       ./build.sh install   构建并安装到 ~/Applications，然后启动
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Veil.app
BIN=$APP/Contents/MacOS/Veil
ARCH=$(uname -m)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"

swiftc -O -wmo -swift-version 5 \
  -target "$ARCH-apple-macosx13.0" \
  -framework AppKit -framework Carbon -framework ServiceManagement \
  Sources/*.swift -o "$BIN"

strip -x "$BIN"
# 优先用固定的自签名证书：签名身份不变，辅助功能授权在重新编译后仍然有效。
# 证书不存在时退回 ad-hoc（每次编译后需要重新授权）。
# 证书放在专用钥匙串 veil-signing（密码固定），签名前解锁，不会弹出钥匙串确认框。
KC="$HOME/Library/Keychains/veil-signing.keychain-db"
SIGN_ID=""
if [[ -f "$KC" ]]; then
  security unlock-keychain -p "${VEIL_KEYCHAIN_PASSWORD:-veil-local}" "$KC" 2>/dev/null || true
  SIGN_ID=$(security find-identity -p codesigning "$KC" 2>/dev/null | awk '/"Veil Local Signing"/ {print $2; exit}')
fi
if [[ -n "$SIGN_ID" ]]; then
  codesign --force --sign "$SIGN_ID" --keychain "$KC" --identifier com.dreamlike.veil "$APP" >/dev/null
else
  echo "提示：未找到“Veil Local Signing”证书，使用 ad-hoc 签名"
  codesign --force --sign - --identifier com.dreamlike.veil "$APP" >/dev/null
fi

echo "已构建：$APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "install" ]]; then
  DEST="$HOME/Applications/Veil.app"
  pkill -x Veil 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "已安装并启动：$DEST"
fi
