import AppKit
import SwiftUI

/// An AppKit-backed button for actions that open Codex from the menu-bar popover.
///
/// On macOS 26, the SwiftUI `Button` gesture path has crashed while dispatching
/// this action from a `MenuBarExtra` popover.  Keeping the control in AppKit and
/// deferring its callback until event tracking has finished avoids that path.
struct CodexActionButton: NSViewRepresentable {
    let title: String
    let systemImage: String
    let onClick: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onClick: onClick) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator,
                              action: #selector(Coordinator.didClick(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.onClick = onClick
        button.title = title
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
    }

    @MainActor final class Coordinator: NSObject {
        var onClick: @MainActor () -> Void

        init(onClick: @escaping @MainActor () -> Void) {
            self.onClick = onClick
        }

        @objc func didClick(_ sender: NSButton) {
            let handler = onClick
            Task { @MainActor in
                await Task.yield()
                handler()
            }
        }
    }
}

/// An AppKit-backed primary action for recording controls in the menu-bar popover.
///
/// The recording controls must not use SwiftUI `Button`: its gesture dispatch can
/// crash in a `MenuBarExtra` window on macOS 26 before the recording action runs.
struct RecordingActionButton: NSViewRepresentable {
    let title: String
    let systemImage: String
    let isDestructive: Bool
    let onClick: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onClick: onClick) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator,
                              action: #selector(Coordinator.didClick(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.imagePosition = .imageLeading
        configure(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.onClick = onClick
        configure(button)
    }

    private func configure(_ button: NSButton) {
        button.title = title
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        button.contentTintColor = isDestructive ? .systemRed : .controlAccentColor
    }

    @MainActor final class Coordinator: NSObject {
        var onClick: @MainActor () -> Void

        init(onClick: @escaping @MainActor () -> Void) {
            self.onClick = onClick
        }

        @objc func didClick(_ sender: NSButton) {
            let handler = onClick
            Task { @MainActor in
                await Task.yield()
                handler()
            }
        }
    }
}

/// A general AppKit button for every remaining action in the menu-bar popover.
///
/// Keeping all tappable controls out of SwiftUI's gesture dispatcher avoids the
/// macOS 26 `MenuBarExtra` crash path seen in the crash reports.
struct MenuBarActionButton: NSViewRepresentable {
    enum Style {
        case regular
        case prominent
        case plain
    }

    let title: String
    let systemImage: String?
    let isEnabled: Bool
    let controlSize: NSControl.ControlSize
    let style: Style
    let onClick: @MainActor () -> Void

    init(
        _ title: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        controlSize: NSControl.ControlSize = .small,
        style: Style = .regular,
        onClick: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.controlSize = controlSize
        self.style = style
        self.onClick = onClick
    }

    func makeCoordinator() -> Coordinator { Coordinator(onClick: onClick) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator,
                              action: #selector(Coordinator.didClick(_:)))
        configure(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.onClick = onClick
        configure(button)
    }

    private func configure(_ button: NSButton) {
        button.title = title
        button.image = systemImage.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: title)
        }
        button.imagePosition = systemImage == nil ? .noImage : .imageLeading
        button.isEnabled = isEnabled
        button.controlSize = controlSize
        switch style {
        case .regular:
            button.bezelStyle = .rounded
            button.contentTintColor = nil
        case .prominent:
            button.bezelStyle = .rounded
            button.contentTintColor = .controlAccentColor
        case .plain:
            button.bezelStyle = .inline
            button.contentTintColor = nil
        }
    }

    @MainActor final class Coordinator: NSObject {
        var onClick: @MainActor () -> Void

        init(onClick: @escaping @MainActor () -> Void) {
            self.onClick = onClick
        }

        @objc func didClick(_ sender: NSButton) {
            let handler = onClick
            Task { @MainActor in
                await Task.yield()
                handler()
            }
        }
    }
}

/// AppKit checkbox counterpart for settings toggles in the menu-bar popover.
struct MenuBarCheckbox: NSViewRepresentable {
    let title: String
    @Binding var isOn: Bool
    let isEnabled: Bool

    init(_ title: String, isOn: Binding<Bool>, isEnabled: Bool = true) {
        self.title = title
        _isOn = isOn
        self.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(isOn: $isOn) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator,
                              action: #selector(Coordinator.didToggle(_:)))
        configure(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.isOn = $isOn
        configure(button)
    }

    private func configure(_ button: NSButton) {
        button.title = title
        button.state = isOn ? .on : .off
        button.isEnabled = isEnabled
        button.controlSize = .small
    }

    @MainActor final class Coordinator: NSObject {
        var isOn: Binding<Bool>

        init(isOn: Binding<Bool>) { self.isOn = isOn }

        @objc func didToggle(_ sender: NSButton) {
            let newValue = sender.state == .on
            let binding = isOn
            Task { @MainActor in
                await Task.yield()
                binding.wrappedValue = newValue
            }
        }
    }
}

/// AppKit popup counterpart for the Whisper model selector.
struct ModelPopupButton: NSViewRepresentable {
    let models: [String]
    @Binding var selectedModel: String
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(selectedModel: $selectedModel) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.didSelect(_:))
        configure(button)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selectedModel = $selectedModel
        configure(button)
    }

    private func configure(_ button: NSPopUpButton) {
        if button.itemArray.map(\.title) != models {
            button.removeAllItems()
            button.addItems(withTitles: models)
        }
        button.selectItem(withTitle: selectedModel)
        button.isEnabled = isEnabled
        button.controlSize = .small
    }

    @MainActor final class Coordinator: NSObject {
        var selectedModel: Binding<String>

        init(selectedModel: Binding<String>) { self.selectedModel = selectedModel }

        @objc func didSelect(_ sender: NSPopUpButton) {
            guard let model = sender.selectedItem?.title else { return }
            let binding = selectedModel
            Task { @MainActor in
                await Task.yield()
                binding.wrappedValue = model
            }
        }
    }
}
