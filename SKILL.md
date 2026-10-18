---
name: macos-dictation
description: |
  喺 macOS 由零起一個完全本機、免費、唔使訂閱嘅語音聽寫 App（Swift + whisper.cpp）。
  撳一下觸發鍵（預設 Option）開始錄音，講完再撳一下，文字自動貼入你正在用嘅 App；
  粵語／繁簡字形／中英夾雜全部跟設定走。
  呢個 skill 包埋完整原始碼、一鍵安裝、體檢腳本、同埋實際踩過嘅坑。
  觸發詞：本機聽寫、語音聽寫、語音轉文字、Whisper 聽寫、Spokenly 替代、免費聽寫、
  唔想畀月費、dictation app、speech to text mac、廣東話聽寫、粵語語音輸入。

read_when:
  - 用戶想裝／重裝／升級一個本機聽寫 app
  - 用戶報「撳 Option 冇反應」「出簡體字」「貼唔到字」「辨識唔到」
  - 用戶想改觸發鍵、改模型、改文字清理方式
  - 要喺第二部 Mac 重現同一套環境
---

# macos-dictation

一個真正本地跑嘅 macOS 聽寫工具：**whisper.cpp 做辨識、Swift/AppKit 做 UI、零訂閱**。
唔會上傳錄音，唯一例外係你自願開嘅 DeepSeek 改錯字（可以完全關掉）。

## 一句講晒

```
bash install.sh  →  開三個權限  →  撳 Option 講嘢  →  再撳 Option 出字
```

---

## Step 1. 安裝

```bash
cd macos-dictation
bash install.sh
```

install.sh 會依次做：

| 步驟 | 做咩 | 失敗點 |
|---|---|---|
| 1 | 檢查 macOS 13+、Xcode Command Line Tools | 會自動彈 `xcode-select --install` |
| 2 | 裝 whisper.cpp（`brew install whisper-cpp`） | 冇 Homebrew 會叫你裝 |
| 3 | 下載模型 `ggml-large-v3-q5_0.bin`（1.08GB）到 `~/.cache/dictation-models/` | 只下載一次 |
| 4 | `build.sh` 編譯 universal binary（arm64 + x86_64）＋ 簽名 | 見下面「簽名」 |
| 5 | 安裝去 `/Applications/Dictation.app` | 冇權限就手動拖 |

### 模型揀擇（2026-10-18 實測）

| 模型 | 解碼器 | 大小 | 速度（M4 Pro） | 準確度 |
|---|---|---|---|---|
| `ggml-large-v3-q5_0.bin`（**預設**） | 32 層 | 1.08GB | 每句約 1.2s | ⭐ 近音詞／中英夾雜／繁體字形明顯較準 |
| `ggml-large-v3-turbo-q5_0.bin` | 4 層（剪枝） | 547MB | 每句約 0.6s（快 2.3 倍） | 稍遜：實測 `長遠`→`長青`、`WorkBuddy`→`Wabuddy`、粵語出簡體字 |

只下載 turbo：`MODEL=ggml-large-v3-turbo-q5_0.bin bash install.sh`。
兩個模型可以同時存在，選單列「模型」隨時切換。

想用自己嘅 bundle id（同作者嘅機唔撞）：

```bash
BUNDLE_ID=com.yourname.dictation bash install.sh
```

## Step 2. 體檢（唯讀，唔會改嘢）

```bash
bash check-deps.sh
```

會逐項報：macOS 版本、swiftc、whisper-cli、模型、app 有冇裝、簽名身份、
有冇**重複副本**（同 bundle id 兩個 app 會搶 TCC 權限）、三個權限開咗未。

## Step 3. 三個權限（缺一不可）

| 權限 | 用途 | 冇開嘅後果 |
|---|---|---|
| 麥克風 | 收音 | 完全錄唔到 |
| **輸入監視**（Input Monitoring） | CGEventTap 收修飾鍵 | 撳 Option **完全冇反應**，而且**系統零提示** |
| 輔助使用（Accessibility） | 模擬 Cmd+V 貼字 | 認到字但**打唔入其他 App** |

⚠️ macOS 15 起「輔助使用」同「輸入監視」係**兩個獨立權限**，兩個都要開。
詳細排查見 `references/permissions.md`。

## Step 4. 用法

1. 游標擺喺任何輸入位置（WhatsApp／郵件／瀏覽器）
2. 撳一下觸發鍵（預設 **Option**，左右都收）→ 聽到「嘟‑嗶」向上
3. 講嘢
4. 再撳一次 → 聽到「嗶‑嘟」向下 → 文字自動貼上

觸發方式可揀「撳一次開始／再撳一次完結」（toggle）或「按住講、鬆手停」（hold）。

### 🔇 錄音時靜音其他聲音（預設開）

睇住片都可以直接撳 Option 講嘢：開始錄音時會將**預設輸出裝置**靜音，錄完即刻還原。

- 用 `kAudioDevicePropertyMute`（唔會改動你嘅音量數字）；裝置唔支援就退為音量歸零
- 提示音係喺靜音**之前**播（延遲 0.14 秒才靜音），所以「開始」音聽得到；
  停止時係**先還原再播**停止音
- 錄音中途換輸出裝置（插耳機／AirPods）→ 0.7 秒 timer 會跟住靜音新裝置
- 三條防「部機從此冇聲」保險：錄完即還原、`applicationWillTerminate` 再還原、
  `~/.cache/dictation-work/muted.json` crash 保險檔（下次啟動自動解返）
- 主視窗 checkbox 或選單列「錄音時靜音其他聲音」可關掉
- 自測：`Dictation --test-mute`（靜音 2 秒後還原，會印出裝置狀態）

## 文字清理：五個引擎

| 引擎 | 費用 | 行為 |
|---|---|---|
| ✨ 執字粒（預設） | $0 | 純規則：虛詞口吃、填充詞、空格、半角標點 → 全角。**唔經 AI，一個字都唔會加** |
| 🧠 執字粒 · DeepSeek | ~¥0.0001/句 | 規則層 + 雲端改同音錯字（我地→我哋）。可揀 V4.1-Flash（預設）／V4-Pro |
| 🚫 唔整理 | $0 | Whisper 出咩貼咩（字形仍然跟語言設定） |
| 🍎 Apple 內建 AI | $0 | 離線，但**會改寫**你嘅講法 |
| 🤖 GPT-4o mini | 要 OpenAI key | 同 Spokenly 一樣會改寫 |

**字形一定跟「輸出語言」**：揀「廣東話（繁體中文）」→ 出繁體（Whisper 偶然吐簡體都會轉返）；
揀普通話 → 出簡體。規則層之後一次、**AI 回傳之後再過一次**（模型會無視指令，見 troubleshooting）。

---

## 出問題

先跑 `bash check-deps.sh`，再睇 `references/troubleshooting.md`。
日誌：`~/.cache/dictation-work/debug.log`（每 2 秒一行 `tick`，睇得到權限同 tap 狀態）。

最常見三個：

| 症狀 | 睇邊 |
|---|---|
| 撳 Option 完全冇反應 | `references/permissions.md` §輸入監視 |
| 認到字但打唔入其他 App | `references/permissions.md` §輔助使用 |
| 揀咗繁體出簡體 | `references/troubleshooting.md` §字形 |

## 改嘢

全部程式碼喺 `Sources/main.swift`（一支檔，約 3300 行）。

```bash
./build.sh                 # 編譯 + 簽名 + 裝去 /Applications
NO_INSTALL=1 ./build.sh    # 只編譯
```

離線自測（唔會碰麥克風、唔會貼字）：

```bash
D=./dist/Dictation.app/Contents/MacOS/Dictation
$D --test-sound                          # 播開始／停止提示音
$D --test-mute                           # 靜音 2 秒後還原，印出裝置狀態
POLISH_TEST="原文" $D --test-polish      # 執字粒 + 雜訊過濾 + 字形轉換
$D --test-guard                          # 守門六個回歸案例
DEEPSEEK_TEST="原文" $D --test-deepseek  # 規則層 vs DeepSeek 對比 + 耗時
```

⚠️ 參數一律用**環境變數**傳，唔好用 argv：`-O` 之下將 argv/env 出嚟嘅 String 放入 array
再 iterate 會 SIGSEGV（`swift::RefCounts::incrementSlow`）。

## 簽名

`build.sh` 會搵 login keychain 有冇 **`Dictation Dev`** 自簽證書：

- **有** → 用穩定身份簽（designated requirement = identifier + certificate leaf），
  rebuild 幾多次都**唔會 reset 麥克風／輔助使用權限**
- **冇** → 退 ad-hoc。每次 rebuild 都要去系統設定重新開權限

想建證書（一次，10 年有效）：

```bash
# 1. 造 key + 自簽證書（注意一定要 -legacy，否則匯入會 MAC verification failed）
openssl req -x509 -newkey rsa:2048 -keyout /tmp/dk.key -out /tmp/dk.crt -days 3650 -nodes \
  -subj "/CN=Dictation Dev"
openssl pkcs12 -export -legacy -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -inkey /tmp/dk.key -in /tmp/dk.crt -out /tmp/dk.p12 -passout pass:
security import /tmp/dk.p12 -k ~/Library/Keychains/login.keychain-db -P "" -T /usr/bin/codesign
security add-trusted-cert -d -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db /tmp/dk.crt
```

## 檔案結構

```
macos-dictation/
├── SKILL.md                  # 你睇緊嘅（agent 用）
├── README.md                 # GitHub 首頁（人用）
├── install.sh                # 一鍵安裝
├── check-deps.sh             # 體檢（唯讀）
├── build.sh                  # 編譯 + 簽名 + 安裝
├── Sources/main.swift        # 全部程式碼
├── Resources/Info.plist      # App 元資料（權限說明字串喺呢度）
└── references/
    ├── permissions.md        # 三個 TCC 權限 + 排查
    └── troubleshooting.md    # 實戰踩過嘅坑
```

## 授權

自己嘅 code，MIT。外部組件：whisper.cpp（MIT）、Whisper 模型（MIT，OpenAI 釋出）。
