# 三個權限（macOS）

呢個 app 一定要三個權限，缺一個就會壞得**好靜**（唔會彈錯，只係冇反應）。

| 權限 | 系統設定位置 | 用途 | 冇開嘅症狀 |
|---|---|---|---|
| 麥克風 | 隱私權與安全性 → 麥克風 | `AVAudioRecorder` 收音 | 錄唔到，HUD 即刻收 |
| **輸入監視** | 隱私權與安全性 → **輸入監視** | CGEventTap 收修飾鍵 | **撳 Option 完全冇反應**（系統零提示） |
| 輔助使用 | 隱私權與安全性 → 輔助使用 | `CGEvent` 模擬 Cmd+V | 認到字，但**打唔入其他 App** |

---

## 🔴 最大的坑：macOS 15 起「輸入監視」同「輔助使用」係兩個獨立權限

以前只要「輔助使用」就收得到鍵盤事件，macOS 15 之後拆開咗：

- 只有輔助使用 → `CGEventTapCreate` **會成功**、`CGEventTapIsEnabled` **報 true**、
  `CGIsEventTapEnabled` 都正常 —— 但**永遠收唔到任何按鍵**，而且**系統完全冇提示**。
- 症狀就係「app 睇落一切正常，但撳極都冇反應」。

程式碼點檢查：

```swift
CGPreflightListenEventAccess()   // 有冇「輸入監視」
CGPreflightPostEventAccess()     // 有冇「輔助使用」
CGRequestListenEventAccess()     // 彈系統視窗申請
```

直接開設定頁：

```
x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent
```

⚠️ **測試陷阱**：app 喺前台嘅時候，事件似乎會經另一條路送到，令你以為冇問題。
一定要**切去背景**（例如開個 Safari）再撳觸發鍵先測得準。

---

## 🔴 第二個坑：同一部機有兩個同 bundle id 嘅 app

macOS TCC 用 bundle id 記權限。如果 `/Applications/Dictation.app` 同
`專案/dist/Dictation.app` 都係 `com.brucelam.dictation`：

- 權限會俾咗其中一個，另一個 `AXIsProcessTrusted()` **永遠 false**
- 你會見到「系統設定明明開咗」但 app 話冇

檢查：

```bash
mdfind "kMDItemCFBundleIdentifier == 'com.brucelam.dictation'"
```

修法：只留一個。`build.sh` 已經自動將 `dist/` 嘅副本改名做 `.disabled`，
並掃一次全機同名 app。改完要重啟 Finder 或跑：

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -r -domain local -domain system -domain user
```

（新版 macOS 已經冇 `lsregister -kill`，用上面嗰句。）

---

## 🔴 第三個坑：另一隻 app 食咗你嘅修飾鍵

Spokenly／Alfred／Raycast／Keyboard Maestro 之類會裝自己嘅 event tap。
**喺 HID 層食咗事件**，你個 app 就完全收唔到。

實例：Spokenly quit 咗，但登錄項 helper `SpokenlyMacHelper`
（`app.spokenly.autolaunch`）仍然會自動重啟 Spokenly。

```bash
launchctl bootout gui/$(id -u)/app.spokenly.autolaunch
pkill -f Spokenly
```

⚠️ 沙盒環境下 `launchctl` 會靜默失敗，要喺正常 Terminal 跑。

---

## 安全輸入模式

如果你啱啱喺某個程式入過密碼（或者開住 Terminal 嘅 secure keyboard entry），
macOS 會暫時唔將按鍵交俾任何 event tap。過一陣或者 quit 嗰個程式就好。

---

## 重設權限（最後手段）

```bash
tccutil reset Accessibility com.brucelam.dictation
tccutil reset ListenEvent   com.brucelam.dictation
tccutil reset Microphone    com.brucelam.dictation
```

然後重開 app，重新開三個權限。**通常唔需要**，先確認冇重複副本同冇第二隻 app 搶事件。

---

## 簽名同權限嘅關係

TCC 用「designated requirement」認 app。ad-hoc 簽名（`--sign -`）嘅 DR 包含 binary hash，
**每次 rebuild 都會變** → macOS 當你係新 app，權限要重新開。

用固定嘅自簽證書（`Dictation Dev`）之後，DR = identifier + certificate leaf，
binary 點改都係同一個身份 → **權限保留**。`build.sh` 會自動偵測，有就用。
