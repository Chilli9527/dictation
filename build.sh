#!/bin/bash
# ============================================================
#  Dictation — 一鍵編譯
#  產出：dist/Dictation.app
# ============================================================
set -e
cd "$(dirname "$0")"

APP_NAME="${APP_NAME:-Dictation}"
# 可以 override：BUNDLE_ID=com.yourname.dictation ./build.sh
# ⚠️ 唔同人用唔同 bundle id 冇問題；但同一部機唔可以有兩個 app 用同一個 id。
BUNDLE_ID="${BUNDLE_ID:-com.brucelam.dictation}"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "▶ 清理舊 build"
rm -rf "$DIST" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

echo "▶ 編譯 Swift（universal: arm64 + x86_64）"
SDK=$(xcrun --show-sdk-path 2>/dev/null || echo "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")

for ARCH in arm64 x86_64; do
  swiftc \
    -swift-version 5 \
    -O \
    -target "${ARCH}-apple-macosx13.0" \
    -sdk "$SDK" \
    -framework AppKit \
    -framework AVFoundation \
    -framework Carbon \
    Sources/main.swift \
    -o "build/Dictation-$ARCH" 2>&1 | grep -v "^$" || true
  if [ ! -f "build/Dictation-$ARCH" ]; then
    echo "✗ $ARCH 編譯失敗"
    exit 1
  fi
  echo "  ✓ $ARCH ok"
done

echo "▶ 合併 universal binary"
lipo -create -output "$APP/Contents/MacOS/$APP_NAME" \
  build/Dictation-arm64 build/Dictation-x86_64

echo "▶ 放入 Info.plist"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 令 plist 嘅 bundle id 同簽名用嘅一致（用家 override BUNDLE_ID 都唔會唔夾）
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist" 2>/dev/null \
  || echo "  ⚠️ PlistBuddy 改唔到 CFBundleIdentifier（用返原值）"

echo "▶ 簽名（穩定身份 → rebuild 唔會 reset 權限）"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Dictation Dev"; then
  # 自簽認證書：designated requirement = identifier + certificate leaf，
  # binary 點樣改都係同一個身份 → macOS TCC 權限（麥克風／輔助使用）保持有效
  codesign --force --sign "Dictation Dev" --identifier "$BUNDLE_ID" --timestamp=none "$APP" 2>&1 | sed 's/^/  /'
  echo "  ✓ 已用穩定身份「Dictation Dev」簽名"
else
  # 後備：ad-hoc（每次 rebuild 會重置權限）
  codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP" 2>&1 | sed 's/^/  /'
  echo "  ⚠️ 用咗 ad-hoc 簽名（找不到 Dictation Dev 身份）— rebuild 會 reset 權限"
fi

echo "▶ 驗證"
lipo -info "$APP/Contents/MacOS/$APP_NAME"
codesign -dvv "$APP" 2>&1 | grep -E "Identifier|Authority|Signature" | sed 's/^/  /'

echo ""
echo "✅ 完成：$(pwd)/$APP"
echo ""

# ------------------------------------------------------------
#  NO_INSTALL=1 → 只編譯，唔裝去 /Applications（install.sh 自己會裝）
# ------------------------------------------------------------
if [ "${NO_INSTALL:-0}" = "1" ]; then
  echo "（NO_INSTALL=1：跳過安裝）"
  exit 0
fi

# ------------------------------------------------------------
#  自動安裝去 /Applications（覆蓋舊版，保留同一條 bundle path，
#  先殺掉正在跑嘅舊版先覆蓋，避免 "resource busy"）
# ------------------------------------------------------------
if [ -d "/Applications/$APP_NAME.app" ]; then
  echo "▶ 停止舊版並安裝去 /Applications"
  pkill -f "/Applications/$APP_NAME.app" 2>/dev/null || true
  sleep 1
  if ditto "$APP" "/Applications/$APP_NAME.app" 2>/dev/null; then
    echo "  ✓ 已安裝：/Applications/$APP_NAME.app"
  else
    echo "  ⚠️ 安裝失敗（權限問題），請手動拖去應用程式夾"
  fi
else
  echo "▶ 安裝去 /Applications"
  if ditto "$APP" "/Applications/$APP_NAME.app" 2>/dev/null; then
    echo "  ✓ 已安裝：/Applications/$APP_NAME.app"
  else
    echo "  ⚠️ 安裝失敗，請手動拖去應用程式夾"
  fi
fi

# ------------------------------------------------------------
#  🔴 關鍵：唔好留兩個同 bundle ID 嘅 app —— macOS TCC 會將權限
#  俾錯一個，另一個 AXIsProcessTrusted() 永遠 false。
#  dist/ 係 build 輸出，改名做 .disabled 等 Launch Services 唔再當佢係 app。
# ------------------------------------------------------------
if [ -d "$APP" ] && [ "$APP" != "/Applications/$APP_NAME.app" ]; then
  mv "$APP" "$APP.disabled" 2>/dev/null && echo "  ✓ 已停用重複副本：$APP.disabled"
fi
/usr/bin/mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null | grep -v "^/Applications/" | while read -r dup; do
  mv "$dup" "$dup.disabled" 2>/dev/null && echo "  ✓ 已停用重複副本：$dup.disabled"
done

echo ""
echo "下一步（由最重要開始）："
echo "  1. 麥克風    系統設定 → 隱私權與安全性 → 麥克風 → 開 Dictation"
echo "  2. 輔助使用  系統設定 → 隱私權與安全性 → 輔助使用 → 開 Dictation（自動貼上用）"
echo "  3. 熱鍵      ⌃⌥D 撳住冇反應就一定係計佢唔到，改用 App 內嘅選單"
