import AppKit
import SwiftTerm

@MainActor
protocol TerminalFindBarDelegate: AnyObject {
    func findBarDidChange(_ bar: TerminalFindBar)
    func findBar(_ bar: TerminalFindBar, next forward: Bool)
    func findBarDidClose(_ bar: TerminalFindBar)
}

/// Find in scrollback: a search field, "3 of 12", previous/next, case sensitivity and Done. Return finds the next
/// match, ⇧Return the previous, Escape closes and returns focus to the terminal.
@MainActor
final class TerminalFindBar: NSView, NSSearchFieldDelegate {
    weak var delegate: (any TerminalFindBarDelegate)?
    private let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let navigation = NSSegmentedControl()
    private let caseButton = NSButton(title: "Aa", target: nil, action: nil)
    private let done = NSButton(title: "Done", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = "Find in terminal"
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(fieldChanged)
        field.setAccessibilityLabel("Find in terminal")
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        navigation.segmentCount = 2
        navigation.trackingMode = .momentary
        navigation.controlSize = .small
        navigation.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous match"), forSegment: 0)
        navigation.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next match"), forSegment: 1)
        navigation.setToolTip("Previous Match (⇧⌘G)", forSegment: 0)
        navigation.setToolTip("Next Match (⌘G)", forSegment: 1)
        navigation.target = self
        navigation.action = #selector(navigate)
        caseButton.setButtonType(.pushOnPushOff)
        caseButton.bezelStyle = .accessoryBarAction
        caseButton.controlSize = .small
        caseButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        caseButton.toolTip = "Match Case"
        caseButton.setAccessibilityLabel("Match case")
        caseButton.target = self
        caseButton.action = #selector(fieldChanged)
        done.bezelStyle = .push
        done.controlSize = .small
        done.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        done.target = self
        done.action = #selector(close)
        let controls = NSStackView(views: [count, navigation, caseButton, done])
        controls.orientation = .horizontal
        controls.spacing = 6
        let separator = NSBox()
        separator.boxType = .separator
        for view in [field, controls, separator] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let preferredWidth = field.widthAnchor.constraint(equalToConstant: 320)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120), preferredWidth,
            field.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -8),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            controls.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            count.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor), separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    var searchText: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    var options: SearchOptions { SearchOptions(caseSensitive: caseButton.state == .on) }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// "3 of 12", "No matches", or nothing.
    func setCount(_ value: (index: Int, total: Int)?) {
        guard let value else {
            count.stringValue = ""
            return
        }
        count.stringValue = value.total == 0 ? "No matches" : value.index > 0 ? "\(value.index) of \(value.total)" : "\(value.total) found"
        count.setAccessibilityLabel(count.stringValue)
    }

    @objc private func fieldChanged() { delegate?.findBarDidChange(self) }
    @objc private func navigate() { delegate?.findBar(self, next: navigation.selectedSegment == 1) }
    @objc private func close() { delegate?.findBarDidClose(self) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            delegate?.findBar(self, next: !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            delegate?.findBarDidClose(self)
            return true
        default:
            return false
        }
    }
}
