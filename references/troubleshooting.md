# 實戰踩過嘅坑

呢啲全部係真金白銀撞出嚟嘅，唔係教科書。

---

## 1. 揀咗繁體，出嚟仲係簡體

**唔係提示詞問題。** 有兩個獨立成因：

### 成因 A：AI 回傳嘅文字冇再過字形關

原本流程係「規則層 → `applyScript()`（轉字形）→ 送 AI → 貼出去」。
字形只喺**送 AI 之前**做，AI 回傳嘅字**直接貼**。
模型偶爾無視「必須繁體」嘅指令吐簡體 → 用戶就見到簡體。

修法：AI 回傳之後**再過一次** `applyScript()`（idempotent，對正確字形零影響）。

```swift
case .deepseek:
    cleanWithDeepSeek(text) { out in completion(applyScript(out)) }
```

### 成因 B：守門把正確嘅繁體輸出誤殺

「保留度」用 LCS 相似度把關。簡→繁轉換會令**大量字元唔同**（這個→這個 唔同、還沒→還沒 唔同），
LCS 可能得 0.53，90% 門檻（0.86）直接退回 → 結果仍然係簡體。

修法：比較**之前**先 `scriptNeutral()`（`Hant-Hans`）統一字形。

```swift
let a = scriptNeutral(normalizeForCompare(out))
let b = scriptNeutral(normalizeForCompare(original))
```

### 字形轉換本身

```swift
let m = NSMutableString(string: s)
CFStringTransform(m, nil, "Hans-Hant" as CFString, false)   // 簡 → 繁
CFStringTransform(m, nil, "Hant-Hans" as CFString, false)   // 繁 → 簡
```

ICU 內建、離線、零成本、idempotent。連「头发 → 頭髮」都識。

---

## 2. Whisper 對住底噪吐亂碼

全零／極靜嘅 WAV 會令 Whisper 產生幻覺，實測見過：

```
PENGASPEN    PAUSE    NARAT    PENHUZI    （全大寫拉丁亂碼）
「你」「you」「多謝觀看」
```

兩層防禦：

1. **靜音閘**：錄音峰值 `peakLevel < -40 dB` → 直接跳過辨識（最有效）
2. **雜訊過濾**：無 CJK + 有大寫 + 無小寫 + ≤20 字 → 丟棄。`1234`、`OK Google` 要保留

```swift
static func isGarbage(_ s: String) -> Bool
```

---

## 3. Apple FoundationModels 做唔到「只執字」

實測四種提示寫法，全部失敗：

| 寫法 | 實際行為 |
|---|---|
| 「你係校對員，只改錯字」 | 原樣照抄，一個錯字都唔改 |
| 「你係打字員，照抄一次」 | 自己重作（11 字 → 237 字假回覆） |
| 「逐字校對」 | 改成書面語（「這個plan」） |
| 純 prompt | 偷偷加字（「我今日」→「今日我今日」） |

**結論**：呢類 tiny on-device model 只適合生成，唔適合校對。冇中間地帶。
所以預設清理引擎改為「純規則執字粒」，完全唔經 AI。

---

## 4. 清理 regex 會整爛正常疊字

```swift
// ❌ 錯：會 collapse 所有重複中文字
"([\u4e00-\u9fa5])\\1{1,}"
```

「看看」「慢慢」「謝謝」「剛剛」「聽聽」全部變態。

**正確**：口吃 collapse 一定要用**虛詞白名單**（我／你／佢／係／唔／嘅／就／都…）。

---

## 5. 手寫 AppKit app 冇建 `NSApp.mainMenu` → Cmd+C／Cmd+V 靜靜失效

macOS 嘅複製貼上**唔係**鍵盤快捷鍵，係靠主選單嘅 `copy:`／`paste:` 選單項
經 responder chain 派動作。冇選單項 = **完全冇反應，而且唔會報錯**。

```swift
edit.addItem(withTitle: "貼上", action: NSSelectorFromString("paste:"), keyEquivalent: "v")
NSApp.mainMenu = main
```

另外 `NSAlert` 內嵌文字框要 `a.window.initialFirstResponder = field`，
否則游標唔喺框內，Cmd+V 貼去虛空。

---

## 6. 提示音：換過輸出裝置就冇聲

`AVAudioEngine` 喺輸出裝置改變（插／拔耳機、切 AirPods）之後會自己停，
但你自己嘅 `ready` flag 仍然係 `true` → 之後所有 `play()` 靜靜地唔出聲。

```swift
if !engine.isRunning {
    try engine.start()   // 每次播之前都要檢查
}
```

音效用正弦波即場合成（唔靠 `/System/Library/Sounds/`，macOS 改版改名都唔怕）：

- 開始：660Hz → 990Hz（向上）
- 停止：990Hz → 660Hz（向下）
- 6ms attack / 20ms release 避免爆音 click
- `mainMixerNode.outputVolume = 0.22`（「一點點」就夠）

---

## 7. 卡死：`busy` 永遠 true

如果 transcriber callback 永遠唔返（whisper-cli hang、網絡卡住），`busy` 永遠 true
→ 之後撳咩都**靜靜地冇反應**，完美符合「app 壞咗」嘅投訴。

要裝看門狗：每 3 秒檢查，`.working` 狀態超過 30 秒強制重設。

---

## 8. `NSAlert.runModal()` 會餓死所有 default-mode timer

modal session 用 `.modalPanel` run loop mode，**default mode 嘅 timer 全部停**。
實測：錄音停止 timer 永久失效，WAV 檔不停變大。

修法：彈 sheet（`beginSheetModal`，一定要掛喺可見視窗），或者非同步呈現，
**唔好**喺有 timer 跑緊嘅時候用 `runModal()`。

---

## 9. `open -n App --args --flag` 傳唔到 argument

實測無效。自測要用標記檔（`~/.cache/dictation-work/run-selftest`），
或者直接 exec binary —— 但注意：

⚠️ **直接 exec `App/Contents/MacOS/xxx` 嘅 TCC 身份同 `open -n` 唔同**
（前者麥克風可能已拒絕，後者已授權）。要驗證權限／錄音，一定要經 `open -n` 起。

---

## 10. `-O` 之下 argv／env 嘅 String 放入 array 再 iterate 會 SIGSEGV

```
swift::RefCounts::incrementSlow
Dictation main ×2
dyld start
```

連一行 `print` 都出唔到（即使 `setvbuf` 無緩衝）。獨立細檔重現唔到，係大檔 `-O`／ARC 問題。

修法：用 `String(decoding: raw.utf8, as: UTF8.self)` 做一份即場副本，**唔入 array**。

---

## 11. macOS 係 BSD grep：`\|` alternation 無效

```bash
grep "A\|B" file      # ❌ 當 literal 搜尋，假陰性
grep -E "A|B" file    # ✅
```

中過招：以為「事件從未出現」，實際一路正常。用錯 grep 會令你作出完全相反嘅結論。

---

## 12. SwiftUI segmented Picker 會壓爆左邊標籤

segments 文字太長（「95%（幾乎原文）」）會令 `HStack` 把寬度讓畀 picker，
左邊 `Text` 被裁（「保留度」→「保留」）。

修法：所有 row label 用

```swift
.frame(width: 44, alignment: .leading)
.fixedSize()
```

並縮短 segments 文字。

---

## 13. 多屏幕：`NSWindow.center()` 會 center 去錯屏

macOS 多屏（尤其 Sidecar）之下，`center()` 可能把你丟去第二塊屏。
要自己揀「有選單列嗰塊」：

```swift
NSScreen.screens.first(where: { $0.frame.origin == .zero })
```

另外 SwiftUI 視窗**必須明確 `setContentSize`**：`NSHostingController` 未排版時
`fittingSize` 係 1px，`NSWindow` 未設尺寸就 center 會變 1×32 離屏視窗
→ 用戶雙擊似「乜都冇發生」。

---

## 14. DeepSeek V4 預設開思考模式

唔關掉會慢幾秒、仲會出 reasoning 內容。

```json
"thinking": {"type": "disabled"}
```

另外用 `"response_format": {"type": "json_object"}` 逼佢只回 `{"text": "..."}`，
天然冇前言／客套話。任何失敗（無 key／401／逾時 6 秒／改動過大）→ 自動退回規則版，
**唔可以卡住用戶貼字**。

---

## 15. 靜音其他聲音：最怕「靜完冇還原」

需求：錄音時將其他聲音靜音（睇住片都可以直接講嘢）。

做法：用 CoreAudio HAL 靜音**預設輸出裝置**。

```swift
// 首選：mute 屬性（唔會改動用戶設定嘅音量數字）
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyMute,
    mScope: kAudioObjectPropertyScopeOutput,
    mElement: kAudioObjectPropertyElementMain)
AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &one)

// 次選（AirPods／HDMI／部分 USB DAC 冇 mute 屬性）：音量歸零
kAudioDevicePropertyVolumeScalar  // 注意 main element 可能冇，要試 element 1 / 2
```

### 三個坑

**① 靜音會連自己嘅提示音都靜埋**

`AVAudioEngine` 出嘅「嘟‑嗶」都係去同一個輸出裝置。
→ 開始：**先播提示音，0.14 秒後才靜音**。
→ 停止：**先還原，再播停止音**。次序反轉就兩個音都聽唔到。

**② 0.7 秒嘅裝置檢查 timer 會搶先一步**

timer 同 `beginRecording` 嘅延遲靜音同時跑，會出現
「換咗輸出裝置，已靜音新裝置」呢個假警報（同一部裝置 log 兩次）。
→ 記住 `mutedAt`，靜音後 0.8 秒內 timer 唔做嘢。

**③ crash／強制退出 → 部機從此冇聲（最痛）**

三條保險：

1. 錄完即刻還原
2. `applicationWillTerminate` 再還原一次
3. 靜音前先寫 `~/.cache/dictation-work/muted.json`（記住**原本**狀態），
   下次啟動 `recoverFromCrash()` 見到就即刻解返

⚠️ 保險檔記嘅係「原本狀態」，唔係「現在要 mute」。
如果原本就係 mute，還原後仍然係 mute —— 呢個係正確行為，唔係 bug。

**④ 用戶喺錄音期間自己調音量**

還原嗰陣如果發現當前音量已經唔係 0，代表用戶自己調過 → **唔好還原**，尊重佢。

---

## 16. 換模型提高準確度（turbo → 完整版 large-v3）

需求：由「講話到文字」要準確。

**事實先講清楚**：`ggml-large-v3-turbo-q5_0.bin` **本身就係 Whisper**（large-v3-turbo，
OpenAI 官方剪枝版）。唔存在「Whisper 另一個模型」嘅分別，只有 turbo vs 完整版。

| | turbo | 完整版 large-v3 |
|---|---|---|
| 解碼器 | 4 層 | 32 層 |
| 大小 | 547MB | 1.08GB |
| 速度（M4 Pro） | 每句約 0.6s | 每句約 1.2s |
| 實測錯誤 | `長遠`→`長青`、`WorkBuddy`→`Wabuddy`、粵語出簡體 | 全部正確，直接出繁體 |

 turbo 嘅解碼器被剪到 4 層 → 近音詞、中英夾雜、字形一致明顯變差。
慢 2.3 倍但每句只多約 1 秒，聽寫嘅體感差唔多。**求準確就必修羅完整版。**

```bash
curl -L -o ~/.cache/dictation-models/ggml-large-v3-q5_0.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin"
# 選單列「模型」即刻多一項（availableModels() 自動掃目錄），唔使重新編譯
```

官方 `ggml-large-v3-q5_0.bin` size = **1,081,140,203 bytes**（用嚟核實下載完整性）。

### 雜訊幻覺會換樣

換模型後，底噪吐嘅亂碼會由全大寫拉丁（`PENGASPEN`）變成**顏文字同符號**
（實測完整版對住環境噪聲吐 `╯︵ ┻━┻`）。
→ `isGarbage()` 要覆蓋「**冇任何字母或數字**」呢類（純符號輸出永遠唔係真內容）。
留意 `$0.isLetter` 對數字係 false，所以要 `isLetter || isNumber`，
否則 `1234` 會被誤殺。
