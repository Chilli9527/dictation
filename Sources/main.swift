// ============================================================
//  Dictation — 自己造嘅語音聽寫（Spokenly 替代品 MVP）
//  撳熱鍵講話 → 再撳一次 → 本地 Whisper 辨識 → 自動打入當前 App
//
//  技術組成：
//    · 錄音   AVAudioRecorder (16kHz mono PCM)
//    · 辨識   whisper.cpp (本機 whisper-cli，Metal GPU 加速)
//    · 熱鍵 ① Carbon RegisterEventHotKey（免輔助使用權限）
//              ② CGEventTap 偵測修飾鍵按住／放開（需要權限）
//    · 輸出   CGEvent 模擬 Cmd+V 貼上（保留剪貼板內容）
//
//  需要權限：麥克風（必要）+ 輔助使用（自動貼上先用）
// ============================================================

import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import CoreAudio
import SwiftUI
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// ---------------- 診斷狀態（俾主視窗即時顯示） ----------------
/// 純值類，主視窗每 2 秒 reload 時讀一次，唔使 Combine
final class Diag {
    static let shared = Diag()

    /// Carbon 熱鍵最近一次成功收到事件嘅時間（空 = 從未收到）
    var lastHotkeyHit: String = ""
    /// 最近一次從 app event target 收到嘅原始按鍵（keyCode + flags）
    var lastKeyEvent: String = ""
    /// Carbon 註冊狀態
    var carbonRegistered: Bool = false
    var carbonLabel: String = currentCombo().label
    var carbonLabels: [String] = []
    var carbonInstallStatus: Int32 = 0
    /// 最近一次錯誤
    var lastError: String = ""
    /// 卡死自動重設過幾多次
    var stuckResets: Int = 0
    /// CGEventTap 自動重建過幾多次
    var tapRebuilds: Int = 0

    private static let fmt: DateFormatter = {
        let d = DateFormatter(); d.dateFormat = "HH:mm:ss"; return d
    }()

    func markHotkey() {
        let t = Self.fmt.string(from: Date())
        DispatchQueue.main.async {
            self.lastHotkeyHit = t
            DLog.w("★ Carbon 熱鍵事件收到 @ \(t)")
        }
    }

    func markKey(keyCode: Int64, flags: UInt64) {
        let t = Self.fmt.string(from: Date())
        DispatchQueue.main.async {
            self.lastKeyEvent = "\(t)  keyCode=\(keyCode) flags=0x\(String(flags, radix: 16))"
        }
    }

    func fail(_ s: String) {
        DispatchQueue.main.async { self.lastError = s }
        DLog.w("✗ \(s)")
    }
}

// ---------------- 偵錯 log ----------------
enum DLog {
    static let path = kWorkDir + "/debug.log"
    static func w(_ s: String) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(df.string(from: Date()))] \(s)\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            h.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

// ============================================================
//  Carbon 全域熱鍵 —— ⚠️ 唔需要輔助使用權限！
//  Carbon RegisterEventHotKey 只支援「撳一下」觸發，所以係切換模式
// ============================================================
struct HotkeyCombo {
    let id: String
    let label: String
    let keyCode: UInt32
    let mods: UInt32
}

let kCombos: [HotkeyCombo] = [
    HotkeyCombo(id: "ctrloptd",     label: "⌃⌥ D",   keyCode: 2,  mods: UInt32(controlKey | optionKey)),
    HotkeyCombo(id: "ctrloptspace", label: "⌃⌥ 空格", keyCode: 49, mods: UInt32(controlKey | optionKey)),
    HotkeyCombo(id: "shiftoptd",    label: "⇧⌥ D",   keyCode: 2,  mods: UInt32(shiftKey | optionKey)),
    HotkeyCombo(id: "ctrld",         label: "⌃ D",    keyCode: 2,  mods: UInt32(controlKey)),
    HotkeyCombo(id: "ctrloptk",     label: "⌃⌥ K",   keyCode: 40, mods: UInt32(controlKey | optionKey)),
    HotkeyCombo(id: "ctrloptj",     label: "⌃⌥ J",   keyCode: 38, mods: UInt32(controlKey | optionKey)),
    HotkeyCombo(id: "ctrlopts",     label: "⌃⌥ S",   keyCode: 1,  mods: UInt32(controlKey | optionKey)),
]

final class CarbonHotkey {
    var onPress: (() -> Void)?
    /// 而家用緊嗰組（只係用嚟顯示標籤）
    private var current = currentCombo()
    /// 所有成功註冊咗嘅 hotkey ref
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    func setCombo(_ c: HotkeyCombo) { current = c; start() }

    func isRegistered() -> Bool { !refs.isEmpty }

    /// 一次過註冊晒 kCombos 入面所有組合，每個用唔同 hotkey id。
    /// 用戶撳邊個都即時觸發 —— 完全解決「個組合俾第個 App 搶咗」嘅問題。
    func start() {
        stop()
        var ok: [String] = []
        var bad: [String] = []

        for (i, c) in kCombos.enumerated() {
            let id = EventHotKeyID(signature: OSType(0x4449_4354), id: UInt32(i + 1)) // 'DICT'
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(c.keyCode, c.mods, id,
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let r = ref {
                refs.append(r)
                ok.append(c.label)
            } else {
                bad.append("\(c.label)(osStatus \(st))")
            }
        }

        // 只需要裝一次 handler（事件內容一樣：撳咗就得）
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            var handlerRef: EventHandlerRef?
            let st2 = InstallEventHandler(GetApplicationEventTarget(), carbonHandler, 1, &spec,
                                          Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
            installed = true
            Diag.shared.carbonInstallStatus = st2
        }

        DLog.w("Carbon 熱鍵註冊：成功 \(ok.count) 組 [\(ok.joined(separator: " "))]"
             + (bad.isEmpty ? "" : "；失敗 \(bad.count) 組 [\(bad.joined(separator: " "))]"))
        Diag.shared.carbonRegistered = !ok.isEmpty
        Diag.shared.carbonLabel = current.label
        Diag.shared.carbonLabels = ok
        if ok.isEmpty {
            Diag.shared.fail("成組熱鍵都註冊唔到 — 可能畀其他 App 全搶咗")
        }
    }

    func stop() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
    }
}

private let carbonHandler: EventHandlerUPP = { _, _, userData in
    guard let userData = userData else { return noErr }
    let me = Unmanaged<CarbonHotkey>.fromOpaque(userData).takeUnretainedValue()
    Diag.shared.markHotkey()
    DispatchQueue.main.async { me.onPress?() }
    return noErr
}

/// 原始按鍵監測（只用嚟偵錯：確認 app 個 event loop 有冇收到任何按鍵）
private let rawKeyHandler: EventHandlerUPP = { _, event, _ in
    // Carbon EventRef bridge 返 NSEvent，直接攞 keyCode / modifierFlags
    if let e = event, let ev = NSEvent(eventRef: UnsafeRawPointer(e)) {
        Diag.shared.markKey(keyCode: Int64(ev.keyCode),
                            flags: UInt64(ev.modifierFlags.rawValue))
    }
    return noErr
}

func installRawKeyMonitor() {
    var specs = [
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventRawKeyDown)),
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventRawKeyUp)),
    ]
    InstallEventHandler(GetApplicationEventTarget(), rawKeyHandler, 2, &specs, nil, nil)
}

func currentCombo() -> HotkeyCombo {
    let id = UserDefaults.standard.string(forKey: "carbonCombo") ?? "ctrloptd"
    return kCombos.first { $0.id == id } ?? kCombos[0]
}

// ============================================================
//  錄音指示窗 —— 撳熱鍵即刻彈出，等你知道佢錄緊音
//  2026-10-16 用戶反饋：「我唔知道佢係錄緊」—— 原本置底 + 0.7 秒一閃，
//  根本留意唔到。參考 Spokenly 個小畫面：改置頂中間、三態設計
//  （紅 · 錄音中／橙 · 辨識中／綠 · 已貼上+內容預覽）。
// ============================================================
enum HUDMode: Equatable { case recording, stopping, done }

struct HUDView: View {
    let mode: HUDMode
    let elapsed: String
    let preview: String
    let pasted: Bool
    let pulse: Double
    let levels: [Float]
    let targetApp: String

    private var dotColor: Color {
        switch mode {
        case .recording: return Color(red: 0.20, green: 0.55, blue: 0.40)
        case .stopping:  return Color(red: 0.62, green: 0.55, blue: 0.40)
        case .done:      return Color(red: 0.20, green: 0.55, blue: 0.40)
        }
    }

    private var title: String {
        switch mode {
        case .recording: return "正在錄音"
        case .stopping:  return "轉寫中…"
        case .done:      return pasted ? "已貼上" : "已複製"
        }
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(red: 0.20, green: 0.20, blue: 0.19))
                Spacer(minLength: 0)
                if mode == .recording {
                    Text("再按 \(currentTrigger().name) 停止")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Color(red: 0.48, green: 0.48, blue: 0.46))
                }
            }

            if mode == .recording {
                HUDWave(levels: levels, color: Color(red: 0.30, green: 0.34, blue: 0.32))
            } else if mode == .stopping {
                Text("請稍候，完成後自動貼上文字")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.48, green: 0.48, blue: 0.46))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(preview)
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.35, green: 0.35, blue: 0.34))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(width: 350, height: 98, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.99, green: 0.99, blue: 0.98))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(red: 0.89, green: 0.89, blue: 0.87), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
    }
}

/// 醒目音量波形：30 條 bar 垂直置中，高／色反映即時音量，一講嘢就跳。
/// 用 HStack 默認 center 對齊 → bar 上下對稱生長，似真·音頻波形。
struct HUDWave: View {
    let levels: [Float]
    let color: Color
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<24, id: \.self) { i in
                let db = i < levels.count ? levels[levels.count - 1 - i] : -160
                let norm = max(0.0, min(1.0, (db + 55) / 55))
                let h = 2.0 + norm * 24.0
                let active = norm > 0.12
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(active ? color : color.opacity(0.24))
                    .frame(width: 8, height: CGFloat(h))
            }
        }
        .frame(height: 30)
    }
}

final class RecordingHUD {
    static let shared = RecordingHUD()
    private var panel: NSPanel?
    private var host: NSHostingController<HUDView>?
    private var timer: Timer?
    private var startT = Date()
    private var mode: HUDMode = .recording
    private var preview = ""
    private var pasted = true
    private var hideAt: Date?
    private var hudScreen: NSScreen?

    func show(stopping: Bool = false) {
        if panel == nil { build() }
        hudScreen = activeScreen()
        mode = stopping ? .stopping : .recording
        preview = ""
        hideAt = nil
        if !stopping { startT = Date() }
        restartTimer()
        place()
        panel?.orderFrontRegardless()
    }

    /// 辨識完成：綠色「✓ 已貼上」+ 內容Preview，顯示 1.4 秒先自動收。
    /// 用户實測反饋：「唔知佢錄唔錄到」→ 完成狀態要見到實際輸出先安樂。
    func showDone(_ text: String, pasted: Bool) {
        if panel == nil { build() }
        mode = .done
        self.pasted = pasted
        self.preview = String(text.prefix(30))
        hideAt = Date().addingTimeInterval(1.4)
        hudScreen = activeScreen()
        restartTimer()
        place()
        panel?.orderFrontRegardless()
    }

    func hide() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil)
        hudScreen = nil
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func build() {
        let v = HUDView(mode: .recording, elapsed: "0.0 秒", preview: "", pasted: true, pulse: 0,
                        levels: [], targetApp: Controller.shared.targetApp)
        let h = NSHostingController(rootView: v)
        host = h
        let p = NSPanel(contentViewController: h)
        p.styleMask = [.borderless, .nonactivatingPanel]
        p.isFloatingPanel = true
        // 錄音提示必須蓋過全屏影片／高層級 App，否則用戶會完全不知道正在錄音。
        // HUD 只在錄音與短暫辨識期間顯示，使用 screenSaver 層並加入所有 Space。
        p.level = .screenSaver
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // 固定最小／最大尺寸，防止 NSHostingController 按內容壓縮 HUD，令波形和提示被裁走。
        let hudSize = NSSize(width: 350, height: 98)
        p.setContentSize(hudSize)
        p.minSize = hudSize
        p.maxSize = hudSize
        panel = p
    }

    /// 用戶而家實際睩住嗰塊屏：滑鼠位置（最可靠）> 鎖定 main > main display
    /// 2026-10-16 教訓：用 frontmost app window bounds 會撞到多視窗／跨屏情況，
    /// 算到一啲離屏坐標（例如 -1460, 2316），用戶完全睇唔到。
    /// 2026-10-16 第三輪 feedback：user 話「睇下佢係邊個屏幕就顯示喺邊個屏幕」——
    /// mouse 位置喺 Trackpad 嗰塊屏，但 user 望緊 WorkBuddy 對話（喺另一塊大屏），
    /// HUD 跟 mouse = 擺咗去 user 望唔到嗰塊屏。**Spokenly 嘅做法係跟前台 app 視窗
    /// 嘅 screen**，呢度改用「前前台 App 嘅 main window 喺邊個 CG display」。
    private func activeScreen() -> NSScreen {
        // ① 前台 app 嘅 main window 喺邊個 display（user 望緊嘅嗰塊）
        if let front = NSWorkspace.shared.frontmostApplication,
           (front.localizedName ?? "") != "Dictation" {
            let pid = front.processIdentifier

            // 優先讀取真正的焦點窗口。多屏的 Comet 等 App 可能每塊屏都有同尺寸窗口，
            // 只按最大面積選會受窗口排列順序影響，偶爾把 HUD 放到另一塊屏。
            let axApp = AXUIElementCreateApplication(pid)
            var focusedRef: CFTypeRef?
            let focusedStatus = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedRef)
            if focusedStatus == .success, let focusedRef {
                let focused = focusedRef as! AXUIElement
                var positionRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                let positionStatus = AXUIElementCopyAttributeValue(focused, kAXPositionAttribute as CFString, &positionRef)
                let sizeStatus = AXUIElementCopyAttributeValue(focused, kAXSizeAttribute as CFString, &sizeRef)
                if positionStatus == .success, sizeStatus == .success,
                   let positionRef, let sizeRef,
                   CFGetTypeID(positionRef) == AXValueGetTypeID(),
                   CFGetTypeID(sizeRef) == AXValueGetTypeID() {
                    var origin = CGPoint.zero
                    var size = CGSize.zero
                    let hasOrigin = AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin)
                    let hasSize = AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                    if hasOrigin, hasSize, size.width >= 400, size.height >= 300 {
                        let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
                        for s in NSScreen.screens {
                            if let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                                let display = CGDirectDisplayID(id.uint32Value)
                                if CGDisplayBounds(display).contains(center) {
                                    DLog.w("HUD 跟住前台 App「\(front.localizedName ?? "?")」焦點視窗：display=\(id.uint32Value) center=(\(Int(center.x)),\(Int(center.y)))")
                                    return s
                                }
                            }
                        }
                    }
                }
            }

            // AX 取不到焦點窗口時，才使用最大窗口後備（同尺寸視窗仍可能有歧義）。
            let wins = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as NSArray? as? [[String: Any]] ?? []
            // 揀最大、正常 size 嘅 main window
            var best: (centerX: Double, centerY: Double, area: Double)?
            for w in wins {
                guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
                      let b = w[kCGWindowBounds as String] as? [String: Any],
                      let x = (b["X"] as? NSNumber)?.doubleValue,
                      let y = (b["Y"] as? NSNumber)?.doubleValue,
                      let wd = (b["Width"] as? NSNumber)?.doubleValue,
                      let ht = (b["Height"] as? NSNumber)?.doubleValue,
                      wd >= 400, ht >= 300 else { continue }    // 跳過 toolbar / popup / 細小視窗
                let area = wd * ht
                if best == nil || area > best!.area {
                    best = (x + wd / 2, y + ht / 2, area)
                }
            }
            if let c = best {
                for s in NSScreen.screens {
                    if let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                        let g = CGDisplayBounds(CGDirectDisplayID(id.uint32Value))
                        if c.centerX >= g.minX && c.centerX <= g.maxX &&
                           c.centerY >= g.minY && c.centerY <= g.maxY {
                            DLog.w("HUD 跟住前台 App「\(front.localizedName ?? "?")」喺屏幕 \(Int(s.frame.width))×\(Int(s.frame.height))")
                            return s
                        }
                    }
                }
            }
        }
        // ② fallback: 滑鼠所在屏
        let mouse = NSEvent.mouseLocation
        for s in NSScreen.screens {
            if let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let b = CGDisplayBounds(CGDirectDisplayID(id.uint32Value))
                if mouse.x >= b.minX && mouse.x <= b.maxX &&
                   mouse.y >= b.minY && mouse.y <= b.maxY {
                    return s
                }
            }
        }
        // ③ fallback: main display 嘅 menu bar 鎖定
        return NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main!
    }

    private func place() {
        guard let p = panel else { return }
        let s = activeScreen()
        // 將 NSScreen 嘅 top-left y-down 座標轉去 NSWindow 用嘅 bottom-left y-up 座標
        // （NSScreen 嘅 visibleFrame.minY 已經係 bottom-left 形式，直接用）
        let pf = p.frame
        let vf = s.visibleFrame
        var x = vf.midX - pf.width / 2
        var y = vf.minY + 18   // 屏幕下方（Dock 上面）—— 用戶要似 Spokenly 截圖
        // ③ 離屏保險：算出嚟嘅 origin 如果唔喺該屏幕 visibleFrame 內，強制擺去屏幕正中間
        if !NSMouseInRect(NSPoint(x: x + pf.width/2, y: y + pf.height/2), vf, false) {
            DLog.w("⚠️ 算到離屏坐標 (\(Int(x)),\(Int(y))，改用屏幕正中")
            x = vf.midX - pf.width / 2
            y = vf.midY - pf.height / 2
        }
        let origin = NSPoint(x: x, y: y)
        p.setFrameOrigin(origin)
        DLog.w(String(format: "HUD 位置：屏幕 %.0fx%.0f visibleFrame(%.0f,%.0f,%.0f,%.0f) origin(%.0f,%.0f) 視窗層級=%d",
                      s.frame.width, s.frame.height,
                      vf.minX, vf.minY, vf.maxX, vf.maxY,
                      origin.x, origin.y, p.level.rawValue))
    }


    private func tick() {
        switch mode {
        case .recording:
            let e = Date().timeIntervalSince(startT)
            let pulse = (sin(e * .pi * 4) + 1) / 2   // 每秒 4 下脈動
            host?.rootView = HUDView(mode: .recording, elapsed: String(format: "%.1f 秒", e),
                                     preview: "", pasted: true, pulse: pulse,
                                     levels: Controller.shared.recorderLevels,
                                     targetApp: Controller.shared.targetApp)
        case .stopping:
            host?.rootView = HUDView(mode: .stopping, elapsed: "", preview: "", pasted: true, pulse: 0,
                                     levels: [], targetApp: Controller.shared.targetApp)
        case .done:
            host?.rootView = HUDView(mode: .done, elapsed: "", preview: preview, pasted: pasted, pulse: 0,
                                     levels: [], targetApp: Controller.shared.targetApp)
            if let h = hideAt, Date() >= h { hide() }
        }
    }
}

// ---------------- 路徑 ----------------
let kHome     = NSHomeDirectory()
let kModelDir = kHome + "/.cache/dictation-models"
let kWorkDir  = kHome + "/.cache/dictation-work"
let kLogFile  = kHome + "/.cache/dictation-work/history.log"

// ---------------- 偏好設定 ----------------
enum Prefs {
    static func register() {
        UserDefaults.standard.register(defaults: [
            "trigger": "rcmd",
            "model": "ggml-large-v3-turbo-q5_0.bin",
            "language": "yue",
            "autoPaste": true,
            // 2026-10-16 用戶明確要求「錄我原文」：AI 整理會改写、甚至加埋無關文字。
            // 2026-10-17 用戶補充：「最好理解了先…但要接近我的…可能執字粒啊」
            //   → 預設改成 .polish（只修錯字／標點，保留講法），AI 大改寫要自己開。
            "cleanFillers": false,
            "keepClipboard": true,
            "cleanupEngine": "polish",
        ])
        // 一次性遷移：舊版預設係 none（唔係用戶自己揀嘅）→ 升級做 polish
        let migKey = "didMigratePolish20261017"
        if !UserDefaults.standard.bool(forKey: migKey) {
            UserDefaults.standard.set(true, forKey: migKey)
            if (UserDefaults.standard.string(forKey: "cleanupEngine") ?? "none") == "none" {
                UserDefaults.standard.set("polish", forKey: "cleanupEngine")
            }
        }
    }
    static var trigger: String {
        get { UserDefaults.standard.string(forKey: "trigger") ?? "rcmd" }
        set { UserDefaults.standard.set(newValue, forKey: "trigger") }
    }
    /// 觸發模式：toggle = 撳一次開始／再撳一次完結（預設，用戶 2026-10-16 要求）；
    /// hold = 撳住講、鬆手完結（Spokenly 風格）
    static var triggerMode: String {
        get { UserDefaults.standard.string(forKey: "triggerMode") ?? "toggle" }
        set { UserDefaults.standard.set(newValue, forKey: "triggerMode") }
    }
    static var model: String {
        get { UserDefaults.standard.string(forKey: "model") ?? "ggml-large-v3-turbo-q5_0.bin" }
        set { UserDefaults.standard.set(newValue, forKey: "model") }
    }
    static var language: String {
        get { UserDefaults.standard.string(forKey: "language") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "language") }
    }
    static var autoPaste: Bool {
        get { UserDefaults.standard.bool(forKey: "autoPaste") }
        set { UserDefaults.standard.set(newValue, forKey: "autoPaste") }
    }
    /// 錄音時自動靜音其他聲音（睇片／聽歌唔會漏入咪，亦唔會嘈住你講）
    /// 預設開 —— 同 Spokenly 一樣。第一次讀唔到 key 就當 true。
    static var muteOthers: Bool {
        get {
            if UserDefaults.standard.object(forKey: "muteOthers") == nil { return true }
            return UserDefaults.standard.bool(forKey: "muteOthers")
        }
        set { UserDefaults.standard.set(newValue, forKey: "muteOthers") }
    }
    static var cleanFillers: Bool {
        get { UserDefaults.standard.bool(forKey: "cleanFillers") }
        set { UserDefaults.standard.set(newValue, forKey: "cleanFillers") }
    }
    static var keepClipboard: Bool {
        get { UserDefaults.standard.bool(forKey: "keepClipboard") }
        set { UserDefaults.standard.set(newValue, forKey: "keepClipboard") }
    }
    /// 清理引擎：polish = 執字粒（預設）；deepseek = 執字粒 + 雲端改錯字；
    /// none = 原文；apple / gpt4omini = AI 大改寫
    static var cleanupEngine: String {
        get { UserDefaults.standard.string(forKey: "cleanupEngine") ?? "polish" }
        set { UserDefaults.standard.set(newValue, forKey: "cleanupEngine") }
    }
    /// DeepSeek 模型 id。官方現行對話模型係 `deepseek-flash`（= DeepSeek-V4.1-Flash）。
    /// 舊名 `deepseek-v4-flash` 仍然接受（會轉去同一個模型）。
    static var deepseekModel: String {
        get {
            let v = UserDefaults.standard.string(forKey: "deepseekModel") ?? ""
            return v.isEmpty ? "deepseek-flash" : v
        }
        set { UserDefaults.standard.set(newValue, forKey: "deepseekModel") }
    }
    /// DeepSeek 力度：strict = 執字粒（字數必須一樣）；light = 輕整理（讀得通少少，但唔可以加料）
    static var deepseekMode: String {
        get {
            let v = UserDefaults.standard.string(forKey: "deepseekMode") ?? ""
            return v.isEmpty ? "light" : v
        }
        set { UserDefaults.standard.set(newValue, forKey: "deepseekMode") }
    }
    /// 保留度（%）：要求 AI 保留原文意思同用字嘅程度。80 / 85 / 90 / 95，預設 90。
    /// 數值越高＝越貼近原話；越低＝整理得越順但改動越多。
    static var fidelity: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "fidelity")
            return v == 0 ? 90 : v
        }
        set { UserDefaults.standard.set(newValue, forKey: "fidelity") }
    }
}

enum CleanupEngine: String, CaseIterable {
    case polish
    case deepseek
    case none
    case apple
    case gpt4omini

    var label: String {
        switch self {
        case .polish:   return "✨ 執字粒 · 純規則（預設）"
        case .deepseek: return "🧠 執字粒 · DeepSeek 改錯字（要 key）"
        case .none:     return "🚫 唔整理 · 用返你原文"
        case .apple:    return "🍎 Apple AI 大整理（會改寫句子）"
        case .gpt4omini: return "🤖 GPT-4o mini 整理（OpenAI，逐次計費）"
        }
    }

    /// 一段簡短說明，顯示喺選單下面
    var hint: String {
        switch self {
        case .polish:
            return "讀得通，但用返你原本嘅講法：清走「嗯／呃」同口吃重複、修標點同多餘空格。唔換詞、唔改句、唔加內容，完全離線、零風險。"
        case .deepseek:
            return "規則層之後，再叫 DeepSeek V4.1-Flash 改同音錯字（我地→我哋、體體→睇睇）。有「執字粒／輕整理」兩級力度；改動太大自動退回規則版。文字會送去 DeepSeek 雲端。"
        case .none:
            return "Whisper 出咩就貼咩，一個字都唔改。"
        case .apple:
            return "Apple 內建 AI 會改寫成通順句子 — 讀得最舒服，但可能唔再係你原本嘅字。"
        case .gpt4omini:
            return "同上一項一樣會改寫，但用 OpenAI 雲端模型（逐次計費）。"
        }
    }

    static var current: CleanupEngine {
        CleanupEngine(rawValue: Prefs.cleanupEngine) ?? .polish
    }
}

// ---------------- API key 存放 ----------------
/// 一個 key 一個檔案，權限 600，只留喺自己部機。
struct ApiKeyStore {
    let path: String

    func get() -> String? {
        guard let d = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let t = d.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    @discardableResult
    func save(_ key: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: kWorkDir, withIntermediateDirectories: true)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try trimmed.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch { return false }
    }

    func mask() -> String? {
        guard let k = get() else { return nil }
        let n = k.count
        guard n > 10 else { return "sk-…（長度可疑）" }
        return k.prefix(7) + "…" + k.suffix(4) + "（共 \(n) 位）"
    }
}

enum KeyStore {
    static let path = kWorkDir + "/openai_key"
    static let openai   = ApiKeyStore(path: path)
    static let deepseek = ApiKeyStore(path: kWorkDir + "/deepseek_key")

    static func get() -> String? { openai.get() }
    @discardableResult static func save(_ key: String) -> Bool { openai.save(key) }
    static func mask() -> String? { openai.mask() }
}

// ---------------- 觸發鍵定義 ----------------
struct TriggerKey {
    let id: String
    let name: String
    /// 左右兩邊嘅 keycode 都收 —— 用戶嘅期望係「揀 Option 就撳邊便 Option 都得」
    let keyCodes: Set<Int64>
    let flag: CGEventFlags
}

let kTriggers: [TriggerKey] = [
    TriggerKey(id: "fn",     name: "Fn 鍵",       keyCodes: [63],       flag: .maskSecondaryFn),
    TriggerKey(id: "rcmd",   name: "Command",     keyCodes: [54, 55],   flag: .maskCommand),
    TriggerKey(id: "ropt",   name: "Option",      keyCodes: [61, 58],   flag: .maskAlternate),
    TriggerKey(id: "rshift", name: "Shift",       keyCodes: [60, 56],   flag: .maskShift),
    TriggerKey(id: "rctrl",  name: "Control",     keyCodes: [62, 59],   flag: .maskControl),
]

/// 所有修飾鍵 keycode —— 用嚟診斷「用戶撳咗但觸發鍵冇反應」
let kModifierCodes: Set<Int64> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

func currentTrigger() -> TriggerKey {
    return kTriggers.first { $0.id == Prefs.trigger } ?? kTriggers[0]
}

// ---------------- 語言選項 ----------------
let kLanguages: [(String, String)] = [
    ("auto", "自動偵測"),
    ("yue",  "廣東話（繁體中文）"),
    ("zh",   "普通話（簡體中文）"),
    ("en",   "English"),
    ("ja",   "日本語"),
    ("ko",   "한국어"),
]

/// 語言代碼 → 顯示名
func languageName(_ code: String) -> String {
    kLanguages.first(where: { $0.0 == code })?.1 ?? code
}

/// DeepSeek 可選模型（2026-10-17 官方只有兩個；`deepseek-flash` = DeepSeek-V4.1-Flash）
let kDeepSeekModels: [(String, String)] = [
    ("deepseek-flash",  "DeepSeek-V4.1-Flash（建議 · 最快最平）"),
    ("deepseek-v4-pro", "DeepSeek-V4-Pro（更強 · 貴幾倍）"),
]

/// 模型 id → 顯示名
func deepseekModelName(_ id: String) -> String {
    kDeepSeekModels.first(where: { $0.0 == id })?.1 ?? id
}

// ---------------- 外部工具 ----------------
func findWhisperCLI() -> String? {
    let candidates = [
        "/opt/homebrew/bin/whisper-cli",
        "/usr/local/bin/whisper-cli",
        "/opt/homebrew/bin/whisper-cpp",
        "/usr/local/bin/whisper-cpp",
    ]
    for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
    return nil
}

func availableModels() -> [String] {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(atPath: kModelDir) else { return [] }
    return items.filter { $0.hasSuffix(".bin") }.sorted()
}

// ---------------- 錄音 ----------------
final class Recorder {
    private var recorder: AVAudioRecorder?
    private(set) var rawURL: URL?
    private var meterTimer: Timer?
    /// 錄音期間最高音量（dB，0 = 最大，-160 = 靜音）。用來判斷有冇人講嘢
    var peakLevel: Float = -160
    /// 最近嘅音量歷史（dB）—— 用嚟畫 HUD 波形
    private(set) var levels: [Float] = []

    func start() throws {
        try? FileManager.default.createDirectory(atPath: kWorkDir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: kWorkDir + "/rec.wav")
        try? FileManager.default.removeItem(at: url)

        // 直接錄成 16kHz 單聲道 16-bit PCM —— whisper.cpp 要嘅格式
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        r.prepareToRecord()
        peakLevel = -160
        levels = []
        guard r.record() else {
            throw NSError(domain: "Dictation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "錄音啟動失敗"])
        }
        recorder = r
        rawURL = url

        // 每 0.1 秒量度音量
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let r = self.recorder else { return }
            r.updateMeters()
            let p = r.averagePower(forChannel: 0)
            if p > self.peakLevel { self.peakLevel = p }
            // 留最近 30 個取樣畫波形
            self.levels.append(p)
            if self.levels.count > 30 { self.levels.removeFirst(self.levels.count - 30) }
        }
    }

    func stop() -> URL? {
        meterTimer?.invalidate(); meterTimer = nil
        recorder?.stop()
        recorder = nil
        guard let url = rawURL else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// ---------------- 辨識 ----------------
final class Transcriber {
    /// 用 afconvert 正規化成 16kHz / mono / 16-bit PCM（保險）
    private func normalize(_ src: URL) -> URL {
        let out = URL(fileURLWithPath: kWorkDir + "/norm.wav")
        try? FileManager.default.removeItem(at: out)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                       src.path, out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return src }
        if p.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) {
            return out
        }
        return src
    }

    func transcribe(wav: URL, completion: @escaping (String?) -> Void) {
        guard let cli = findWhisperCLI() else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let modelPath = kModelDir + "/" + Prefs.model
        guard FileManager.default.fileExists(atPath: modelPath) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let input = self.normalize(wav)

            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = [
                "-m", modelPath,
                "-f", input.path,
                "-l", Prefs.language,
                "-nt",        // 唔要時間戳
                "-np",        // 唔要雜訊輸出
                "-sns",       // 壓制非語音標記（減少靜音幻覺）
                "-t", "8",    // 8 線程
            ]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice

            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                var text = String(data: data, encoding: .utf8) ?? ""
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // 清走 whisper 偶爾出嘅 [BLANK_AUDIO] / (音樂) 之類標記
                if text.contains("[BLANK_AUDIO]") || text.contains("[ Silence ]") { text = "" }
                text = text.replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async { completion(text.isEmpty ? nil : text) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
}

// ---------------- 音效（開始／停止提示音） ----------------
/// 用 AVAudioEngine 即場生成兩個短音，唔依賴系統音效檔（macOS 改版改名都唔怕）。
/// 用戶 2026-10-17 要求：「按 Option 開始時畀一點點音效，錄完再按 Option 都畀一點」。
final class SoundFX {
    static let shared = SoundFX()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var ready = false
    private let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    /// 預熱：第一次播音會有幾十毫秒延遲，所以 app 啟動時先叫一次
    func prepare() {
        guard !ready else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = 0.22     // 「一點點」就夠，唔好嘈親人
        do { try engine.start(); ready = true }
        catch { DLog.w("音效引擎起唔到：\(error.localizedDescription)") }
    }

    /// 單音：正弦波 + 6ms 淡入 / 20ms 淡出（避免爆音 click）
    private func tone(_ freq: Double, _ dur: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(fmt.sampleRate * dur)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        guard let ch = buf.floatChannelData?[0] else { return nil }
        let sr = fmt.sampleRate
        for i in 0..<Int(frames) {
            let t = Double(i) / sr
            let attack  = min(1.0, t / 0.006)
            let release = min(1.0, (dur - t) / 0.02)
            let env = max(0, min(attack, release))
            ch[i] = Float(sin(2 * Double.pi * freq * t) * 0.6 * env)
        }
        return buf
    }

    /// 開始錄音：兩個音向上（E5 → B5），清脆、有「開始」感
    func playStart() { play([(660, 0.05), (990, 0.075)]) }
    /// 停止錄音：向下（B5 → E5），有「收工」感
    func playStop()  { play([(990, 0.05), (660, 0.075)]) }

    private func play(_ notes: [(Double, Double)]) {
        prepare()
        guard ready else { return }
        // 換過輸出裝置（插耳機／拔耳機）之後 engine 會自己停，`ready` 仍然係 true，
        // 唔重啟就會靜靜地冇聲。所以每次播之前都確認一次。
        if !engine.isRunning {
            do { try engine.start() } catch {
                DLog.w("音效引擎重啟失敗：\(error.localizedDescription)")
                return
            }
        }
        for (f, d) in notes {
            if let b = tone(f, d) { player.scheduleBuffer(b, completionHandler: nil) }
        }
        if !player.isPlaying { player.play() }
    }
}

// ---------------- 錄音時靜音其他聲音 ----------------
/// 用戶 2026-10-18：「錄音嘅時候，佢自己會 mute 咗其他聲音…Spokenly 有呢個功能」
///
/// 做法：用 CoreAudio HAL 將**預設輸出裝置**靜音，錄完即刻還原。
///
/// 點解唔逐個 App 靜音？macOS 14.4 起雖然有 `AudioHardwareCreateProcessTap`
/// 可以逐個 process mute，但要用 aggregate device，對「錄音時唔想有聲」呢個需求
/// 嚟講太重。整機靜音 100% 可靠、零權限、即時生效。
///
/// 三條保險，防止「靜音之後冇還原」（最痛嘅後果：部機從此冇聲）：
///   ① 錄完即刻還原 —— 而且**喺播停止音之前**，所以聽得到提示音
///   ② App 結束（applicationWillTerminate）再還原一次
///   ③ 靜音前先將原本音量寫落 `~/.cache/dictation-work/muted.json`；
///      下次啟動見到呢個檔就即刻還原（crash／強制退出／拔電都救得返）
enum SystemAudio {
    /// 一組「還原資訊」
    struct Saved {
        let device: UInt32
        let muted: Bool?                    // 用 mute 屬性（nil = 唔支援，改用 volume）
        let volumes: [UInt32: Float32]      // element → 原本音量
    }

    private static var active: [UInt32: Saved] = [:]
    private static var mutedAt: Date?          // 幾時開始靜音（用嚟擋住 timer 搶先一步）
    private static let statePath = kWorkDir + "/muted.json"

    // MARK: - 基本 HAL 讀寫

    static func defaultOutput() -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return (err == noErr && dev != 0) ? dev : nil
    }

    private static func addr(_ sel: AudioObjectPropertySelector, _ el: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel,
                                   mScope: kAudioObjectPropertyScopeOutput,
                                   mElement: el)
    }

    private static func getMute(_ dev: UInt32) -> Bool? {
        var a = addr(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(AudioObjectID(dev), &a) else { return nil }
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(dev), &a, 0, nil, &size, &v)
        return err == noErr ? (v != 0) : nil
    }

    @discardableResult
    private static func setMute(_ dev: UInt32, _ on: Bool) -> Bool {
        var a = addr(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(AudioObjectID(dev), &a) else { return false }
        var v: UInt32 = on ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(AudioObjectID(dev), &a, 0, nil, size, &v) == noErr
    }

    private static func getVolume(_ dev: UInt32, _ el: UInt32) -> Float32? {
        var a = addr(kAudioDevicePropertyVolumeScalar, el)
        guard AudioObjectHasProperty(AudioObjectID(dev), &a) else { return nil }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(dev), &a, 0, nil, &size, &v)
        return err == noErr ? v : nil
    }

    @discardableResult
    private static func setVolume(_ dev: UInt32, _ el: UInt32, _ v: Float32) -> Bool {
        var a = addr(kAudioDevicePropertyVolumeScalar, el)
        guard AudioObjectHasProperty(AudioObjectID(dev), &a) else { return false }
        var val = v
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(AudioObjectID(dev), &a, 0, nil, size, &val) == noErr
    }

    /// 有啲裝置（AirPods／HDMI／部分 USB DAC）冇 main element，要逐條 channel 改
    private static func elements(_ dev: UInt32) -> [UInt32] {
        if getVolume(dev, kAudioObjectPropertyElementMain) != nil {
            return [kAudioObjectPropertyElementMain]
        }
        return [1, 2].filter { getVolume(dev, $0) != nil }
    }

    // MARK: - 靜音 / 還原

    @discardableResult
    static func mute(_ dev: UInt32) -> Bool {
        if active[dev] != nil { return true }          // 已經處理過
        // 首選 mute 屬性：唔會改動用戶設定嘅音量數字
        if let m = getMute(dev), setMute(dev, true) {
            active[dev] = Saved(device: dev, muted: m, volumes: [:])
            return true
        }
        // 次選：音量歸零
        var vols: [UInt32: Float32] = [:]
        var ok = false
        for el in elements(dev) {
            if let v = getVolume(dev, el) {
                vols[el] = v
                if setVolume(dev, el, 0) { ok = true }
            }
        }
        if ok {
            active[dev] = Saved(device: dev, muted: nil, volumes: vols)
        } else {
            DLog.w("⚠️ 靜音失敗：裝置 \(dev) 冇 mute 亦冇 volume 屬性")
        }
        return ok
    }

    static func restore(_ dev: UInt32) {
        guard let s = active[dev] else { return }
        if let m = s.muted {
            setMute(dev, m)
        }
        for (el, v) in s.volumes {
            // 用戶喺錄音期間自己調過音量 → 尊重佢，唔還原
            if let now = getVolume(dev, el), now > 0.001 { continue }
            setVolume(dev, el, v)
        }
        active[dev] = nil
        if active.isEmpty { mutedAt = nil }
    }

    /// 開始錄音時叫：靜音目前嘅預設輸出裝置
    static func muteForRecording() {
        guard let dev = defaultOutput() else {
            DLog.w("⚠️ 搵唔到預設輸出裝置，唔靜音")
            return
        }
        guard active[dev] == nil else { return }   // 0.7 秒 timer 快一步靜咗，唔好重複
        if mute(dev) {
            mutedAt = Date()
            persist()
            DLog.w("🔇 已靜音其他聲音（device \(dev)）")
        }
    }

    /// 錄完叫：全部還原
    static func restoreAfterRecording() {
        guard !active.isEmpty else { return }
        for dev in Array(active.keys) { restore(dev) }
        mutedAt = nil
        clearPersist()
        DLog.w("🔊 已還原聲音")
    }

    /// 錄音期間每 0.7 秒叫一次：換咗輸出裝置（插耳機／AirPods）就順手靜音埋新嗰個
    static func ensureCurrentDeviceMuted() {
        // 頭 0.8 秒唔好做嘢 —— beginRecording 會喺 0.14 秒後自己靜音，
        // 呢個 timer 搶先嘅話就會誤報「換咗輸出裝置」。
        guard let t = mutedAt, Date().timeIntervalSince(t) > 0.8 else { return }
        guard let dev = defaultOutput() else { return }
        if active[dev] == nil, mute(dev) {
            persist()
            DLog.w("🔇 換咗輸出裝置，已靜音新裝置（device \(dev)）")
        }
    }

    static var isMuted: Bool { !active.isEmpty }

    /// 自測用：一句講晒目前裝置嘅狀態
    static func describe(_ dev: UInt32) -> String {
        let m = getMute(dev).map { $0 ? "mute" : "unmute" } ?? "冇 mute 屬性"
        var vols: [String] = []
        for el in elements(dev) {
            if let v = getVolume(dev, el) { vols.append("el\(el)=\(String(format: "%.2f", v))") }
        }
        return "device \(dev) · \(m) · \(vols.isEmpty ? "冇 volume 屬性" : vols.joined(separator: " "))"
    }

    // MARK: - Crash 保險

    private static func persist() {
        var obj: [String: Any] = [:]
        for (dev, s) in active {
            var d: [String: Any] = [:]
            if let m = s.muted { d["muted"] = m }
            if !s.volumes.isEmpty {
                var v: [String: Double] = [:]
                for (el, val) in s.volumes { v[String(el)] = Double(val) }
                d["volumes"] = v
            }
            obj[String(dev)] = d
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? data.write(to: URL(fileURLWithPath: statePath))
    }

    private static func clearPersist() {
        try? FileManager.default.removeItem(atPath: statePath)
    }

    /// App 啟動時叫：上次如果死喺錄音中途，幫佢還原
    static func recoverFromCrash() {
        guard let data = FileManager.default.contents(atPath: statePath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for (key, value) in obj {
            guard let dev = UInt32(key), let d = value as? [String: Any] else { continue }
            if let m = d["muted"] as? Bool { setMute(dev, m) }
            if let vols = d["volumes"] as? [String: Double] {
                for (el, val) in vols {
                    if let e = UInt32(el) { setVolume(dev, e, Float32(val)) }
                }
            }
            DLog.w("🩹 救返上次未還原嘅靜音（device \(dev)）")
        }
        clearPersist()
    }
}

// ---------------- 文字清理 ----------------
enum CleanService {
    /// 入口：先做安全嘅規則整理，再按設定交畀 AI
    static func run(_ input: String, completion: @escaping (String) -> Void) {
        // 雜訊幻覺：Whisper 對住底噪會吐出「PENGASPEN」「PAUSE」「NARAT」呢類
        // 全大寫英文字（2026-10-17 history.log 實測出現多次）。呢啲唔係用戶講嘅嘢，
        // 直接當冇講過，唔好貼一堆亂碼出嚟。
        if isGarbage(input) {
            DLog.w("過濾雜訊幻覺：\(input)")
            completion("")
            return
        }

        let engine = CleanupEngine.current

        // 「唔整理」= 唔整理文字內容（但字形仍然要跟「輸出語言」）
        if engine == .none {
            completion(applyScript(input.trimmingCharacters(in: .whitespacesAndNewlines)))
            return
        }

        var text = input
        switch engine {
        case .none:
            break
        case .polish, .deepseek:
            text = tidyText(text)          // 純規則、零風險嘅「執字粒」
        case .apple, .gpt4omini:
            if Prefs.cleanFillers { text = cleanFillers(text) }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 🔴 字形最後把關：Whisper 對粵語偶爾會吐簡體字（實測 history.log 有
        //    「处理好了个版链了」），用戶揀咗繁體就一定要出繁體。
        text = applyScript(text)
        guard !text.isEmpty else { completion(""); return }

        switch engine {
        case .none:
            completion(text)
        case .polish:
            // 2026-10-17 實測：Apple 本機 AI 做唔到「只執字」——
            //   ① 叫佢校對，佢原樣照抄（一個錯字都唔改）；
            //   ② 換個寫法叫佢照抄，佢就自己重作（「幫我睇下個報告有冇問題」
            //      → 變成一段 237 字嘅假回覆）；
            //   ③ 有時仲會偷偷加字（「我今日」→「今日我今日」）。
            // 所以純規則執字粒唔經 AI：快、離線、可預測、一個字都唔會亂加。
            completion(text)
        case .deepseek:
            // 🔴 AI 嘅輸出一定要再過一次字形：模型偶爾會無視「必須繁體」嘅指令，
            //    直接吐簡體（用戶 2026-10-17 報嘅正正係呢個）。呢一層係最後防線，
            //    而且 CFStringTransform 對本身已正確嘅字形完全冇影響（idempotent）。
            cleanWithDeepSeek(text) { out in completion(applyScript(out)) }
        case .apple:
            cleanWithApple(text) { out in completion(applyScript(out)) }
        case .gpt4omini:
            cleanWithGPT4oMini(text) { out in completion(applyScript(out)) }
        }
    }

    // ---------------- 執字粒（規則層） ----------------
    /// 「執字粒」第一步：純規則、零風險嘅修正。
    /// 只做四件事：① 口吃重複字 ② 獨立填充詞 ③ 多餘空格 ④ 半角標點轉全角。
    /// 絕不換詞、絕不改句、絕不加內容。
    static func tidyText(_ input: String) -> String {
        var t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return t }

        // ① 口吃重複：只限「重複咗一定冇意思」嘅虛詞。
        //    ⚠️ 唔可以一刀切 collapse 所有重複中文字 —— 會整爛「看看／慢慢／謝謝／剛剛／聽聽」。
        let stutterChars = ["我", "你", "佢", "係", "唔", "咁", "就", "但", "同", "嘅",
                            "喺", "嗰", "呢", "啲", "即", "都", "要", "會", "有", "冇"]
        for c in stutterChars {
            t = t.replacingOccurrences(of: "\(c){2,}", with: c, options: [.regularExpression])
        }
        // 英文口吃（I I / the the）
        t = t.replacingOccurrences(of: "\\b(\\w+)(\\s+\\1\\b)+", with: "$1",
                                   options: [.regularExpression, .caseInsensitive])
        // 連環填充（「嗯嗯嗯」「呃呃」）→ 先壓做一個，下面嘅規則先清得走
        t = t.replacingOccurrences(of: "(嗯|呃|哦|喔|呀)\\1{1,}", with: "$1", options: [.regularExpression])

        // ② 填充詞：重複掃幾次（「嗯，呃，」呢種連環填充要逐個拆）
        for _ in 0..<3 {
            // 連住逗號嘅（「嗯，」「呃、」）→ 連標點一齊清
            t = t.replacingOccurrences(of: "(^|[，。！？；：\\s])(嗯|呃|哦|喔|er|erm|um|uh)[，,、]\\s*",
                                       with: "$1", options: [.regularExpression, .caseInsensitive])
            // 獨立一個字夾喺標點中間嘅
            t = t.replacingOccurrences(of: "(^|[，。！？、；：\\s])(嗯|呃|哦|喔|呀|啊|er|erm|um|uh|ah)(?=[，。！？、；：\\s]|$)",
                                       with: "$1", options: [.regularExpression, .caseInsensitive])
        }
        // 清到開頭留低嘅標點
        t = t.replacingOccurrences(of: "^[，、。；：\\s]+", with: "", options: [.regularExpression])

        // ③ 空格：中文字之間嘅空格全清（Whisper 偶爾會插）
        t = t.replacingOccurrences(of: "(?<=[\\u4e00-\\u9fa5])[ \\t]+(?=[\\u4e00-\\u9fa5])", with: "", options: [.regularExpression])
        // 標點前面嘅空格
        t = t.replacingOccurrences(of: "[ \\t]+([，。！？、；：）」』])", with: "$1", options: [.regularExpression])
        // 中文標點後面嘅空格（「， 係」→「，係」）
        t = t.replacingOccurrences(of: "(?<=[，。！？、；：])[ \\t]+(?=[\\u4e00-\\u9fa5])", with: "", options: [.regularExpression])
        // 多餘連續空格
        t = t.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: [.regularExpression])

        // ④ 半角標點 → 全角（只喺中文字旁邊轉，英文句子唔受影響）
        let halfToFull: [(String, String)] = [(",", "，"), ("?", "？"), ("!", "！"), (";", "；"), (":", "：")]
        for (h, f) in halfToFull {
            let esc = NSRegularExpression.escapedPattern(for: h)
            t = t.replacingOccurrences(of: "(?<=[\\u4e00-\\u9fa5])\(esc)", with: f, options: [.regularExpression])
            t = t.replacingOccurrences(of: "\(esc)(?=[\\u4e00-\\u9fa5])", with: f, options: [.regularExpression])
        }
        // 英文句號前後唔好亂轉（. 唔處理，避免整爛小數同網址）

        // 半角轉全角之後再清一次「， 係」型空格（原本係半角逗號，上面條規則捉唔到）
        t = t.replacingOccurrences(of: "(?<=[，。！？、；：])[ \\t]+(?=[\\u4e00-\\u9fa5])", with: "", options: [.regularExpression])

        // 收尾：清走句尾多餘空白
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // 句尾如果係逗號／頓號 → 改句號（講完一句但 Whisper 收尾錯）
        if let last = t.last, last == "，" || last == "、" {
            t = String(t.dropLast()) + "。"
        }
        return t
    }

    /// 雜訊幻覺判斷：冇中文／日文／韓文，又冇任何細楷字母，又有大楷字母 → 幻覺簽名。
    /// 純數字（「1234」）唔算，因為可能真係講數字。
    static func isGarbage(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        let hasCJK = t.unicodeScalars.contains { u in
            (0x4E00...0x9FFF).contains(u.value)      // 中日韓統一表意文字
                || (0x3040...0x30FF).contains(u.value)   // 日文假名
                || (0xAC00...0xD7AF).contains(u.value)   // 韓文
        }
        if hasCJK { return false }
        guard t.count <= 20 else { return false }
        let hasUpper = t.contains { $0.isUppercase }
        let hasLower = t.contains { $0.isLowercase }
        return hasUpper && !hasLower
    }

    /// 比較用：只留字母數字（中文都算字母），去掉標點同空白
    static func normalizeForCompare(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// 把文字統一到簡體字形（純粹為咗比較，唔會影響輸出）
    static func scriptNeutral(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        let m = NSMutableString(string: s)
        guard CFStringTransform(m, nil, "Hant-Hans" as CFString, false) else { return s }
        return m as String
    }

    /// 按「輸出語言」統一字形。用 macOS 內建 ICU（CFStringTransform），完全離線、零成本。
    /// 用戶 2026-10-17：「我揀咗廣東話繁體，但出嚟仲係簡體」—— Whisper 對粵語偶爾會吐
    /// 簡體字，所以貼出去之前一定要強制轉一次。實測 ICU 連「头发」都識轉做「頭髮」，
    /// 而對本身已經係繁體嘅文字完全冇影響（idempotent）。
    static func applyScript(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        let id: String
        switch Prefs.language {
        case "yue": id = "Hans-Hant"     // 簡 → 繁（香港）
        case "zh":  id = "Hant-Hans"     // 繁 → 簡
        default:    return s             // 英文／日文／韓文／自動：唔動字形
        }
        let m = NSMutableString(string: s)
        guard CFStringTransform(m, nil, id as CFString, false) else { return s }
        let out = m as String
        if out != s { DLog.w("字形轉換（\(Prefs.language)）：\(s) → \(out)") }
        return out
    }

    /// 最長公共子序列比例（0...1）
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        if x.isEmpty && y.isEmpty { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = [Int](repeating: 0, count: y.count + 1)
        var cur  = prev
        for i in 1...x.count {
            for j in 1...y.count {
                cur[j] = (x[i - 1] == y[j - 1]) ? prev[j - 1] + 1 : max(prev[j], cur[j - 1])
            }
            prev = cur
        }
        return 2.0 * Double(prev[y.count]) / Double(x.count + y.count)
    }

    /// 雲端整理結果嘅守門。寧願退回規則版，都唔好貼一段唔係你講嘅嘢。
    ///
    /// 判斷邏輯（2026-10-17 重寫）：
    /// ① **字數一樣** → 模型只可能「換字」（改錯字、繁簡轉字形），唔可能加料或刪句，
    ///    所以只要唔係面目全非（LCS ≥ 0.40）就接受。呢條係最重要嘅一條：
    ///    繁體轉換會令大量字元唔同，用「逐位改動百分比」判斷會全部誤殺。
    /// ② **字數有變** → 用「保留度」門檻：保留度越高，要求越貼近原文。
    /// ③ 執字粒（strict）額外要求字數必須一樣。
    static func acceptRewrite(_ out: String, original: String, strict: Bool) -> Bool {
        // ⚠️ 比較前一定要把兩邊字形統一：繁簡轉換會令大量字元唔同，
        //    唔統一就會把「正確嘅繁體輸出」當成「改得太多」而誤殺
        //    （實測：简体→繁体 lcs 只有 0.53，90% 門檻 0.86 直接退回）。
        let a = scriptNeutral(normalizeForCompare(out))
        let b = scriptNeutral(normalizeForCompare(original))
        guard !a.isEmpty, !b.isEmpty else { return false }

        if strict && a.count != b.count {
            DLog.w("deepseek 退回：執字粒要求字數一樣（原文 \(b.count) / AI \(a.count)）")
            return false
        }

        let lcs = similarity(a, b)

        if a.count == b.count {
            guard lcs >= 0.40 else {
                DLog.w(String(format: "deepseek 退回：字數一樣但改得太多（lcs=%.2f）", lcs))
                return false
            }
            return true
        }

        let (minLcs, tol) = fidelityThresholds()
        let ratio = Double(a.count) / Double(b.count)
        guard ratio >= 1 - tol, ratio <= 1 + tol, lcs >= minLcs else {
            DLog.w(String(format: "deepseek 退回：保留度 %d%% 要求 lcs≥%.2f len±%.0f%%（實際 lcs=%.2f len=%.2f）",
                         Prefs.fidelity, minLcs, tol * 100, lcs, ratio))
            return false
        }
        return true
    }

    /// 保留度 → (最低相似度, 長度容差)
    /// 實測校準：「我今日想講嘅係…」→「今日我哋要講嘅係…」lcs=0.828，
    /// 90% 要擋得住（所以門檻 0.86），95% 更加唔使講；80% 才會放行呢種改動。
    static func fidelityThresholds() -> (Double, Double) {
        switch Prefs.fidelity {
        case 95...: return (0.92, 0.08)
        case 90...: return (0.86, 0.14)
        case 85...: return (0.80, 0.20)
        default:    return (0.72, 0.28)
        }
    }

    // ---------------- DeepSeek（執字粒 + 改錯字） ----------------
    /// 官方 OpenAI 相容端點。模型 id：`deepseek-flash`（= DeepSeek-V4.1-Flash）。
    /// ⚠️ V4 預設開「思考模式」，唔關掉會慢幾秒又出 reasoning，所以一定要
    ///    送 `"thinking": {"type": "disabled"}`。
    static let deepseekURL = "https://api.deepseek.com/chat/completions"

    /// 輸出語言／字形規則 —— 用戶揀咩就出咩，唔准擅自轉換。
    static func languageRule() -> String {
        switch Prefs.language {
        case "yue":
            return """
            輸出語言：繁體中文（香港）。必須全部用繁體字，唔可以出現簡體字；
            粵語口語用字要原樣保留（係、唔、嘅、咗、啲、喺、嗰、咁、冇、睇、俾、嚟、嘢），
            唔好轉做普通話書面語。
            """
        case "zh":
            return "輸出語言：簡體中文（普通話）。必須全部用簡體字，唔可以出現繁體字。"
        case "en":
            return "Output language: English. Write the whole result in English."
        case "ja":
            return "出力言語：日本語。"
        case "ko":
            return "출력 언어: 한국어."
        default:
            return """
            輸出語言同字形要跟返原文：原文係繁體就出繁體，簡體就出簡體，英文就英文，
            唔好擅自轉換字形或者翻譯。
            """
        }
    }

    static func deepseekPrompt(strict: Bool) -> String {
        let lang = languageRule()
        let keep = "中英夾雜嘅內容（產品名、英文詞組、數字、專有名詞）要原樣保留，唔好翻譯、唔好加中文解釋。"

        if strict {
            return """
            你係語音辨識嘅校對器，工作只係「執字粒」。輸入係一段口語嘅辨識結果。
            你只可以做三件事：
            1. 改返同音／近音嘅錯別字（例：我地→我哋、佢地→佢哋、體體→睇睇）；
            2. 修正標點；
            3. 按下面嘅字形要求轉換字形（例如原文出咗簡體字，要轉做繁體）。
            嚴禁：改寫句子、換用詞、改語序、刪走句子、加任何內容、翻譯、總結、解釋、
            加標題或引號。
            \(lang)
            \(keep)
            輸出嘅字數必須同輸入完全一樣（轉字形唔會改變字數）。
            只輸出 JSON，格式：{"text":"校對後嘅文字"}
            """
        }
        return """
        你係語音辨識嘅文字整理器。輸入係一段口語嘅辨識結果。
        目標：令句子讀得通順，但必須保留講者原本嘅意思同用字。
        可以做：改錯別字、補標點同分段、刪重複同口語贅字、理順明顯亂咗嘅語序、
        按下面嘅字形要求轉換字形。
        嚴禁：加入原文冇嘅資訊、總結、擴寫、回答內容、翻譯、加標題、加解釋、加任何客套話。
        \(lang)
        \(keep)
        保留原文用字嘅程度：至少 \(Prefs.fidelity)%。即係話，除咗錯別字、標點、明顯重複之外，
        盡量唔好改動原文用詞同語序。
        只輸出 JSON，格式：{"text":"整理後嘅文字"}
        """
    }

    static func cleanWithDeepSeek(_ text: String, completion: @escaping (String) -> Void) {
        guard let key = KeyStore.deepseek.get() else {
            DLog.w("deepseek: 未設定 key → 用規則版")
            completion(text)
            return
        }
        guard let url = URL(string: deepseekURL) else { completion(text); return }
        let strict = Prefs.deepseekMode == "strict"
        let started = Date()

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 6          // 逾時就照樣貼規則版，唔可以卡住用戶
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": Prefs.deepseekModel,
            "messages": [
                ["role": "system", "content": deepseekPrompt(strict: strict)],
                ["role": "user",   "content": text],
            ],
            "temperature": 0,
            "max_tokens": 1024,
            "stream": false,
            "thinking": ["type": "disabled"],       // 關掉 V4 思考模式（快好多）
            "response_format": ["type": "json_object"],  // 逼佢出 JSON，唔會加前言
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var done = false
        func finish(_ out: String) {
            DispatchQueue.main.async {
                if done { return }
                done = true
                completion(out)
            }
        }

        URLSession.shared.dataTask(with: req) { data, resp, err in
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if let err = err {
                DLog.w("deepseek 失敗（\(ms)ms）：\(err.localizedDescription) → 用規則版")
                finish(text); return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                finish(text); return
            }
            if let e = json["error"] as? [String: Any] {
                DLog.w("deepseek API 錯誤（\(ms)ms）：\(e["message"] ?? e) → 用規則版")
                finish(text); return
            }
            guard let choices = json["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else {
                finish(text); return
            }
            // 內容應該係 {"text": "..."}；穩陣起見，唔係 JSON 就直接用原文
            var out = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = out.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let t = obj["text"] as? String {
                out = t.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                out = stripMeta(out)
            }
            guard !out.isEmpty else { finish(text); return }

            if acceptRewrite(out, original: text, strict: strict) {
                DLog.w("deepseek 採用（\(ms)ms，\(strict ? "執字粒" : "輕整理")）：\(out)")
                finish(out)
            } else {
                // 記低被退回嘅內容，否則永遠唔知係 AI 改得過火定守門太緊
                let a = scriptNeutral(normalizeForCompare(out))
                let b = scriptNeutral(normalizeForCompare(text))
                let ratio = Double(a.count) / Double(max(1, b.count))
                DLog.w(String(format: "deepseek 退回（lcs=%.2f len=%.2f）：%@  ← 原文：%@",
                             similarity(a, b), ratio, out, text))
                finish(text)
            }
        }.resume()

        // 保險：URLSession 有時唔會準時 timeout（例如斷網重試），8 秒後強制收工
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if !done {
                done = true
                DLog.w("deepseek 逾時 8 秒 → 用規則版")
                completion(text)
            }
        }
    }


    /// 過濾 AI 吐出嚟嘅「元說明」文字。
    /// 實測 Apple FoundationModels 有時會回「經過處理後，結果是：」或
    /// 「這是清理後的結果。」呢類前言，直接貼上去會好奇怪。
    static func stripMeta(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)

        let markers = [
            "經過處理後，結果是：", "经过处理后，结果是：",
            "經過處理後，結果如下：", "經過處理後，結果係：",
            "這是清理後的結果", "这是清理后的结果",
            "以下是清理後的結果", "以下是清理后的结果",
            "以下是清理後嘅文字", "以下是清理后的文字",
            "以下是清理後的內容", "以下是清理后的内容",
            "以下是清理後嘅內容", "以下是整理後的內容", "以下是整理后的内容",
            "清理後的結果係：", "清理后的结果是：",
            "清理後嘅文字係：", "清理后的文字是：",
            "（輸出清理後嘅文字）", "（输出清理后的文字）",
            "輸出清理後嘅文字", "输出清理后的文字",
            "（輸出）", "（输出）",
            "以下是", "如下：", "結果：", "结果：",
        ]
        for m in markers {
            if out.contains(m) {
                // 取 marker 之後最後一段，去掉前言
                let parts = out.components(separatedBy: m)
                if let last = parts.last {
                    out = last.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        // 成對引號／書名號包住嘅（例如「我有些...」）→ 拆咗佢
        if out.count >= 2 {
            let pairs = [("\"", "\""), ("'", "'"), ("「", "」"), ("『", "』")]
            for (l, r) in pairs where out.hasPrefix(l) && out.hasSuffix(r) {
                out = String(out.dropFirst().dropLast())
                break
            }
        }
        // 多段輸出 → 取最後一段非空內容（前言通常喺最前）
        let lines = out
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.count > 1 { out = lines.last ?? out }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ---- Apple 內建 AI：免費、離線、唔使 API key ----
    static func appleStatus() -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "✅ 可用（本機運算）"
            case .unavailable(let reason):
                return "⚠️ 未開：\(reasonText(reason))"
            @unknown default:
                return "⚠️ 未知狀態"
            }
        }
        #endif
        return "⚠️ 需要 macOS 26 或更新"
    }

    @available(macOS 26.0, *)
    private static func reasonText(_ r: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch r {
        case .deviceNotEligible:        return "部機唔支援"
        case .appleIntelligenceNotEnabled: return "未開 Apple Intelligence"
        case .modelNotReady:            return "模型未就緒"
        @unknown default:               return "未知原因"
        }
    }

    static func cleanWithApple(_ text: String, completion: @escaping (String) -> Void) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                DispatchQueue.main.async { completion(text) }
                return
            }
            // 用系統指令（instructions）模式：指令同內容分開，
            // 模型就唔會將指令當作文本複述返嚟
            let session = LanguageModelSession(instructions: """
            你係語音轉文字嘅文字清理器。輸入係語音辨識嘅原始結果。
            規則：移除口語填充詞（嗯、呃、啊、um、uh、嗰個、其實）；修正標點同分段；
            數字轉阿拉伯數字。維持原本語氣同用字，唔好改寫、唔好加內容、
            唔好翻譯、唔好總結。輸出必須同輸入係同一段說話。
            只輸出清理後嘅文字本身——唔好加任何前言、說明、引號或標題，
            連「清理後嘅文字係」呢類開場白都唔要。
            """)
            Task {
                do {
                    let response = try await session.respond(to: text)
                    let out = CleanService.stripMeta(String(describing: response.content))
                    DispatchQueue.main.async {
                        completion(out.isEmpty ? text : out)
                    }
                } catch {
                    DispatchQueue.main.async { completion(text) }
                }
            }
            return
        }
        #endif
        DispatchQueue.main.async { completion(text) }
    }

    // ---- GPT-4o mini（OpenAI API），同 Spokenly 逐字計費模式 ----
    static func cleanWithGPT4oMini(_ text: String, completion: @escaping (String) -> Void) {
        guard let key = KeyStore.get() else {
            DispatchQueue.main.async { completion(text) }
            return
        }
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system",
                 "content": "你係文字清理助手。移除口語填充詞、修正標點、數字轉阿拉伯數字。唔好改寫語氣，唔好加內容，唔要解釋。只輸出清理後嘅文字。"],
                ["role": "user", "content": text]
            ],
            "temperature": 0,
            "max_tokens": 2000
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, _, _ in
            var out = text
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any],
               let content = msg["content"] as? String {
                let t = CleanService.stripMeta(content)
                if !t.isEmpty { out = t }
            }
            DispatchQueue.main.async { completion(out) }
        }.resume()
    }
}

func cleanFillers(_ s: String) -> String {
    // 2026-10-17：舊版有一條 `([\u4e00-\u9fa5])\1{1,}` 會 collapse 所有重複中文字，
    // 連「看看／慢慢／謝謝／剛剛／聽聽」都被整爛（意思都變埋）。已改為只清虛詞口吃。
    var t = CleanService.tidyText(s)
    // 再清幾個 AI 大整理模式用得着嘅口頭禪（執字粒模式唔會行到呢度）
    for p in ["其實", "其实", "即係話", "即系话"] {
        t = t.replacingOccurrences(of: "(^|[，。！？\\s])" + p + "[，,]\\s*", with: "$1",
                                   options: [.regularExpression])
    }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
}

// ---------------- 熱鍵監聽（按住／放開） ----------------
final class HotkeyTap {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    /// toggle 模式：撳一次開始／再撳一次完結
    var onToggle: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false
    private var trigger = currentTrigger()

    // ---- 健康監測（2026-10-16 為咗捉「用一次後靜默死亡」而加） ----
    /// 收過嘅 flagsChanged 事件總數 —— 用嚟驗證 tap 係咪「真係收到嘢」
    private(set) var flagsSeen: Int = 0
    /// tap 被系統停用過幾多次（逾時／用戶輸入）
    private(set) var disableEvents: Int = 0
    /// 探測事件：自己合成一粒「唔係觸發鍵」嘅修飾鍵，睇下個 tap 收唔收到
    private var probeCode: Int64 = 63
    private var probeExpected = false
    var lastProbeSent: Date?
    private var lastProbeOK: Date?
    var probeAttempts: Int = 0
    var probeFails: Int = 0

    func setTrigger(_ t: TriggerKey) {
        trigger = t
        isDown = false
    }

    func isTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    /// CGEventTap 會間歇性失效（逾時／系統回收）；失效嗰陣要重新起
    func isTapAlive() -> Bool {
        return tap != nil
    }

    /// 對象存在 **同** 未被系統停用，先至算真係活着
    func isTapEnabled() -> Bool {
        guard let t = tap else { return false }
        return CGEvent.tapIsEnabled(tap: t)
    }

    /// 最後一粒探測事件有冇順利返到嚟。
    /// ⚠️ 預設值好緊要：送過探測但從未收到一定要當失敗（預設 return true 會令
    /// 自愈邏輯永遠唔啟動 —— 2026-10-16 實測中招）。
    var lastProbeSuccess: Bool {
        guard let sent = lastProbeSent else { return true }   // 未送過探測 → 唔算失敗
        guard let ok = lastProbeOK else { return false }      // 送過但從未收到 → 失敗
        return ok >= sent
    }

    @discardableResult
    func start() -> Bool {
        stop()
        let mask = (1 << CGEventType.flagsChanged.rawValue)
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { DLog.w("✗ CGEventTap 建立失敗（多數係輔助使用未開）"); return false }

        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        DLog.w("✓ CGEventTap 建立成功（enabled=\(CGEvent.tapIsEnabled(tap: t))）")
        return true
    }

    func stop() {
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), s, .commonModes) }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        source = nil
        tap = nil
    }

    // ---- 探測：合成一粒修飾鍵出嚟，驗證個 tap 係咪真係收到事件 ----
    /// 實測過「用一次後靜默死亡」：tap 對象存在、冇 timeout callback、
    /// app 同 run loop 都健康，但就係收唔到任何事件 —— 唯一可靠嘅檢查係
    /// 自己合成事件落去，睇下會唔會繞返嚟。
    /// ⚠️ 千萬唔好 gate 住「系統報告話已啟用」先探測：停用嗰陣就永遠唔會
    /// 再探測，等於自己遮住自己對眼。呢度以「實際收唔收到」為唯一標準。
    @discardableResult
    func sendProbe() -> Bool {
        guard let t = tap else { return false }
        // 系統報告話停用咗 → 順手撳返開（ mach port 失效嗰陣呢步無效，
        // 跟住嘅探測會失敗 → 健康檢查就會整個 tap 重建）
        if !CGEvent.tapIsEnabled(tap: t) {
            CGEvent.tapEnable(tap: t, enable: true)
            DLog.w("🩺 系統報告 CGEventTap 已停用 → 已嘗試撳返開")
        }
        // 揀一個唔屬於觸發鍵嘅修飾鍵做探測，避免當成真撳鍵
        let candidates: [(Int64, CGEventFlags)] = [
            (63, .maskSecondaryFn), (60, .maskShift), (56, .maskShift),
            (55, .maskCommand), (54, .maskCommand), (62, .maskControl),
            (59, .maskControl), (61, .maskAlternate), (58, .maskAlternate),
        ]
        guard let pick = candidates.first(where: { !trigger.keyCodes.contains($0.0) }) else { return false }
        probeCode = pick.0
        probeExpected = true
        lastProbeSent = Date()
        probeAttempts += 1
        postModifierTap(code: pick.0, flag: pick.1, down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            self.postModifierTap(code: pick.0, flag: pick.1, down: false)
        }
        return true
    }

    private func postModifierTap(code: Int64, flag: CGEventFlags, down: Bool) {
        guard let src = CGEventSource(stateID: .combinedSessionState),
              let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down)
        else { return }
        e.type = .flagsChanged
        e.flags = down ? flag : CGEventFlags()
        e.setIntegerValueField(.keyboardEventKeycode, value: code)
        e.post(tap: .cghidEventTap)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            disableEvents += 1
            let why = type == .tapDisabledByTimeout ? "逾時 timeout" : "用戶輸入 userInput"
            if let t = tap {
                CGEvent.tapEnable(tap: t, enable: true)
                DLog.w("⛔ 系統停用咗個 tap（\(why)）→ 已重新啟用（enabled=\(CGEvent.tapIsEnabled(tap: t))），累計 \(disableEvents) 次")
            } else {
                DLog.w("⛔ 系統停用咗個 tap（\(why)）但 tap 已經唔存在，累計 \(disableEvents) 次")
            }
            return
        }
        guard type == .flagsChanged else { return }

        flagsSeen += 1
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let raw = event.flags.rawValue

        // 探測事件返嚟 → 證明個 tap 係真係收到嘢
        if probeExpected && code == probeCode {
            probeExpected = false
            lastProbeOK = Date()
            DLog.w("✅ 探測事件收到（keycode=\(code)）—— tap 正常運作")
        }

        // 診斷：每一個修飾鍵事件都記低 —— 萬一觸發鍵冇反應，一眼睇穿係
        // 「事件根本冇嚟」定「嚟咗但 keycode 唔啱」
        if kModifierCodes.contains(code) {
            let nm = kTriggers.first { $0.keyCodes.contains(code) }?.name ?? "\(code)"
            DLog.w("⚙︎ 修飾鍵事件：\(nm) keycode=\(code) flags=0x\(String(raw, radix: 16)) 觸發鍵=\(trigger.name)")
        }

        guard trigger.keyCodes.contains(code) else { return }

        let down = event.flags.contains(trigger.flag)

        if Prefs.triggerMode == "toggle" {
            // ── toggle 模式（預設）：撳一次開始、再撳一次完結 ──
            // 只喺「落下」邊緣 toggle，鬆開邊緣淨係 reset，唔會變停止
            if down && !isDown {
                isDown = true
                DLog.w("🔁 觸發鍵撳落：toggle 錄音（mode=toggle）")
                onToggle?()
            } else if !down {
                isDown = false
            }
        } else {
            // ── hold 模式（舊）：撳住講、鬆手完結 ──
            if down && !isDown {
                isDown = true
                onDown?()
            } else if !down && isDown {
                isDown = false
                onUp?()
            } else if down == isDown {
                DLog.w("⚠️ 觸發鍵 \(trigger.name) 事件被忽略（狀態已經係 \(down ? "down" : "up")）")
            }
        }
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
    me.handle(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

// ---------------- 輸出（模擬 Cmd+V） ----------------
func restartApp() {
    let path = Bundle.main.bundlePath
    let task = Process()
    task.launchPath = "/usr/bin/open"
    task.arguments = ["-n", path]
    try? task.run()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        NSApp.terminate(nil)
    }
}

enum Paster {
    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func sendCommandV() {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKey: CGKeyCode = 9 // V
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        usleep(15000)
        up?.post(tap: .cghidEventTap)
    }
}

// ---------------- 主控 ----------------
enum DictationState {
    case idle, recording, working
}

final class Controller {
    static let shared = Controller()

    let recorder = Recorder()
    let transcriber = Transcriber()
    let hotkey = HotkeyTap()
    /// 而家互動中嘅 App（聽寫完字會貼去呢度）—— 顯示喺 HUD 等用戶安心
    var targetApp: String = "当前 App"
    /// 比 HUD 讀取音量波形
    var recorderLevels: [Float] { recorder.levels }
    /// 最近一個「唔係我哋自己」嘅前台 App —— 主視窗開住時 capture 會捉到自己
    private var lastExternalApp: String = "当前 App"

    func captureTargetApp() {
        if let app = NSWorkspace.shared.frontmostApplication,
           (app.localizedName ?? "") != "Dictation" {
            targetApp = app.localizedName ?? "当前 App"
        } else {
            targetApp = lastExternalApp
        }
        DLog.w("目標 App：\(targetApp)")
    }
    let carbon = CarbonHotkey()

    var state: DictationState = .idle {
        didSet { DispatchQueue.main.async { self.onStateChange?(self.state) } }
    }
    var onStateChange: ((DictationState) -> Void)?
    var onError: ((String) -> Void)?

    private var busy = false
    private var workingSince: Date?

    func boot() {
        try? FileManager.default.createDirectory(atPath: kWorkDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: kModelDir, withIntermediateDirectories: true)

        // 診斷：確認 app 個 event loop 收唔收到任何原始按鍵
        installRawKeyMonitor()

        // （2026-10-16 13:20）全域熱鍵已停用 —— 用戶明確話淨係要「快速設定」嗰個觸發鍵，
        // 唔需要 ⌃⌥D 一類組合。CarbonHotkey class 保留但唔註冊。

        // 熱鍵 2：按住修飾鍵講話（需要輔助使用權限）—— Spokenly 嘅主要用法
        hotkey.setTrigger(currentTrigger())
        hotkey.onDown = { [weak self] in
            DLog.w("▼ 觸發鍵撓落去：開始錄音（hold 模式）")
            self?.captureTargetApp()   // 記住字會貼去邊個 App，顯示喺 HUD
            MainWindow.shared.hide()   // 收埋主視窗，等 paste 去用戶個 App
            self?.beginRecording()
        }
        hotkey.onUp   = { [weak self] in
            DLog.w("▲ 觸發鍵鬆開：停止並辨識（hold 模式）")
            self?.endRecording()
        }
        hotkey.onToggle = { [weak self] in
            DLog.w("🔁 觸發鍵撳一次：toggle 錄音")
            self?.toggleDictation()
        }
        if !hotkey.start() {
            DLog.w("⚠️ CGEventTap 起唔到（多數係輔助使用未開）— 用全域熱鍵 ⌃⌥D 都得")
        }

        // 每 1 秒記住用戶而家用緊嘅 App（聽寫完字會貼去呢度，顯示喺 HUD）
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            if let app = NSWorkspace.shared.frontmostApplication,
               (app.localizedName ?? "") != "Dictation" {
                self?.lastExternalApp = app.localizedName ?? "当前 App"
            }
        }

        // 看門狗：如果卡在「辨識中」超過 30 秒，強行重設，確保熱鍵永遠有反應
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.watchdog()
        }

        // 🩺 熱鍵健康檢查（2026-10-16 加）：解決「用一次後靜默死亡」。
        // 每 2 秒送一粒合成探測修飾鍵落去，0.8 秒內個 tap 收唔到 → 壞咗：
        // 先試重新啟用，再唔得就整個 tap 重建。呢個係全自動修復，
        // 用戶永遠感覺唔到中間死過一次。
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkTapHealth()
        }
    }

    private var lastProbeTime: Date = .distantPast
    private var lastHeartbeat: Date = .distantPast
    private var lastSlowRetry: Date = .distantPast

    private func checkTapHealth() {
        let hk = hotkey

        if !hk.isTapAlive() {
            DLog.w("🩺 tap 已經唔存在 → 重建")
            Diag.shared.tapRebuilds += 1
            reloadHotkey()
            lastProbeTime = Date()
            hk.sendProbe()
            return
        }

        // 每 2 秒探一次
        if Date().timeIntervalSince(lastProbeTime) >= 2.0 {
            lastProbeTime = Date()
            hk.sendProbe()
        }

        // 探測送咗超過 0.8 秒都未收到 → 呢個 tap 雖然存在但收唔到事件
        if let sent = hk.lastProbeSent, Date().timeIntervalSince(sent) > 0.8, !hk.lastProbeSuccess {
            hk.probeFails += 1
            let why = hk.isTapEnabled()
                ? "tap 開住但收唔到事件（可能佢上游有另一隻 App 裝咗會食事件嘅 tap）"
                : "tap 存在但被系統停用咗"
            let secure = IsSecureEventInputEnabled() ? "；安全輸入模式開啟中（有程式開咗密碼類輸入，macOS 唔會將按鍵交畀聽寫 App）" : ""
            DLog.w("🩺 探測失敗（第 \(hk.probeFails) 次）：\(why)\(secure)")
            if hk.probeFails <= 10 {
                DLog.w("🩺 → 自動重建 CGEventTap")
                Diag.shared.tapRebuilds += 1
                reloadHotkey()
                lastProbeTime = Date()
                hk.sendProbe()
            } else {
                // 連續失敗太多次：唔好每秒狂重建（系統可能將個 process 咗雪糕筒），
                // 改為每 15 秒慢試一次，永遠唔會放棄 —— 用戶嘅觸發鍵必須返到。
                if Date().timeIntervalSince(lastSlowRetry) > 15 {
                    lastSlowRetry = Date()
                    DLog.w("🩺 連續失敗 \(hk.probeFails) 次 → 慢速重試重建（每 15 秒一次，唔會放棄）")
                    Diag.shared.tapRebuilds += 1
                    reloadHotkey()
                    lastProbeTime = Date()
                    hk.sendProbe()
                }
            }
            return
        }

        // 每 5 秒一行心跳，全部狀態一目了然
        if Date().timeIntervalSince(lastHeartbeat) >= 5.0 {
            lastHeartbeat = Date()
            let tapState = hk.isTapAlive() ? (hk.isTapEnabled() ? "開" : "停用") : "死"
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            let monitor = CGPreflightListenEventAccess() ? 1 : 0
            DLog.w(String(format: "⏱ tap=%@ 收過事件=%d 探測 %d成功/%d次 停用事件=%d 安全輸入=%d 輸入監視=%d 前台=%@ 狀態=%@",
                          tapState, hk.flagsSeen, hk.probeAttempts - hk.probeFails, hk.probeAttempts,
                          hk.disableEvents, IsSecureEventInputEnabled() ? 1 : 0, monitor, front, stateDescription))
        }
    }

    /// 卡死保護 —— 呢個係「按熱鍵完全冇反應」最隱藏嘅原因：
    /// 如果辨識 callback 冇返，busy 會永遠係 true，之後按咩都冇用
    private func watchdog() {
        guard state == .working, busy else { workingSince = nil; return }
        if workingSince == nil {
            workingSince = Date()
        } else if Date().timeIntervalSince(workingSince!) > 30 {
            DLog.w("⚠️ 卡在「辨識中」超過 30 秒 → 強行重設")
            Diag.shared.stuckResets += 1
            state = .idle
            busy = false
            workingSince = nil
            RecordingHUD.shared.hide()
        }
    }

    var isBusy: Bool { busy }
    var stateDescription: String {
        switch state {
        case .idle: return "閒置"
        case .recording: return "錄音中"
        case .working: return "辨識中"
        }
    }

    func reloadHotkey() {
        hotkey.setTrigger(currentTrigger())
        hotkey.start()
    }

    func reloadCarbon() {
        carbon.setCombo(currentCombo())
    }

    /// 切換模式：idle → 開始錄；recording → 停止
    func toggleDictation() {
        switch state {
        case .idle:
            guard !busy else {
                DLog.w("toggleDictation 被擋：busy=true（state=\(stateDescription)）")
                Diag.shared.fail("辨識中，請稍候再試")
                return
            }
            // 收埋主視窗：唔收埋嘅話 focus 留喺我哋視窗度，
            // 講完模擬 Cmd+V 會打落自己 App 而唔係用戶個對話框
            captureTargetApp()
            MainWindow.shared.hide()
            beginRecording()
        case .recording:
            endRecording()
        default:
            DLog.w("toggleDictation 忽略：state=\(stateDescription)")
            break
        }
    }

    private func beginRecording() {
        guard !busy, state == .idle else { return }
        do {
            try recorder.start()
            state = .recording
            RecordingHUD.shared.show()
            SoundFX.shared.playStart()     // 「開始」提示音（同錄音同時，唔會漏開頭）
            // 靜音其他聲音：要等提示音播完（125ms）先落手，
            // 否則連自己個「嘟‑嗶」都會靜埋，用戶就聽唔到「開始咗」。
            if Prefs.muteOthers {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
                    guard let self = self, self.state == .recording else { return }
                    SystemAudio.muteForRecording()
                }
            }
        } catch {
            onError?("錄音失敗：\(error.localizedDescription)")
        }
    }

    private func endRecording() {
        guard state == .recording else { return }
        state = .working
        busy = true
        workingSince = Date()
        // 🔴 先還原聲音，再播停止音 —— 否則停止音自己都會被靜音
        SystemAudio.restoreAfterRecording()
        SoundFX.shared.playStop()          // 「停止」提示音
        // 停止录音後保留同一個簡約 HUD，顯示「轉寫中…」；辨識完成才先收起，
        // 再把文字貼回原輸入位置，讓用戶知道 App 仍在處理。
        RecordingHUD.shared.show(stopping: true)

        guard let wav = recorder.stop() else {
            state = .idle; busy = false; workingSince = nil; RecordingHUD.shared.hide(); return
        }

        // 太短（<0.3 秒）就當誤觸
        let attrs = try? FileManager.default.attributesOfItem(atPath: wav.path)
        let size = (attrs?[.size] as? Int) ?? 0
        if size < 12_000 {
            state = .idle; busy = false; workingSince = nil; RecordingHUD.shared.hide(); return
        }

        // 靜音過濾：最高音量都低過 -40 dB 就當冇人講嘢，唔好浪費時間辨識
        DLog.w("錄音完 peak=\(Int(recorder.peakLevel))dB size=\(size)")
        if recorder.peakLevel < -40 {
            DLog.w("靜音，略過辨識")
            state = .idle; busy = false; workingSince = nil; RecordingHUD.shared.hide(); return
        }

        transcriber.transcribe(wav: wav) { [weak self] text in
            guard let self = self else { return }

            guard let raw = text else {
                RecordingHUD.shared.hide()
                self.state = .idle; self.busy = false; self.workingSince = nil
                return
            }

            CleanService.run(raw) { out in
                guard !out.isEmpty else {
                    RecordingHUD.shared.hide()
                    self.state = .idle; self.busy = false; self.workingSince = nil
                    return
                }
                self.appendHistory(out)
                Paster.copyToClipboard(out)
                // 轉寫完成：先收起處理提示，再把文字貼入原本輸入位置。
                RecordingHUD.shared.hide()

                if Prefs.autoPaste {
                    if AXIsProcessTrusted() {
                        // 有輔助使用權限 → 模擬 Cmd+V，直接打入游標所在嘅對話框
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            Paster.sendCommandV()
                        }
                    } else {
                        // 冇權限 → macOS 根本唔俾自動打字，直接教用戶開（唔再叫佢自己貼）
                        DLog.w("no a11y -> guidance, skip paste")
                        RecordingHUD.shared.hide()
                        showA11yGuidance()
                    }
                }

                self.state = .idle; self.busy = false; self.workingSince = nil
            }
        }
    }

    private func appendHistory(_ text: String) {
        DLog.w("辨識結果：\(text)")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(df.string(from: Date()))] \(text)\n"
        if let h = FileHandle(forWritingAtPath: kLogFile) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            h.closeFile()
        } else {
            try? line.write(toFile: kLogFile, atomically: true, encoding: .utf8)
        }
    }
}

// ---------------- App ----------------
// ============================================================
//  主視窗（第一次啟動自動彈出，等雙擊一定有反應）
// ============================================================
struct MainView: View {
    @State private var trigger: String = Prefs.trigger
    @State private var triggerMode: String = Prefs.triggerMode
    @State private var language: String = Prefs.language
    @State private var engine: String = Prefs.cleanupEngine
    @State private var dsMode: String = Prefs.deepseekMode
    @State private var dsModel: String = Prefs.deepseekModel
    @State private var fidelity: Int = Prefs.fidelity
    @State private var autoPaste: Bool = Prefs.autoPaste
    @State private var muteOthers: Bool = Prefs.muteOthers

    var body: some View {
        // 可滾動：內容越加越多，要確保細屏／Sidecar 都睇到晒
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {

            // 標題 + 狀態
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.15))
                        .frame(width: 52, height: 52)
                    Image(systemName: statusIcon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(statusColor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dictation")
                        .font(.system(size: 22, weight: .bold))
                    Text(statusText)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            // 用法
            VStack(alignment: .leading, spacing: 10) {
                Label("點用", systemImage: "1.circle.fill")
                    .font(.headline)
                HStack(spacing: 8) {
                    stepBadge("1", "游標擺喺任何輸入位置")
                    Image(systemName: "arrow.right").foregroundColor(.secondary)
                    stepBadge("2", triggerMode == "toggle"
                              ? "撳一次 **\(currentTrigger().name)** 開始"
                              : "撳住 **\(currentTrigger().name)**")
                    Image(systemName: "arrow.right").foregroundColor(.secondary)
                    stepBadge("3", triggerMode == "toggle" ? "講完再撳一次出字" : "講嘢，鬆手出字")
                }
                Text("觸發鍵可以喺下面「快速設定」改（Command / Option / Shift / Control / Fn，左右都收）。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 即時試錄
            let recNow = Controller.shared.state == .recording
            let btnTitle = recNow ? "停止並辨識" : "試錄一句（撳呢度都得）"
            let btnIcon = recNow ? "stop.circle" : "play.circle"
            HStack(spacing: 10) {
                Button {
                    Controller.shared.toggleDictation()
                } label: {
                    Label(btnTitle, systemImage: btnIcon)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .tint(recNow ? Color.red : Color.accentColor)
                .disabled(Controller.shared.state == .working)
            }

            Divider()

            // 快速設定
            VStack(alignment: .leading, spacing: 12) {
                Label("快速設定", systemImage: "slider.horizontal.3")
                    .font(.headline)

                HStack {
                    Text("觸發鍵").frame(width: 76, alignment: .leading)
                    Picker("", selection: $trigger) {
                        ForEach(kTriggers, id: \.id) { t in
                            Text(t.name).tag(t.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }

                HStack {
                    Text("觸發方式").frame(width: 76, alignment: .leading)
                    Picker("", selection: $triggerMode) {
                        Text("撳一次（開始）／再撳一次（完結）").tag("toggle")
                        Text("撳住講嘢（鬆手完結）").tag("hold")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 290)
                }

                HStack {
                    Text("輸出語言").frame(width: 76, alignment: .leading)
                    Picker("", selection: $language) {
                        Text("自動偵測").tag("auto")
                        Text("廣東話（繁體中文）").tag("yue")
                        Text("普通話（簡體中文）").tag("zh")
                        Text("English").tag("en")
                        Text("日本語").tag("ja")
                        Text("한국어").tag("ko")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 230)
                }
                Text("選「廣東話（繁體中文）」會按粵語辨識；其他語言可隨時切換。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.leading, 76)

                HStack {
                    Text("文字清理").frame(width: 76, alignment: .leading)
                    Picker("", selection: $engine) {
                        ForEach(CleanupEngine.allCases, id: \.rawValue) { e in
                            Text(e.label).tag(e.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 320)
                }
                Text((CleanupEngine(rawValue: engine) ?? .polish).hint)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 76)
                    .padding(.trailing, 8)

                Toggle("講完直接將字顯示喺游標位置（對話框／WhatsApp／郵件…）", isOn: $autoPaste)
                    .toggleStyle(.checkbox)
                Text("呢個係 macOS 系統機制：自動打字必須開「輔助使用」。未開嘅話辨識完會彈窗教你。")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Toggle("錄音時自動靜音其他聲音（睇片／聽歌唔會漏入咪）", isOn: $muteOthers)
                    .toggleStyle(.checkbox)
                    .onChange(of: muteOthers) { v in
                        Prefs.muteOthers = v
                        AppDelegate.shared.rebuildMenu()
                    }
                Text("撳 Option 開始錄 → 系統輸出靜音；錄完即刻還原。中途插耳機／轉 AirPods 都會跟住靜音。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let e = CleanupEngine(rawValue: engine), e == .apple {
                    Text("Apple 內建 AI：免費、離線、唔使 API key。目前狀態：\(CleanService.appleStatus())")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let e = CleanupEngine(rawValue: engine), e == .polish {
                    Text("純規則整理，唔經任何 AI —— 所以唔會加字、唔會改你講法。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let e = CleanupEngine(rawValue: engine), e == .deepseek {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("模型").font(.caption).foregroundColor(.secondary)
                                .frame(width: 44, alignment: .leading).fixedSize()
                            Picker("", selection: $dsModel) {
                                ForEach(kDeepSeekModels, id: \.0) { m in
                                    Text(m.1).tag(m.0)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 320)
                        }
                        HStack(spacing: 8) {
                            Text("力度").font(.caption).foregroundColor(.secondary)
                                .frame(width: 44, alignment: .leading).fixedSize()
                            Picker("", selection: $dsMode) {
                                Text("執字粒（字數必須一樣）").tag("strict")
                                Text("輕整理（讀得通順少少）").tag("light")
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 300)
                        }
                        if dsMode == "light" {
                            HStack(spacing: 8) {
                                Text("保留度")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(width: 44, alignment: .leading)
                                    .fixedSize()
                                Picker("", selection: $fidelity) {
                                    Text("95%").tag(95)
                                    Text("90%（建議）").tag(90)
                                    Text("85%").tag(85)
                                    Text("80%").tag(80)
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(width: 260)
                            }
                            Text("95% 幾乎原文　·　90% 建議　·　85% 中度　·　80% 可大執（改動多啲）")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(.leading, 52)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 6) {
                            Image(systemName: "globe").foregroundColor(.blue)
                            Text("輸出字形跟「輸出語言」：\(languageName(language))")
                                .font(.caption)
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "key.fill").foregroundColor(.orange)
                            Text(KeyStore.deepseek.get() == nil
                                 ? "未設定 key —— 撳右邊個掣貼入去（sk- 開頭）"
                                 : "key：\(KeyStore.deepseek.mask() ?? "")")
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Button("設定 DeepSeek key") { AppDelegate.shared.promptForDeepSeekKey() }
                                .controlSize(.small)
                        }
                        Text("文字會送去 DeepSeek 雲端，每次約 ¥0.0000x；冇網絡／逾時會自動用返規則版。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }
                if CleanupEngine(rawValue: engine) == .gpt4omini {
                    HStack(spacing: 6) {
                        Image(systemName: "key.fill").foregroundColor(.orange)
                        Text(KeyStore.get() == nil
                             ? "未設定 OpenAI key — 撳右下角「設定 key」"
                             : "已設定：\(KeyStore.mask() ?? "")")
                            .font(.caption)
                    }
                }
            }

            Divider()

            // 權限狀態（最明顯）
            VStack(alignment: .leading, spacing: 10) {
                Label("權限檢查", systemImage: "lock.shield")
                    .font(.headline)

                HStack(spacing: 10) {
                    Image(systemName: micOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(micOK ? .green : .red)
                        .font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(micOK ? "麥克風權限已開啟" : "麥克風權限未開啟")
                            .font(.system(size: 13, weight: .semibold))
                        Text(micOK
                             ? (a11yOK ? "收音、自動貼上全部就緒" : "錄音同辨識已就緒；開輔助使用可自動貼上")
                             : "未開呢個權限會錄到全靜音，一個字都辨識唔到")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                if !a11yOK {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("輔助使用權限未開啟 — 一定要開")
                                .font(.system(size: 13, weight: .semibold))
                            Text("唔開呢個權限，講完嘅字顯示唔到對話框度（macOS 系統限制）。開咗掣都係唔work？撳「打開輔助使用設定」，揀住 Dictation 撳「−」刪咗再「+」加返")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }

                if !listenOK {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("輸入監視權限未開啟 — 觸發鍵用唔到")
                                .font(.system(size: 13, weight: .semibold))
                            Text("macOS 15 起「輔助使用」同「輸入監視」係兩個獨立權限。冇輸入監視，聽寫 App 收唔到撳觸發鍵嘅事件。開咗即刻見效。")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }

                HStack(spacing: 8) {
                    Button(micOK ? "麥克風已開" : "打開麥克風設定") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                    .controlSize(.small)
                    .tint(micOK ? Color.gray : Color.red)

                    Button(AXIsProcessTrusted() ? "輔助使用已開" : "打開輔助使用設定") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .controlSize(.small)
                    .tint(a11yOK ? Color.gray : Color.orange)

                    Button(CGPreflightListenEventAccess() ? "輸入監視已開" : "打開輸入監視設定") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                    }
                    .controlSize(.small)
                    .tint(listenOK ? Color.gray : Color.orange)

                    Button("重新啟動 App") { restartApp() }
                        .controlSize(.small)
                        .tint(.orange)

                    Text("開完要撳「重新啟動」先生效")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // 底部按鈕
            HStack(spacing: 8) {
                Button("測試自動貼上") {
                    // 游標擺去任何打字位再撳呢度 — 成功就即場出現字
                    MainWindow.shared.hide()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        if AXIsProcessTrusted() {
                            Paster.copyToClipboard("測試成功 — Dictation 自動打字運作中")
                            Paster.sendCommandV()
                        } else {
                            showA11yGuidance()
                        }
                    }
                }
                .controlSize(.small)
                .tint(.green)

                Button("設定 OpenAI key") { AppDelegate.shared.promptForKey() }
                    .controlSize(.small)
                Button("設定 DeepSeek key") { AppDelegate.shared.promptForDeepSeekKey() }
                    .controlSize(.small)
                Spacer()
                Button("開始講嘢") { MainWindow.shared.hide() }
                    .keyboardShortcut(.defaultAction)
            }
            }
        }
        .padding(24)
        .frame(width: 560)
        .onChange(of: trigger) { v in
            Prefs.trigger = v
            Controller.shared.reloadHotkey()
        }
        .onChange(of: triggerMode) { v in
            Prefs.triggerMode = v
        }
        .onChange(of: language) { v in
            Prefs.language = v
            AppDelegate.shared.rebuildMenu()
        }
        .onChange(of: engine) { v in
            Prefs.cleanupEngine = v
            AppDelegate.shared.rebuildMenu()
        }
        .onChange(of: dsMode) { v in
            Prefs.deepseekMode = v
            AppDelegate.shared.rebuildMenu()
        }
        .onChange(of: dsModel) { v in
            Prefs.deepseekModel = v
            AppDelegate.shared.rebuildMenu()
        }
        .onChange(of: fidelity) { v in
            Prefs.fidelity = v
            AppDelegate.shared.rebuildMenu()
        }
        .onChange(of: autoPaste) { v in
            Prefs.autoPaste = v
        }
    }

    private var a11yOK: Bool { AXIsProcessTrusted() }
    /// 輸入監視權限：CGEventTap 要收按鍵事件必備（macOS 15+ 獨立權限）
    private var listenOK: Bool { CGPreflightListenEventAccess() }
    private var micOK: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    private var statusColor: Color {
        switch Controller.shared.state {
        case .recording: return .red
        case .working:   return .orange
        default:         return .green
        }
    }
    private var statusIcon: String {
        switch Controller.shared.state {
        case .recording: return "mic.circle.fill"
        case .working:   return "ellipsis.circle.fill"
        default:         return "checkmark.circle.fill"
        }
    }
    private var statusText: String {
        switch Controller.shared.state {
        case .recording: return "錄音中… 講完再撳一次 \(currentTrigger().name)"
        case .working:   return "辨識中…完成後直接貼到游標位置"
        default:         return triggerMode == "toggle"
            ? "就緒 — 撳一次 \(currentTrigger().name) 開始錄音"
            : "就緒 — 按住 \(currentTrigger().name) 講話"
        }
    }

    /// 診斷一格：細標題 + 數值
    private func diagRow(_ title: String, _ value: String, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(ok ? .green : .secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private func stepBadge(_ n: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(n)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            Text(text).font(.system(size: 12))
        }
    }
}

final class MainWindow {
    static let shared = MainWindow()
    private var window: NSWindow?
    private var hosting: NSHostingController<MainView>?

    /// 俾外部攞主視窗（開 sheet 用）
    var nsWindow: NSWindow? { window }

    /// 揀啱屏幕：優先有選單列嗰塊（Mac 內建屏），避免彈去 Sidecar / 外接屏
    private func primaryScreen() -> NSScreen? {
        // 有選單列嘅屏幕，frame origin 一定係 (0,0)
        if let s = NSScreen.screens.first(where: { $0.frame.origin == .zero }) { return s }
        if let s = NSScreen.main { return s }
        return NSScreen.screens.first
    }

    func show() {
        DLog.w("MainWindow.show() enter")
        if window == nil {
            DLog.w("building window...")
            let view = MainView()
            let host = NSHostingController(rootView: view)
            hosting = host
            let w = NSWindow(contentViewController: host)
            w.title = "Dictation"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            // ⚠️ 必須明確指定尺寸：NSHostingController 未排版時 fittingSize 會係 1px
            w.setContentSize(NSSize(width: 620, height: 620))
            w.minSize = NSSize(width: 520, height: 460)
            if let s = primaryScreen() {
                let x = s.frame.midX - (w.frame.width / 2)
                let y = s.frame.maxY - w.frame.height - 60
                w.setFrameOrigin(NSPoint(x: x, y: y))
                DLog.w("centered on screen: \(s.frame) -> origin (\(x), \(y))")
            } else {
                w.center()
                DLog.w("centered via w.center()")
            }
            window = w
            DLog.w("window built: \(w.frame)")
            fitWindow()
        }
        NSApp.setActivationPolicy(.regular)
        DLog.w("policy=regular, activating")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        DLog.w("window ordered front, visible=\(window?.isVisible ?? false)")
    }

    func hide() {
        window?.orderOut(nil)
        DLog.w("window hidden (app 繼續喺背景運行)")
    }

    func toggle() {
        if let w = window, w.isVisible { hide() } else { show() }
    }

    /// 將視窗裁到合適尺寸：固定闊度，高度取「內容足夠」或「螢幕容許」之間較細嗰個，
    /// 內容再長就靠 ScrollView 滾動，永遠唔會頂出螢幕。
    private func fitWindow() {
        guard let w = window else { return }
        let maxH = (primaryScreen()?.visibleFrame.height ?? 900) - 140
        // 760：DeepSeek 面板展開之後（模型／力度／保留度／key 狀態）高過 680，
        // 用 680 會令「key 狀態」同最後一行說明跌落摺線以下，用戶要自己滾。
        let height = min(760, maxH)
        var size = NSSize(width: 620, height: height)
        if let s = primaryScreen(), size.height > s.visibleFrame.height - 140 {
            size.height = s.visibleFrame.height - 140
        }
        w.setContentSize(size)
        if let s = primaryScreen() {
            let x = s.frame.midX - (w.frame.width / 2)
            let y = s.frame.maxY - w.frame.height - 60
            w.setFrameOrigin(NSPoint(x: x, y: y))
        }
        DLog.w("window fitted to \(w.frame)")
    }

    /// 強制重畫（狀態轉換時用）
    func reload() {
        guard let host = hosting, window?.isVisible == true else { return }
        host.rootView = MainView()
        fitWindow()
    }
}

/// 冇「輔助使用」權限 → macOS 唔准自動打字入第個 App。
/// 用戶要嘅係「講完直接顯示喺對話框」，所以呢個權限係硬要求，要清楚地教。
func showA11yGuidance() {
    guard !AXIsProcessTrusted() else { return }
    DispatchQueue.main.async {
        let a = NSAlert()
        a.messageText = "字打唔到對話框：要開「輔助使用」"
        a.informativeText = "macOS 規矩：將文字自動打入第個 App（WhatsApp、郵件、備忘錄...）必須開「輔助使用」。\n\n1. 撳「打開輔助使用設定」\n2. 左邊揀「輔助使用」\n3. 右邊搵到 Dictation，開關撥去開啟\n4. 返嚟再講一次就得\n\n⚠️ 如果開關已經係「開」但呢度仍然話未開（換簽名之後會咁）：\n揀住列表中嘅 Dictation → 撳下面「−」刪咗佢 → 再撳「+」→ 應用程式 → 揀 Dictation → 開啟"
        a.alertStyle = .warning
        a.addButton(withTitle: "打開輔助使用設定")
        a.addButton(withTitle: "遲啲先")
        AppDelegate.shared.presentHint(a) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var statusRow: NSMenuItem!
    static var shared = AppDelegate()

    /// 開一張非阻塞嘅提示。優先用 sheet 挂住主視窗（唔會 deadlock 主執行緒，
    /// 錄音 timer 照行）；主視窗未 ready 就彈出佢再用 sheet。
    /// ⚠️ 唔可以用 runModal()：modal session 會餓死 default-mode timer
    ///    （實測錄音停止 timer 永久失效，錄音唔停）。
    func presentHint(_ a: NSAlert, open: @escaping () -> Void) {
        if let w = MainWindow.shared.nsWindow, w.isVisible {
            a.beginSheetModal(for: w) { resp in
                if resp == .alertFirstButtonReturn { open() }
            }
        } else if let w = MainWindow.shared.nsWindow {
            // 主視窗收埋咗：彈返出嚟再用 sheet（sheet 一定要掛可見視窗）
            MainWindow.shared.show()
            a.beginSheetModal(for: w) { resp in
                if resp == .alertFirstButtonReturn { open() }
            }
        } else {
            a.addButton(withTitle: "打開設定")
            a.addButton(withTitle: "遲啲先")
            if a.runModal() == .alertFirstButtonReturn { open() }
        }
    }

    /// 建立主選單。
    /// 🔴 2026-10-17 用戶報「DeepSeek API key 不能複製貼上」—— 根因就係呢個 App
    ///    一直冇建 NSApp.mainMenu，即係完全冇「編輯」選單。macOS 嘅 Cmd+C／Cmd+V
    ///    係靠選單項嘅 action（copy: / paste:）經 responder chain 派落去，
    ///    冇選單項就完全冇反應（唔會報錯，只係靜靜地唔做嘢）。
    func buildMainMenu() {
        let main = NSMenu()

        // App 選單
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "關於 Dictation",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隱藏 Dictation",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "結束 Dictation",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // 編輯選單 —— 冇佢，所有輸入框都貼唔到嘢
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "編輯")
        edit.addItem(withTitle: "還原", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪下", action: NSSelectorFromString("cut:"), keyEquivalent: "x")
        edit.addItem(withTitle: "複製", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        edit.addItem(withTitle: "貼上", action: NSSelectorFromString("paste:"), keyEquivalent: "v")
        edit.addItem(withTitle: "全選", action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
        DLog.w("主選單已建立：" + main.items.map { $0.submenu?.title ?? $0.title }.joined(separator: " / "))
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 保險 ②：如果仲喺錄音中途就 quit／登出，唔可以留低「部機冇聲」呢個狀態
        SystemAudio.restoreAfterRecording()
        DLog.w("=== applicationWillTerminate：已還原聲音（如有）===")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DLog.w("=== applicationDidFinishLaunching ===")
        Prefs.register()
        AppDelegate.shared = self
        buildMainMenu()
        SoundFX.shared.prepare()          // 預熱音效引擎，第一次撳 Option 唔會有延遲
        SystemAudio.recoverFromCrash()    // 上次死喺錄音中途 → 幫佢還原聲音

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        DLog.w("statusItem created: \(statusItem != nil)")
        if let b = statusItem.button {
            // 圖示 + 文字一齊顯示，確保一定見得到
            b.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Dictation")
            b.image?.isTemplate = false           // 唔用 template，避免主題問題
            b.imagePosition = .imageLeading
            b.title = "聽寫"
            b.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            b.toolTip = "Dictation — 撳一次 \(currentTrigger().name) 開始，再撳一次出字"
            DLog.w("statusItem button set: image=\(b.image != nil) title=\(b.title) frame=\(b.frame)")
        } else {
            DLog.w("!! statusItem.button is nil")
        }
        // 先填好選單先 assign（空選單可能令圖示唔顯示）
        rebuildMenu()
        menu.delegate = self
        statusItem.menu = menu
        DLog.w("menu assigned, items=\(menu.numberOfItems)")

        Controller.shared.onStateChange = { [weak self] s in
            self?.render(s)
            MainWindow.shared.reload()
        }
        Controller.shared.onError = { [weak self] msg in self?.alert(msg) }
        DLog.w("callbacks set, booting controller")
        Controller.shared.boot()
        DLog.w("controller booted, a11y=\(AXIsProcessTrusted() ? "✅" : "❌") listen=\(CGPreflightListenEventAccess() ? "✅" : "❌")")

        requestMic()
        checkAccessibility()

        // 麥克風被拒：啟動後彈一個唔會睇漏嘅提示，直接俾條路用戶去開
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                DLog.w("mic denied on launch -> alert")
                let a = NSAlert()
                a.messageText = "麥克風未開啟，聽寫用唔到"
                a.informativeText = "macOS 而家俾 Dictation 嘅麥克風權限係「拒絕」，所以錄出嚟係全靜音，一個字都辨識唔到。\n\n撳下面嘅掣會直接打開設定頁，跟住：\n① 喺左邊揀「麥克風」\n② 喺右邊搵到 Dictation，將開關撥去開啓\n③ 返嚟撳「重新啟動 App」"
                a.alertStyle = .warning
                self.presentHint(a) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
            }
        }

        // 權限檢查（兩個權限，缺一不可）：
        //   ① 輔助使用 Accessibility  —— 模擬 Cmd+V 自動貼上
        //   ② 輸入監視 Input Monitoring —— CGEventTap 收按鍵事件（觸發鍵！）
        // macOS 15 起呢兩個係獨立權限：開咗輔助使用唔代表有輸入監視；
        // 冇輸入監視個 tap 會建到、報告 enabled，但靜靜地收唔到任何按鍵
        // （2026-10-16 實測：用戶報「用一次後無反應」真正元凶）。
        let needsA11y = !AXIsProcessTrusted()
        let needsListen = !CGPreflightListenEventAccess()
        if needsA11y || needsListen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                let stillA11y = !AXIsProcessTrusted()
                let stillListen = !CGPreflightListenEventAccess()
                guard stillA11y || stillListen else { return }
                if stillListen { CGRequestListenEventAccess() }   // 彈系統原生授權窗
                DLog.w("權限未齊：輔助使用=\(stillA11y ? "缺" : "有") 輸入監視=\(stillListen ? "缺" : "有")")
                let a = NSAlert()
                a.messageText = "開齊兩個權限，聽寫先完全用到"
                a.informativeText = """
                ① 「輔助使用」—— 講完自動將字打入你個對話框（模擬 Cmd+V）
                ② 「輸入監視」—— 收到你撳觸發鍵嘅按鍵事件

                兩個係獨立權限，開咗一個唔代表有第二個。撳下面掣會開系統設定，
                逐項剔返 Dictation 就得。

                ⚠️ 開咗掣但仍然話未開？揀住列表中嘅 Dictation → 撳「−」刪咗 → 再撳「+」加返。
                """
                a.alertStyle = .warning
                a.addButton(withTitle: "打開權限設定")
                a.addButton(withTitle: "遲啲先")
                self.presentHint(a) {
                    if stillListen && !CGPreflightListenEventAccess() {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                    } else {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
        }

        // 唔再每次啟動都強制彈出主視窗 —— 用戶明確要求「唔使開主版面都要應用到」。
        // 主視窗係設定／診斷用，要開有幾種方法：
        //   ① Dock 圖示撳一下（applicationShouldHandleReopen 會彈返）
        //   ② 選單列 🎙 →「打開主視窗」
        // 而家有權限問題先至會自動 pop（下面兩個 if 會經 presentHint 彈出主視窗）。

        // 每 2 秒刷新主視窗 + 記錄權限狀態，等權限狀態即時更新
        var wasTrusted = AXIsProcessTrusted()
        var wasListen = CGPreflightListenEventAccess()
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            let mic: String
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined: mic = "未決定"
            case .restricted:    mic = "受限"
            case .denied:        mic = "已拒絕"
            case .authorized:    mic = "已授權"
            @unknown default:    mic = "未知"
            }
            let nowTrusted = AXIsProcessTrusted()
            let nowListen = CGPreflightListenEventAccess()
            // 用戶開咗輔助使用 → 立刻重啟 CGEventTap，唔使重啟 app
            if nowTrusted && !wasTrusted {
                DLog.w("輔助使用權限剛剛開啟 → 重啟修飾鍵熱鍵")
                Controller.shared.reloadHotkey()
            }
            // 用戶開咗輸入監視 → 都要重建 tap：冇權限嗰陣建嘅 tap 係聾嘅
            if nowListen && !wasListen {
                DLog.w("輸入監視權限剛剛開啟 → 重建 CGEventTap（之前個係聾）")
                Controller.shared.reloadHotkey()
            }
            wasTrusted = nowTrusted
            wasListen = nowListen
            DLog.w("tick a11y=\(nowTrusted ? "✅" : "❌") listen=\(nowListen ? "✅" : "❌") mic=\(mic)")
            MainWindow.shared.reload()
        }

        // 錄音期間每 0.7 秒檢查一次：換咗輸出裝置（插耳機／AirPods）就順手靜音埋新嗰個，
        // 否則新裝置會照樣出聲，靜音等於白做。
        Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { _ in
            guard Prefs.muteOthers, Controller.shared.state == .recording else { return }
            SystemAudio.ensureCurrentDeviceMuted()
        }

        // 自我測試觸發（三選一）：
        //   ① --selftest                    直接行 binary 時用
        //   ② DICTATION_SELFTEST=1          有環境變數時用
        //   ③ 落標記檔 ~/.cache/dictation-work/run-selftest
        //      （`open --args` 傳唔到 argument，標記檔最可靠）
        let flagPath = NSHomeDirectory() + "/.cache/dictation-work/run-selftest"
        let flagSelftest = FileManager.default.fileExists(atPath: flagPath)
        if flagSelftest { try? FileManager.default.removeItem(atPath: flagPath) }
        let selftest = CommandLine.arguments.contains("--selftest")
            || ProcessInfo.processInfo.environment["DICTATION_SELFTEST"] != nil
            || flagSelftest
        if selftest {
            DLog.w("selftest 啟動")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                Controller.shared.toggleDictation()
                DLog.w("selftest: 開始錄音")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    Controller.shared.toggleDictation()
                    DLog.w("selftest: 停止，開始辨識")
                }
            }
        }

        // 自動化迴路（紅綠燈）：落標記檔 ~/.cache/dictation-work/run-taptest，
        // 啟動後自動送 3 粒探測事件，驗證「觸發鍵收事件」係咪一次後死亡。
        // 用法：pkill -f Dictation.app; touch ~/.cache/dictation-work/run-taptest
        //       open -n /Applications/Dictation.app; sleep 12
        //       grep -E "TAPTEST|探測" ~/.cache/dictation-work/debug.log
        let tapTestPath = NSHomeDirectory() + "/.cache/dictation-work/run-taptest"
        if FileManager.default.fileExists(atPath: tapTestPath) {
            try? FileManager.default.removeItem(atPath: tapTestPath)
            DLog.w("taptest 啟動（自動送探測事件）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                let hk = Controller.shared.hotkey
                hk.sendProbe()
                DLog.w("TAPTEST #1 送出探測")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    hk.sendProbe()
                    DLog.w("TAPTEST #2 送出探測（模擬「第二次就死」）")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        hk.sendProbe()
                        DLog.w("TAPTEST #3 送出探測")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            DLog.w("TAPTEST 結果：探測總數=\(hk.probeAttempts) 失敗=\(hk.probeFails) 系統停用事件=\(hk.disableEvents) → \(hk.probeFails == 0 ? "PASS（tappy 一路收到事件）" : "FAIL（中間死過，已自動重建 \(Diag.shared.tapRebuilds) 次）")")
                        }
                    }
                }
            }
        }
    }

    /// 喺 Dock 撳 app 圖示時，重新顯示主視窗
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.shared.show()
        return true
    }

    /// App 變背景 —— 記錄低，用嚟同 tap 死亡時間對照
    func applicationDidResignActive(_ notification: Notification) {
        DLog.w("▼ app 變背景（resign active）")
    }

    /// 每次 App 變 active 都確保 CGEventTap 健康：冇嘅話起返，被停用嘅話撳返開
    func applicationDidBecomeActive(_ notification: Notification) {
        DLog.w("▲ app 變前台（become active）")
        let hk = Controller.shared.hotkey
        if !hk.isTapAlive() {
            DLog.w("app became active — CGEventTap 唔喺度，重新起")
            Controller.shared.reloadHotkey()
        } else if !hk.isTapEnabled() {
            DLog.w("app became active — CGEventTap 存在但被停用，撳返開")
            Diag.shared.tapRebuilds += 1
            Controller.shared.reloadHotkey()
        }
    }

    // -------- 權限 --------
    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    func checkAccessibility() {
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }
    }

    func alert(_ msg: String) {
        let a = NSAlert()
        a.messageText = "Dictation"
        a.informativeText = msg
        a.alertStyle = .warning
        a.addButton(withTitle: "知道了")
        a.runModal()
    }

    // -------- 狀態顯示 --------
    func render(_ s: DictationState) {
        guard let b = statusItem.button else { return }
        switch s {
        case .idle:
            b.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
            b.contentTintColor = nil
        case .recording:
            b.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: nil)
            b.contentTintColor = .systemRed
        case .working:
            b.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
            b.contentTintColor = .systemOrange
        }
        b.image?.isTemplate = (s == .idle)
        b.toolTip = "Dictation — \(statusText(s))"
        rebuildMenu()
    }

    func statusText(_ s: DictationState) -> String {
        switch s {
        case .idle:      return "就緒"
        case .recording: return "錄音中…"
        case .working:   return "辨識中…"
        }
    }

    // -------- 選單 --------
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func rebuildMenu() {
        menu.removeAllItems()

        let head = NSMenuItem(title: "🎙 \(statusText(Controller.shared.state))", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)

        let hintText = Prefs.triggerMode == "toggle"
            ? "撳一次「\(currentTrigger().name)」開始，再撳一次出字"
            : "按住「\(currentTrigger().name)」講話，鬆手出字"
        let hint = NSMenuItem(title: hintText, action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        let showWin = NSMenuItem(title: "打開主視窗", action: #selector(showMainWindow), keyEquivalent: "")
        showWin.target = self
        menu.addItem(showWin)

        menu.addItem(.separator())

        // 觸發鍵
        let trigItem = NSMenuItem(title: "觸發鍵", action: nil, keyEquivalent: "")
        let trigMenu = NSMenu()
        for t in kTriggers {
            let i = NSMenuItem(title: t.name, action: #selector(pickTrigger(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = t.id
            i.state = (Prefs.trigger == t.id) ? .on : .off
            trigMenu.addItem(i)
        }
        trigItem.submenu = trigMenu
        menu.addItem(trigItem)

        // 模型
        let modelItem = NSMenuItem(title: "模型", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        let models = availableModels()
        if models.isEmpty {
            let i = NSMenuItem(title: "（未下載任何模型）", action: nil, keyEquivalent: "")
            i.isEnabled = false
            modelMenu.addItem(i)
        }
        for m in models {
            let i = NSMenuItem(title: m, action: #selector(pickModel(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = m
            i.state = (Prefs.model == m) ? .on : .off
            modelMenu.addItem(i)
        }
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        // 語言
        let langItem = NSMenuItem(title: "語言", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for (code, label) in kLanguages {
            let i = NSMenuItem(title: label, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = code
            i.state = (Prefs.language == code) ? .on : .off
            langMenu.addItem(i)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        menu.addItem(.separator())

        let paste = NSMenuItem(title: "自動貼上", action: #selector(togglePaste), keyEquivalent: "")
        paste.target = self
        paste.state = Prefs.autoPaste ? .on : .off
        menu.addItem(paste)

        let mute = NSMenuItem(title: "錄音時靜音其他聲音", action: #selector(toggleMute), keyEquivalent: "")
        mute.target = self
        mute.state = Prefs.muteOthers ? .on : .off
        menu.addItem(mute)

        // 「去口語詞」只對 AI 大整理模式有意義；執字粒模式本身一定會清口語詞，
        // 擺個冇作用嘅開關出嚟只會令人混亂，所以唔顯示。
        if CleanupEngine.current == .apple || CleanupEngine.current == .gpt4omini {
            let clean = NSMenuItem(title: "去口語詞", action: #selector(toggleClean), keyEquivalent: "")
            clean.target = self
            clean.state = Prefs.cleanFillers ? .on : .off
            menu.addItem(clean)
        }

        // 文字清理引擎
        let engItem = NSMenuItem(title: "文字清理方式", action: nil, keyEquivalent: "")
        let engMenu = NSMenu()
        for e in CleanupEngine.allCases {
            let i = NSMenuItem(title: e.label, action: #selector(pickCleanup(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = e.rawValue
            i.state = (e == CleanupEngine.current) ? .on : .off
            engMenu.addItem(i)
        }
        engMenu.addItem(.separator())
        let status = NSMenuItem(title: "Apple 內建 AI 狀態：\(CleanService.appleStatus())",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        engMenu.addItem(status)
        engItem.submenu = engMenu
        menu.addItem(engItem)

        // DeepSeek：key + 力度（只喺揀咗 DeepSeek 先顯示）
        if CleanupEngine.current == .deepseek {
            let dsKey = NSMenuItem(
                title: KeyStore.deepseek.get() == nil
                    ? "⚠️ 未設定 DeepSeek key — 撳呢度貼入"
                    : "🧠 DeepSeek key：\(KeyStore.deepseek.mask() ?? "")",
                action: #selector(setDeepSeekKey), keyEquivalent: "")
            dsKey.target = self
            menu.addItem(dsKey)

            let modelItem = NSMenuItem(title: "DeepSeek 模型：\(deepseekModelName(Prefs.deepseekModel))",
                                       action: nil, keyEquivalent: "")
            let modelMenu = NSMenu()
            for (id, name) in kDeepSeekModels {
                let i = NSMenuItem(title: name, action: #selector(pickDeepSeekModel(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = id
                i.state = (Prefs.deepseekModel == id) ? .on : .off
                modelMenu.addItem(i)
            }
            modelItem.submenu = modelMenu
            menu.addItem(modelItem)

            let modeItem = NSMenuItem(title: "DeepSeek 力度", action: nil, keyEquivalent: "")
            let modeMenu = NSMenu()
            for (id, name) in [("strict", "執字粒（字數必須一樣）"), ("light", "輕整理（讀得通順少少）")] {
                let i = NSMenuItem(title: name, action: #selector(pickDeepSeekMode(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = id
                i.state = (Prefs.deepseekMode == id) ? .on : .off
                modeMenu.addItem(i)
            }
            modeItem.submenu = modeMenu
            menu.addItem(modeItem)

            let fidItem = NSMenuItem(title: "保留度 \(Prefs.fidelity)%", action: nil, keyEquivalent: "")
            let fidMenu = NSMenu()
            for pct in [95, 90, 85, 80] {
                let i = NSMenuItem(title: "\(pct)%", action: #selector(pickFidelity(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = pct
                i.state = (Prefs.fidelity == pct) ? .on : .off
                fidMenu.addItem(i)
            }
            fidItem.submenu = fidMenu
            menu.addItem(fidItem)
        }

        // OpenAI key（只喺揀咗 GPT-4o mini 先顯示）
        if CleanupEngine.current == .gpt4omini {
            let keyItem = NSMenuItem(
                title: KeyStore.get() == nil
                    ? "⚠️ 未設定 OpenAI API key — 撳呢度輸入"
                    : "🔑 OpenAI key：\(KeyStore.mask() ?? "")",
                action: #selector(setKey), keyEquivalent: "")
            keyItem.target = self
            menu.addItem(keyItem)
        }

        menu.addItem(.separator())

        let permTitle: String
        if AXIsProcessTrusted() && CGPreflightListenEventAccess() {
            permTitle = "✅ 權限齊全（輔助使用 + 輸入監視）— 撳住觸發鍵講話可用"
        } else if !CGPreflightListenEventAccess() {
            permTitle = "⚠️ 未開「輸入監視」權限 — 撳呢度去開（觸發鍵收按鍵必備）"
        } else {
            permTitle = "⚠️ 未開「輔助使用」權限 — 撳呢度去開（自動貼上必備）"
        }
        let perm = NSMenuItem(title: permTitle, action: #selector(openAccessibility), keyEquivalent: "")
        perm.target = self
        menu.addItem(perm)

        let openLog = NSMenuItem(title: "睇歷史紀錄", action: #selector(openHistory), keyEquivalent: "")
        openLog.target = self
        menu.addItem(openLog)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "結束 Dictation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc func pickTrigger(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Prefs.trigger = id
        Controller.shared.reloadHotkey()
        rebuildMenu()
    }

    @objc func pickModel(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? String else { return }
        Prefs.model = m
        rebuildMenu()
    }

    @objc func pickLanguage(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? String else { return }
        Prefs.language = c
        rebuildMenu()
    }

    @objc func togglePaste() {
        Prefs.autoPaste.toggle()
        rebuildMenu()
    }

    @objc func toggleMute() {
        Prefs.muteOthers.toggle()
        // 由「開」變「關」嗰陣如果正在靜音，即刻還原，唔好等錄完
        if !Prefs.muteOthers { SystemAudio.restoreAfterRecording() }
        rebuildMenu()
        MainWindow.shared.reload()
    }

    @objc func toggleClean() {
        Prefs.cleanFillers.toggle()
        rebuildMenu()
    }

    @objc func pickCleanup(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        Prefs.cleanupEngine = raw
        if CleanupEngine.current == .gpt4omini && KeyStore.get() == nil {
            promptForKey()
        }
        if CleanupEngine.current == .deepseek && KeyStore.deepseek.get() == nil {
            promptForDeepSeekKey()
        }
        rebuildMenu()
    }

    @objc func setKey() {
        promptForKey()
    }

    @objc func setDeepSeekKey() {
        promptForDeepSeekKey()
    }

    @objc func pickDeepSeekMode(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Prefs.deepseekMode = id
        rebuildMenu()
        MainWindow.shared.reload()
    }

    @objc func pickFidelity(_ sender: NSMenuItem) {
        guard let pct = sender.representedObject as? Int else { return }
        Prefs.fidelity = pct
        rebuildMenu()
        MainWindow.shared.reload()
    }

    @objc func pickDeepSeekModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Prefs.deepseekModel = id
        rebuildMenu()
        MainWindow.shared.reload()
    }

    /// 通用 API key 輸入框。
    /// ⚠️ 2026-10-17：用戶報「key 不能複製貼上」。根因係 App 冇主選單（已修，見 buildMainMenu）。
    ///    呢度再加一個「貼上剪貼板」掣做後路 —— 就算用遠端桌面／剪貼板工具都一定貼到。
    func promptForAPIKey(store: ApiKeyStore, title: String, info: String, savedNote: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "sk-..."
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        if let existing = store.get() { field.stringValue = existing }
        a.accessoryView = field
        // 明確指定輸入框做 first responder，否則游標唔喺框內，Cmd+V 會貼去虛空
        a.window.initialFirstResponder = field
        a.addButton(withTitle: "儲存")
        a.addButton(withTitle: "取消")
        a.addButton(withTitle: "貼上剪貼板")

        var guardCount = 0
        while guardCount < 5 {
            guardCount += 1
            let resp = a.runModal()
            if resp == .alertFirstButtonReturn {
                let k = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if store.save(k) { alert(savedNote) } else { alert("儲存失敗：key 空白或寫唔到檔案。") }
                break
            } else if resp == .alertThirdButtonReturn {
                if let cb = NSPasteboard.general.string(forType: .string) {
                    field.stringValue = cb.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                continue      // 貼完再彈返同一個框，等用戶確認
            } else {
                break
            }
        }
        rebuildMenu()
        MainWindow.shared.reload()
    }

    func promptForDeepSeekKey() {
        promptForAPIKey(
            store: KeyStore.deepseek,
            title: "DeepSeek API key",
            info: """
            貼入你嘅 DeepSeek API key（sk- 開頭，喺 platform.deepseek.com 攞）。
            只會存喺你自己部機：~/.cache/dictation-work/deepseek_key（權限 600）

            用 deepseek-flash（DeepSeek-V4.1-Flash），一句幾十字約 ¥0.0001 以下。
            可以撳「貼上剪貼板」，或者直接 Cmd+V。
            """,
            savedNote: "已儲存。文字清理已切去「🧠 執字粒 · DeepSeek」。講一句試下。")
        if KeyStore.deepseek.get() != nil {
            Prefs.cleanupEngine = CleanupEngine.deepseek.rawValue
            rebuildMenu()
            MainWindow.shared.reload()
        }
    }

    @objc func showMainWindow() {
        MainWindow.shared.toggle()
    }

    func promptForKey() {
        promptForAPIKey(
            store: KeyStore.openai,
            title: "OpenAI API key",
            info: """
            入你嘅 OpenAI API key（sk- 開頭）。
            只會存喺你自己部機：~/.cache/dictation-work/openai_key（權限 600）

            用 gpt-4o-mini，一句 3 秒左右嘅說話約 $0.0001。
            可以撳「貼上剪貼板」，或者直接 Cmd+V。
            """,
            savedNote: "已儲存。之後每次辨識都會經 GPT-4o mini 清理。")
    }

    @objc func openAccessibility() {
        checkAccessibility()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc func openHistory() {
        if FileManager.default.fileExists(atPath: kLogFile) {
            NSWorkspace.shared.open(URL(fileURLWithPath: kLogFile))
        } else {
            alert("暫時未有紀錄。講一句試下先。")
        }
    }
}

// ---------------- 啟動 ----------------
// 離線自測（唔開 GUI）：
//   POLISH_TEST="原文" Dictation --test-polish   → 印出執字粒結果就退出
//   Dictation --test-polish                      → 跑內建回歸案例
// ⚠️ 2026-10-17：實測呢個 binary 只要 **argc ≥ 3**（多一個參數）就 SIGSEGV，
//    連 print 都出唔到（swift::RefCounts::incrementSlow / EXC_BAD_ACCESS）。
//    所以自測文字改用環境變數傳，唔用 argv 第三個參數。
func polishSelfTest() -> Never {
    setvbuf(stdout, nil, _IONBF, 0)
    Prefs.register()

    func emit(_ src: String) {
        print("原文：\(src)")
        print("結果：\(CleanService.tidyText(src))")
        print("")
    }

    // ⚠️ 2026-10-17：實測直接將 env／argv 出嚟嘅 String 放入 array 再 iterate，
    //    會 SIGSEGV（swift::RefCounts::incrementSlow）。所以先做一份原生副本，
    //    而且唔經 array 直接呼叫。
    let raw = ProcessInfo.processInfo.environment["POLISH_TEST"] ?? ""
    if !raw.isEmpty {
        emit(String(decoding: raw.utf8, as: UTF8.self))
    } else {
        emit("嗯，我我今日想講嘅係，聽日開會改三點。")                 // 填充詞 + 口吃
        emit("呢個 plan 我地要係星期五之前搞掂,唔該你幫我睇睇,慢慢來就得") // 半角標點；唔可以整爛「睇睇／慢慢」
        emit("我睇睇先，慢慢嚟，謝謝你，剛剛好。")                     // 全部正常疊字，一個都唔可以改
        emit("  幫 我 睇 下 個 報 告  ")                             // 中文字之間嘅空格
        emit("好")                                                 // 極短
    }
    // 雜訊幻覺過濾回歸測試
    let garbageCases = ["PENHUZI", "PENGASPEN", "PAUSE", "NARAT", "1234", "OK Google", "幫我睇下"]
    for g in garbageCases {
        print("幻覺測試 \(g) → \(CleanService.isGarbage(g) ? "當雜訊，丟棄" : "保留")")
    }

    // 行一次真正嘅入口（CleanService.run），確保 polish 路徑唔會 crash
    let probe = raw.isEmpty ? "嗯，我我今日想講嘅係，聽日開會改三點。" : String(decoding: raw.utf8, as: UTF8.self)
    print("--- 真正入口 run()，引擎=\(Prefs.cleanupEngine) ---")
    var done = false
    CleanService.run(probe) { out in
        print(out.isEmpty ? "（空白 → 唔會貼任何嘢）" : out)
        done = true
    }
    // DeepSeek 係非同步：要等回呼返嚟先 exit，否則永遠睇唔到結果
    let waitUntil = Date().addingTimeInterval(15)
    while !done && Date() < waitUntil {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    if !done { print("（15 秒內冇回呼 —— 網絡或 key 有問題）") }

    // 字形轉換回歸（按「輸出語言」）
    print("--- 字形轉換，輸出語言=\(languageName(Prefs.language)) ---")
    let scriptCases = ["处理好了个版链了", "这个项目还没有处理", "我今日想講嘅係，聽日開會改三點。", "develop 呢個 feature"]
    for t in scriptCases {
        print("\(t)  →  \(CleanService.applyScript(t))")
    }
    exit(0)
}

if CommandLine.arguments.contains("--test-polish") {
    polishSelfTest()
}

// 守門邏輯自測：Dictation --test-guard
if CommandLine.arguments.contains("--test-guard") {
    setvbuf(stdout, nil, _IONBF, 0)
    Prefs.register()

    func check(_ name: String, _ out: String, _ orig: String, _ expect: Bool) {
        let a = CleanService.normalizeForCompare(out)
        let b = CleanService.normalizeForCompare(orig)
        let lcs = CleanService.similarity(a, b)
        let ratio = Double(a.count) / Double(max(1, b.count))
        let got = CleanService.acceptRewrite(out, original: orig, strict: false)
        print("\(got == expect ? "✅" : "❌") \(name)：預期\(expect ? "接受" : "退回")，實際\(got ? "接受" : "退回")"
              + String(format: "  [%d→%d 字, lcs=%.3f, ratio=%.3f]", b.count, a.count, lcs, ratio))
    }
    print("保留度 = \(Prefs.fidelity)%　力度 = \(Prefs.deepseekMode)")
    check("繁簡轉字形（字數一樣）", "處理好了個版鏈了", "处理好了个版链了", true)
    check("改同音錯字", "我哋今日去飲茶", "我地今日去飲茶", true)
    check("只改標點", "幫我睇下個報告，有冇問題？", "幫我睇下個報告有冇問題", true)
    check("加料", "幫我睇下啦，唔該晒你先", "幫我睇下", false)
    check("刪走半句", "聽日開會改三點", "我今日想講嘅係，聽日開會改三點", false)
    check("語序調換", "今日我哋要講嘅係聽日開會改三點", "我今日想講嘅係聽日開會改三點", Prefs.fidelity < 85)
    exit(0)
}

// 離線自測 DeepSeek：DEEPSEEK_TEST="原文" Dictation --test-deepseek
if CommandLine.arguments.contains("--test-deepseek") {
    setvbuf(stdout, nil, _IONBF, 0)
    Prefs.register()
    let rawEnv = ProcessInfo.processInfo.environment["DEEPSEEK_TEST"]
        ?? "我地今日要係星期五之前搞掂,唔該你幫我睇睇個report"
    let src = String(decoding: rawEnv.utf8, as: UTF8.self)
    let tidy = CleanService.applyScript(CleanService.tidyText(src))   // 同真實流程一致：先轉字形
    print("模型：\(Prefs.deepseekModel)　力度：\(Prefs.deepseekMode)")
    print("key：\(KeyStore.deepseek.mask() ?? "（未設定）")")
    print("原文：\(src)")
    print("規則層：\(tidy)")
    var finished = false
    let t0 = Date()
    CleanService.cleanWithDeepSeek(tidy) { out in
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("DeepSeek（\(ms)ms）：\(out)")
        print(out == tidy ? "→ 同規則版一樣（冇改／被退回）" : "→ 有改動")
        finished = true
    }
    let deadline = Date().addingTimeInterval(20)
    while !finished && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    exit(0)
}

// 音效自測：Dictation --test-sound   （播「開始」→ 停 1 秒 → 播「停止」，然後退出）
if CommandLine.arguments.contains("--test-sound") {
    setvbuf(stdout, nil, _IONBF, 0)
    SoundFX.shared.prepare()
    print("播放『開始』音（660Hz → 990Hz）…")
    SoundFX.shared.playStart()
    RunLoop.current.run(until: Date().addingTimeInterval(1.2))
    print("播放『停止』音（990Hz → 660Hz）…")
    SoundFX.shared.playStop()
    RunLoop.current.run(until: Date().addingTimeInterval(1.2))
    print("完成（如果聽到兩聲『嘟‑嘟』就正常）")
    exit(0)
}

// 靜音自測：Dictation --test-mute   （靜音 2 秒後還原，順便驗證 crash 保險檔）
if CommandLine.arguments.contains("--test-mute") {
    setvbuf(stdout, nil, _IONBF, 0)
    guard let dev = SystemAudio.defaultOutput() else {
        print("✗ 搵唔到預設輸出裝置")
        exit(1)
    }
    print("原本：  \(SystemAudio.describe(dev))")
    SystemAudio.muteForRecording()
    print("靜音後：\(SystemAudio.describe(dev))")
    print("（等 2 秒…如果耳機／喇叭真係冇聲就正常）")
    RunLoop.current.run(until: Date().addingTimeInterval(2.0))
    SystemAudio.restoreAfterRecording()
    print("還原後：\(SystemAudio.describe(dev))")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 一般 App（會有 Dock 圖示同主視窗）—— 等雙擊一定有反應
app.setActivationPolicy(.regular)
DLog.w("app launching, policy=regular")
app.run()
