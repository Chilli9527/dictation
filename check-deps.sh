#!/bin/bash
# ============================================================
#  Dictation — 體檢（唯讀，唔會改任何嘢）
#  用法：bash check-deps.sh
# ============================================================
set -uo pipefail
cd "$(dirname "$0")" || exit 1

APP="/Applications/Dictation.app"
BUNDLE_ID="com.brucelam.dictation"
MODEL_DIR="$HOME/.cache/dictation-models"
MODEL="ggml-large-v3-turbo-q5_0.bin"
FAIL=0

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
warn() { printf "  \033[33m⚠\033[0m %s\n" "$1"; }

echo ""
echo "════ Dictation 體檢 ════"

echo ""
echo "系統"
OS_VER=$(sw_vers -productVersion 2>/dev/null || echo "?")
if [ "${OS_VER%%.*}" -ge 13 ] 2>/dev/null; then ok "macOS $OS_VER"; else bad "macOS ${OS_VER}（要 13+）"; fi
command -v swiftc >/dev/null 2>&1 && ok "swiftc $(swiftc --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)" \
  || bad "冇 swiftc —— 跑 xcode-select --install"

echo ""
echo "依賴"
if command -v whisper-cli >/dev/null 2>&1; then
  ok "whisper-cli → $(command -v whisper-cli)"
elif command -v whisper-cpp >/dev/null 2>&1; then
  ok "whisper-cpp → $(command -v whisper-cpp)"
else
  bad "冇 whisper.cpp —— brew install whisper-cpp"
fi

if [ -f "$MODEL_DIR/$MODEL" ]; then
  SZ=$(stat -f%z "$MODEL_DIR/$MODEL" 2>/dev/null || echo 0)
  if [ "$SZ" -gt 500000000 ]; then ok "模型 $(du -h "$MODEL_DIR/$MODEL" | cut -f1)"; else bad "模型唔完整（$SZ bytes）"; fi
else
  bad "冇模型 —— 跑 bash install.sh"
fi

echo ""
echo "App"
if [ -d "$APP" ]; then
  ok "已安裝 $APP"
  # ⚠️ 一定要 -dvv：單一個 -v 唔會印 Authority 行
  if codesign -dvv "$APP" 2>&1 | grep -q "Dictation Dev"; then
    ok "簽名：Dictation Dev（穩定，rebuild 唔會 reset 權限）"
  else
    warn "簽名：ad-hoc（每次 rebuild 要重新開權限）"
  fi
  RUNNING=$(pgrep -f "$APP/Contents/MacOS/Dictation" | head -1 || true)
  [ -n "$RUNNING" ] && ok "正在運行（pid ${RUNNING}）" || warn "未運行"
  DUP=$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null | grep -v "^$APP$" || true)
  if [ -n "$DUP" ]; then
    bad "有重複副本（同 bundle id 會搶權限）："
    echo "$DUP" | sed 's/^/      /'
  else
    ok "冇重複副本"
  fi
else
  bad "未安裝 —— 跑 bash install.sh"
fi

echo ""
echo "權限（app 有跑先檢查得到）"
LOG="$HOME/.cache/dictation-work/debug.log"
if [ -f "$LOG" ]; then
  LAST=$(grep "tick a11y" "$LOG" | tail -1)
  if [ -n "$LAST" ]; then
    echo "  最後一次檢查：$LAST"
    echo "$LAST" | grep -q "a11y=✅"   || warn "輔助使用未開（自動貼上要用）"
    echo "$LAST" | grep -q "listen=✅" || warn "輸入監視未開（撳 Option 收唔到）"
    echo "$LAST" | grep -q "mic=已授權" || warn "麥克風未授權"
  else
    warn "日誌未有權限紀錄 —— 開一次 App 先"
  fi
else
  warn "未有日誌 —— 開一次 App 先"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  printf "\033[32m全部正常 ✅\033[0m\n\n"
else
  printf "\033[31m有 %d 樣要處理 ❌\033[0m\n\n" "$FAIL"
fi
