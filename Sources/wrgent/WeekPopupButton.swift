import AppKit
import SwiftUI

/// An AppKit popup used instead of SwiftUI's menu-style Picker.
///
/// SwiftUI's `Picker(.menu)` is backed by `AppKitPopUpAdaptor`. On macOS 26 it
/// has crashed while delivering a selection from a MenuBarExtra popover. Keeping
/// this small control outside that adaptor also lets the selection handler defer
/// state changes until AppKit has finished tracking the menu.
struct WeekPopupButton: NSViewRepresentable {
    let weeks: [String]
    let selectedWeek: String
    let label: (String) -> String
    let onSelect: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.target = context.coordinator
        button.action = #selector(Coordinator.didSelectWeek(_:))
        configure(button)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        let currentWeeks = button.itemArray.compactMap { $0.representedObject as? String }
        if currentWeeks != weeks {
            configure(button)
        } else {
            select(selectedWeek, in: button)
        }
    }

    private func configure(_ button: NSPopUpButton) {
        button.removeAllItems()
        for week in weeks {
            button.addItem(withTitle: label(week))
            button.lastItem?.representedObject = week
        }
        select(selectedWeek, in: button)
    }

    private func select(_ week: String, in button: NSPopUpButton) {
        if let index = weeks.firstIndex(of: week) {
            button.selectItem(at: index)
        }
    }

    @MainActor final class Coordinator: NSObject {
        var onSelect: @MainActor (String) -> Void

        init(onSelect: @escaping @MainActor (String) -> Void) {
            self.onSelect = onSelect
        }

        @objc func didSelectWeek(_ sender: NSPopUpButton) {
            guard let week = sender.selectedItem?.representedObject as? String else { return }
            let handler = onSelect
            Task { @MainActor in
                await Task.yield()
                handler(week)
            }
        }
    }
}
