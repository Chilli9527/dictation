#!/bin/bash
# ============================================================
#  Dictation — 一鍵安裝（macOS 13+）
#
#  做四件事：
#    1. 檢查系統（macOS 版本、Xcode Command Line Tools、Homebrew）
#    2. 裝 whisper.cpp（冇裝先裝）
#    3. 下載 Whisper 模型（547MB，只下載一次）
#    4. 編譯 + 簽名 + 裝去 /Applications
#
#  用法：  bash install.sh
#  想用自己嘅 bundle id：BUNDLE_ID=com.yourname.dictation bash install.sh
# ============================================================
set -uo pipefail
cd "$(dirname "$0")" || exit 1

MODEL_DIR="$HOME/.cache/dictation-models"
MODEL="ggml-large-v3-turbo-q5_0.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL"
BUNDLE_ID="${BUNDLE_ID:-com.brucelam.dictation}"
APP_NAME="Dictation"

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m⚠\033[0m %s\n" "$1"; }
die()  { printf "\n\033[31m✗ %s\033[0m\n\n" "$1"; exit 1; }
step() { printf "\n\033[1m▶ %s\033[0m\n" "$1"; }

# ------------------------------------------------------------
step "1/5  檢查系統"
# ------------------------------------------------------------
OS_VER=$(sw_vers -productVersion 2>/dev/null || echo "0")
OS_MAJOR=${OS_VER%%.*}
[ "${OS_MAJOR:-0}" -ge 13 ] 2>/dev/null \
  || die "要 macOS 13 或以上（你而家係 ${OS_VER}）"
ok "macOS $OS_VER"

if ! xcode-select -p >/dev/null 2>&1; then
  echo ""
  echo "  需要 Xcode Command Line Tools（免費，約 1-2GB）。"
  echo "  即將幫你開啟安裝視窗，裝完之後再跑一次 bash install.sh。"
  xcode-select --install 2>/dev/null || true
  die "請先裝好 Command Line Tools"
fi
command -v swiftc >/dev/null 2>&1 || die "搵唔到 swiftc —— 請跑 xcode-select --install"
ok "Swift $(swiftc --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"

ARCH=$(uname -m)
ok "處理器 $ARCH"

# ------------------------------------------------------------
step "2/5  檢查 whisper.cpp"
# ------------------------------------------------------------
if command -v whisper-cli >/dev/null 2>&1; then
  ok "whisper-cli 已裝：$(command -v whisper-cli)"
elif command -v whisper-cpp >/dev/null 2>&1; then
  ok "whisper-cpp 已裝：$(command -v whisper-cpp)"
else
  warn "未裝 whisper.cpp"
  if ! command -v brew >/dev/null 2>&1; then
    echo ""
    echo "  需要 Homebrew 先裝得到 whisper.cpp。"
    echo "  安裝 Homebrew（官方一行指令）："
    echo '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    die "請先裝 Homebrew"
  fi
  echo "  正在裝：brew install whisper-cpp（可能要幾分鐘）"
  if brew install whisper-cpp; then
    ok "whisper.cpp 裝好"
  else
    die "brew install whisper-cpp 失敗"
  fi
fi

# ------------------------------------------------------------
step "3/5  檢查 Whisper 模型"
# ------------------------------------------------------------
mkdir -p "$MODEL_DIR"
if [ -f "$MODEL_DIR/$MODEL" ]; then
  SIZE=$(stat -f%z "$MODEL_DIR/$MODEL" 2>/dev/null || echo 0)
  if [ "$SIZE" -gt 500000000 ]; then
    ok "模型已存在（$(du -h "$MODEL_DIR/$MODEL" | cut -f1)）"
  else
    warn "模型檔案唔完整（$SIZE bytes），重新下載"
    rm -f "$MODEL_DIR/$MODEL"
  fi
fi

if [ ! -f "$MODEL_DIR/$MODEL" ]; then
  echo "  下載 ${MODEL}（547MB，一次性）…"
  echo "  存放位置：$MODEL_DIR"
  if curl -L --fail --progress-bar -o "$MODEL_DIR/$MODEL.part" "$MODEL_URL"; then
    mv "$MODEL_DIR/$MODEL.part" "$MODEL_DIR/$MODEL"
    ok "模型下載完成（$(du -h "$MODEL_DIR/$MODEL" | cut -f1)）"
  else
    rm -f "$MODEL_DIR/$MODEL.part"
    die "模型下載失敗（檢查網絡，或者手動由 huggingface.co/ggerganov/whisper.cpp 下載）"
  fi
fi

# ------------------------------------------------------------
step "4/5  編譯 + 簽名"
# ------------------------------------------------------------
BUNDLE_ID="$BUNDLE_ID" ./build.sh || die "編譯失敗（睇上面嘅錯誤）"

# ------------------------------------------------------------
step "5/5  驗證"
# ------------------------------------------------------------
if [ -d "/Applications/$APP_NAME.app" ]; then
  ok "已安裝：/Applications/$APP_NAME.app"
elif [ -d "$HOME/Applications/$APP_NAME.app" ]; then
  ok "已安裝：$HOME/Applications/$APP_NAME.app"
else
  warn "搵唔到安裝好嘅 app —— 你可以手動將 dist/$APP_NAME.app 拖去「應用程式」"
fi

echo ""
echo "────────────────────────────────────────────"
echo "  仲要做兩步（macOS 一定要你自己開）"
echo "────────────────────────────────────────────"
echo "  1. 開一次 Dictation（應用程式資料夾雙擊）"
echo "  2. 系統設定 → 隱私權與安全性 → 麥克風      → 開 Dictation"
echo "     系統設定 → 隱私權與安全性 → 輔助使用    → 開 Dictation"
echo "     系統設定 → 隱私權與安全性 → 輸入監視    → 開 Dictation"
echo ""
echo "  然後撳一下 Option 就開始錄，講完再撳一下出字。"
echo "  有問題睇 references/troubleshooting.md"
echo ""
