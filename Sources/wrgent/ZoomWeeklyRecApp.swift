import SwiftUI
import AppKit
import Combine
import UserNotifications
import Darwin

extension Notification.Name {
    static let wrgentTerminationRequested = Notification.Name("wrgent.terminationRequested")
    static let wrgentDismissMenuPanel = Notification.Name("wrgent.dismissMenuPanel")
}

/// Objective-C 例外による abort は Swift の `catch` を通らないため、アプリ本体とは
/// 別プロセスの最小限の監視役を起動する。通常終了では停止印を残し、異常終了なら
/// 同じアプリケーションバンドルを再起動する（5分間で最大3回）。
private final class CrashRelaunchGuardian {
    private let markerURL: URL
    private let restartStateURL: URL
    private let guardianDirectoryURL: URL

    init?(appURL: URL) {
        let pid = getpid()
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            RecLog.shared.log("crash guardian: Application Support directory unavailable")
            return nil
        }
        guardianDirectoryURL = applicationSupport
            .appendingPathComponent("wrgent", isDirectory: true)
            .appendingPathComponent("crash-guardian", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: guardianDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let values = try guardianDirectoryURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                RecLog.shared.log("crash guardian: unsafe guardian directory")
                return nil
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: guardianDirectoryURL.path
            )
        } catch {
            RecLog.shared.log("crash guardian: directory preparation failed: \(error.localizedDescription)")
            return nil
        }

        markerURL = guardianDirectoryURL
            .appendingPathComponent("guardian-\(pid)-\(UUID().uuidString)")
        restartStateURL = guardianDirectoryURL.appendingPathComponent("restart-state")
        do {
            try Data("restart".utf8).write(to: markerURL, options: .atomic)
        } catch {
            RecLog.shared.log("crash guardian: marker creation failed: \(error.localizedDescription)")
            return nil
        }

        let guardian = Process()
        guardian.executableURL = URL(fileURLWithPath: "/bin/sh")
        guardian.arguments = [
            "-c",
            "pid=\"$1\"; marker=\"$2\"; app=\"$3\"; " +
            "state=\"$4\"; while kill -0 \"$pid\" 2>/dev/null; do sleep 1; done; " +
            "if [ \"$(cat \"$marker\" 2>/dev/null)\" = restart ]; then " +
            "now=$(date +%s); window=0; count=0; " +
            "if [ -r \"$state\" ]; then IFS=: read -r window count < \"$state\"; fi; " +
            "case \"$window\" in ''|*[!0-9]*) window=0;; esac; " +
            "case \"$count\" in ''|*[!0-9]*) count=0;; esac; " +
            "if [ $((now-window)) -ge 300 ]; then window=$now; count=0; fi; " +
            "count=$((count+1)); printf '%s:%s\\n' \"$window\" \"$count\" > \"$state\"; " +
            "if [ \"$count\" -le 3 ]; then /usr/bin/open -gj \"$app\"; fi; fi; rm -f \"$marker\"",
            "wrgent-crash-guardian",
            String(pid),
            markerURL.path,
            appURL.path,
            restartStateURL.path
        ]
        guardian.standardOutput = FileHandle.nullDevice
        guardian.standardError = FileHandle.nullDevice
        do {
            try guardian.run()
            RecLog.shared.log("crash guardian: armed pid=\(pid)")
        } catch {
            try? FileManager.default.removeItem(at: markerURL)
            RecLog.shared.log("crash guardian: launch failed: \(error.localizedDescription)")
            return nil
        }
    }

    func disable() {
        try? Data("stop".utf8).write(to: markerURL, options: .atomic)
    }

    func markHealthy() {
        try? FileManager.default.removeItem(at: restartStateURL)
    }
}

/// SwiftUI の MenuBarExtra と NSPopover は macOS 26 の accessory アプリで
/// ステータス項目のクリック直後に表示を失うことがある。AppKit 側で status item
/// と非アクティブ化しない小型パネルのライフサイクルを所有し、クリック受信と
/// 表示を一つの経路に固定する。
@MainActor
private final class StatusItemPopoverController: NSObject {
    private let recorder: AudioRecorder
    // 以前のメニューバーアイコンと同じ占有幅に戻す。
    private let statusItem = NSStatusBar.system.statusItem(withLength: 16)
    private let panel: NSPanel
    private var recorderChange: AnyCancellable?
    private var dismissObserver: NSObjectProtocol?
    private var pendingShowTask: Task<Void, Never>?
    private var showGeneration = 0
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var deactivateObserver: NSObjectProtocol?

    init(recorder: AudioRecorder) {
        self.recorder = recorder
        let host = NSHostingController(rootView: AnyView(ContentView().environmentObject(recorder)))
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()

        guard let button = statusItem.button else {
            RecLog.shared.log("menu bar: failed to create status button")
            return
        }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.toolTip = "wrgent — クリックして開く"
        button.setAccessibilityLabel("wrgent")
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        button.layer?.masksToBounds = true

        panel.contentViewController = host
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .windowBackgroundColor

        dismissObserver = NotificationCenter.default.addObserver(
            forName: .wrgentDismissMenuPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismissPanel(reason: "requested")
            }
        }

        deactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.panel.isVisible else { return }
                self.dismissPanel(reason: "application deactivated")
            }
        }

        recorderChange = recorder.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusIcon()
            }
        }
        updateStatusIcon()
        RecLog.shared.log("menu bar: AppKit status item ready")
    }

    @objc private func togglePopover(_ sender: Any?) {
        if panel.isVisible || pendingShowTask != nil {
            dismissPanel(reason: "status item")
        } else {
            // NSStatusItem のクリック追跡が終わる前に開くと、macOS が直後に
            // 非表示へ戻す。MainActor の一回の yield では同じ追跡周期のことが
            // あるため、短い遅延と世代番号でクリック完了後だけを表示する。
            showGeneration &+= 1
            let generation = showGeneration
            pendingShowTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled,
                      let self,
                      self.showGeneration == generation else { return }
                self.pendingShowTask = nil
                self.showPanel()
            }
        }
    }

    func showPanel() {
        guard !panel.isVisible, let button = statusItem.button else {
            if statusItem.button == nil {
                RecLog.shared.log("menu bar: status button unavailable on click")
            }
            return
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        let contentSize = panel.contentView?.fittingSize ?? NSSize(width: 360, height: 480)

        let screen = button.window?.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.screens[0].visibleFrame
        // NSHostingView の fittingSize は長い会議名や件数で膨らむ。
        // 表示領域を固定し、会議一覧だけをスクロールさせる。
        let panelSize = NSSize(width: 360, height: min(contentSize.height, visibleFrame.height - 8))
        panel.setContentSize(panelSize)
        let statusFrame = button.window.map { window in
            window.convertToScreen(button.convert(button.bounds, to: nil))
        }.flatMap { frame in
            frame.isEmpty || frame.midY < visibleFrame.maxY - NSStatusBar.system.thickness * 2
                ? nil : frame
        }
        let anchorX = statusFrame?.midX ?? visibleFrame.maxX - panelSize.width / 2
        let anchorBottom = statusFrame?.minY ?? visibleFrame.maxY
        let x = min(max(anchorX - panelSize.width / 2, visibleFrame.minX),
                    visibleFrame.maxX - panelSize.width)
        let y = max(visibleFrame.minY, anchorBottom - panelSize.height - 4)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        RecLog.shared.log("menu bar: statusFrame=\(String(describing: statusFrame)) panelFrame=\(panel.frame)")
        // 非アクティブパネルではステータス項目の追跡終了時に隠れる事例がある。
        // 明示的にアプリとパネルを前面・キー化して、クリック後も残るようにする。
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startOutsideClickMonitoring()
        RecLog.shared.log("menu bar: panel opened")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            RecLog.shared.log("menu bar: panel visible=\(self.panel.isVisible)")
        }
    }

    private func dismissPanel(reason: String) {
        showGeneration &+= 1
        pendingShowTask?.cancel()
        pendingShowTask = nil
        stopOutsideClickMonitoring()
        if panel.isVisible {
            panel.orderOut(nil)
            RecLog.shared.log("menu bar: panel closed (\(reason))")
        }
    }

    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.panel.isVisible else { return }
                self.dismissPanel(reason: "outside click")
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible,
                      let window = event.window, window !== self.panel,
                      window !== self.statusItem.button?.window,
                      window !== NSApp.modalWindow,
                      window.sheetParent !== self.panel else { return }
                self.dismissPanel(reason: "outside window click")
            }
            return event
        }
    }

    private func stopOutsideClickMonitoring() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        let tint: NSColor
        let icon: StatusBadgeIcon
        if recorder.isRecording {
            tint = .systemRed
            icon = .microphone
        } else if recorder.isFinalizingRecording {
            tint = .systemOrange
            icon = .drive
        } else if recorder.isTranscribing {
            tint = .systemPurple
            icon = .waveform
        } else if recorder.isGeneratingSummary {
            tint = .systemPurple
            icon = .document
        } else {
            tint = .systemBlue
            icon = .microphone
        }

        // SF Symbolのテンプレート描画には戻さず、表示できた固定幅バッジ上へ
        // AppKitで直接描く非テンプレートの状態アイコンを載せる。
        button.image = Self.badgeImage(for: icon)
        button.title = ""
        button.imagePosition = .imageOnly
        button.contentTintColor = nil
        button.layer?.backgroundColor = tint.cgColor
    }

    private enum StatusBadgeIcon {
        case microphone
        case waveform
        case drive
        case document
    }

    private static func badgeImage(for icon: StatusBadgeIcon) -> NSImage {
        switch icon {
        case .microphone: microphoneBadgeImage()
        case .waveform: waveformBadgeImage()
        case .drive: driveBadgeImage()
        case .document: documentBadgeImage()
        }
    }

    private static func microphoneBadgeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 16))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.white.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 5, y: 7, width: 4, height: 6),
            xRadius: 2,
            yRadius: 2
        ).fill()

        NSColor.white.setStroke()
        let cradle = NSBezierPath()
        cradle.lineWidth = 1.6
        cradle.lineCapStyle = .round
        cradle.move(to: NSPoint(x: 3, y: 8))
        cradle.curve(
            to: NSPoint(x: 11, y: 8),
            controlPoint1: NSPoint(x: 3, y: 3.5),
            controlPoint2: NSPoint(x: 11, y: 3.5)
        )
        cradle.stroke()

        let stem = NSBezierPath()
        stem.lineWidth = 1.5
        stem.lineCapStyle = .round
        stem.move(to: NSPoint(x: 7, y: 4.5))
        stem.line(to: NSPoint(x: 7, y: 2.5))
        stem.move(to: NSPoint(x: 4.75, y: 2.5))
        stem.line(to: NSPoint(x: 9.25, y: 2.5))
        stem.stroke()
        image.isTemplate = false
        return image
    }

    private static func waveformBadgeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 16))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.white.setFill()
        for rect in [
            NSRect(x: 1.5, y: 5.5, width: 1.5, height: 5),
            NSRect(x: 4, y: 3.5, width: 1.5, height: 9),
            NSRect(x: 6.5, y: 1.5, width: 1.5, height: 13),
            NSRect(x: 9, y: 4.5, width: 1.5, height: 7),
            NSRect(x: 11.5, y: 6.5, width: 1.5, height: 3)
        ] {
            NSBezierPath(roundedRect: rect, xRadius: 0.75, yRadius: 0.75).fill()
        }
        image.isTemplate = false
        return image
    }

    private static func driveBadgeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 16))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.white.setStroke()
        let enclosure = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 3, width: 11, height: 10), xRadius: 2, yRadius: 2)
        enclosure.lineWidth = 1.6
        enclosure.stroke()
        let slot = NSBezierPath()
        slot.lineWidth = 1.4
        slot.lineCapStyle = .round
        slot.move(to: NSPoint(x: 4, y: 6))
        slot.line(to: NSPoint(x: 8.5, y: 6))
        slot.stroke()
        NSBezierPath(ovalIn: NSRect(x: 9.75, y: 5.25, width: 1.5, height: 1.5)).fill()
        image.isTemplate = false
        return image
    }

    private static func documentBadgeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 16))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.white.setStroke()
        let sheet = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 1.5, width: 9, height: 13), xRadius: 1.2, yRadius: 1.2)
        sheet.lineWidth = 1.5
        sheet.stroke()
        let lines = NSBezierPath()
        lines.lineWidth = 1.3
        lines.lineCapStyle = .round
        lines.move(to: NSPoint(x: 4.5, y: 10.5))
        lines.line(to: NSPoint(x: 9.5, y: 10.5))
        lines.move(to: NSPoint(x: 4.5, y: 7.5))
        lines.line(to: NSPoint(x: 9.5, y: 7.5))
        lines.move(to: NSPoint(x: 4.5, y: 4.5))
        lines.line(to: NSPoint(x: 7.5, y: 4.5))
        lines.stroke()
        image.isTemplate = false
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var terminationRequested = false
    private var crashRelaunchGuardian: CrashRelaunchGuardian?
    private let recorder = AudioRecorder()
    private var statusItemController: StatusItemPopoverController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        crashRelaunchGuardian = CrashRelaunchGuardian(appURL: Bundle.main.bundleURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.crashRelaunchGuardian?.markHealthy()
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            RecLog.shared.log("notifications: permission granted=\(granted)")
        }
        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemPopoverController(recorder: recorder)
        DispatchQueue.main.async {
            NSApp.windows.filter { !($0 is NSPanel) }.forEach { $0.orderOut(nil) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Finderなどから再度開いた場合も、録音状態を確認できるようにする。
        statusItemController?.showPanel()
        return false
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationRequested else { return .terminateLater }
        terminationRequested = true
        crashRelaunchGuardian?.disable()
        NotificationCenter.default.post(name: .wrgentDismissMenuPanel, object: nil)
        if !recorder.isRecording && !recorder.isStarting && !recorder.isFinalizingRecording {
            // 通常時の「終了」は即時に完了させる。終了待ちの返信経路を使うのは、
            // 録音ファイルの保存が必要な場合だけに限定する。
            RecLog.shared.log("application: terminating immediately")
            return .terminateNow
        }
        NotificationCenter.default.post(name: .wrgentTerminationRequested, object: nil)

        // A stuck framework writer must not turn graceful termination into an
        // unkillable app. AudioRecorder normally replies earlier after finalize.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 15) {
            RecLog.shared.log("application: termination finalize deadline reached")
            // This path is reached only after macOS has explicitly requested
            // termination. It remains independent of the main actor so a stuck
            // filesystem/framework callback cannot leave the app unquittable.
            Darwin.exit(EXIT_SUCCESS)
        }
        return .terminateLater
    }
}

@main
struct WrgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
