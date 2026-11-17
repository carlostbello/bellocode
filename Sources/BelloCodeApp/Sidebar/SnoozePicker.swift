import AppKit
import Engine
import Observation
import SwiftUI

/// "Snooze Until…": the presets with their times, and a custom date and time. A popover anchored to the thread's row
/// (keyboard: Tab between controls, Return snoozes, Escape closes).
struct SnoozePickerView: View {
    /// The custom date (an observable model: SwiftUI's `@State` macro is unavailable with Command Line Tools).
    @MainActor @Observable final class Model {
        var custom: Date
        init(custom: Date) { self.custom = custom }
    }

    let title: String
    let now: Date
    let onSnooze: (Date) -> Void
    let onCancel: () -> Void
    @Bindable var model: Model

    init(title: String, now: Date = Date(), onSnooze: @escaping (Date) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.now = now
        self.onSnooze = onSnooze
        self.onCancel = onCancel
        model = Model(custom: SnoozePreset.tomorrow.date(from: now))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
            VStack(spacing: 2) {
                ForEach(SnoozePreset.allCases, id: \.self) { preset in
                    let date = preset.date(from: now)
                    Button {
                        onSnooze(date)
                    } label: {
                        HStack {
                            Text(preset.title)
                            Spacer()
                            Text(ThreadRowPresentation.wakeText(date, now: now)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SnoozeRowStyle())
                    .accessibilityLabel("\(preset.title), until \(ThreadRowPresentation.wakeText(date, now: now))")
                }
            }
            Divider()
            Text("Custom").font(.subheadline).foregroundStyle(.secondary)
            DatePicker("Until", selection: $model.custom, in: now..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.field)
                .labelsHidden()
            HStack {
                Text("Wakes early if it needs you.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Snooze") { onSnooze(model.custom) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

private struct SnoozeRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5).fill(configuration.isPressed ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05)))
    }
}

/// Shows the snooze picker in a popover.
@MainActor
enum SnoozePicker {
    @discardableResult
    static func show(
        title: String, relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge = .maxX, onSnooze: @escaping (Date) -> Void
    ) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let host = NSHostingController(
            rootView: SnoozePickerView(
                title: title,
                onSnooze: { [weak popover] date in
                    popover?.close()
                    onSnooze(date)
                },
                onCancel: { [weak popover] in popover?.close() }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
        return popover
    }
}
