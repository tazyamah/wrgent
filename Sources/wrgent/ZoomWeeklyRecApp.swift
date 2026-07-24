import SwiftUI
import AppKit
import UserNotifications
import Darwin

extension Notification.Name {
    static let wrgentTerminationRequested = Notification.Name("wrgent.terminationRequested")
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var terminationRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            RecLog.shared.log("notifications: permission granted=\(granted)")
        }
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            NSApp.windows.filter { !($0 is NSPanel) }.forEach { $0.orderOut(nil) }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationRequested else { return .terminateLater }
        terminationRequested = true
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

struct MenuBarStatusLabel: View {
    @ObservedObject var recorder: AudioRecorder

    var body: some View {
        menuIcon
            .font(.system(size: 15, weight: .medium))
    }

    @ViewBuilder
    private var menuIcon: some View {
        if recorder.isRecording {
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
        } else if recorder.isFinalizingRecording {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(.orange)
        } else if recorder.isTranscribing {
            Image(systemName: "waveform")
                .foregroundStyle(Color.purple)
        } else if recorder.isGeneratingSummary {
            Image(systemName: "doc.text.fill")
                .foregroundStyle(Color.purple)
        } else {
            Image(systemName: "mic")
                .foregroundStyle(.primary)
        }
    }
}

@main
struct WrgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var recorder = AudioRecorder()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(recorder)
        } label: {
            MenuBarStatusLabel(recorder: recorder)
        }
        .menuBarExtraStyle(.window)
    }
}
