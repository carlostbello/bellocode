import AppKit
import DesignSystem
import SwiftTerm

@MainActor
protocol TerminalFindBarDelegate: AnyObject {
    func findBarDidChange(_ bar: TerminalFindBar)
    func findBar(_ bar: TerminalFindBar, next forward: Bool)
    func findBarDidClose(_ bar: TerminalFindBar)
}

/// Find in scrollback (§6 find bars): a 32 pt strip on `canvas` with a `border` hairline, the DS search field,
/// "3 of 12" (`meta text3`, tabular), previous / next icon buttons, a "Match case" toggle (Aa, on = `fillHover`) and a
/// ghost Done. Return finds the next match, ⇧Return the previous, Escape closes and returns focus to the terminal.
@MainActor
final class TerminalFindBar: NSView, NSTextFieldDelegate {
    weak var delegate: (any TerminalFindBarDelegate)?
    private let input = DSTextField(style: .search, placeholder: "Find in terminal")
    private var field: NSTextField { input.field }
    let count = NSTextField(labelWithString: "")
    private let previous = DSButton(icon: "chevron.up", accessibilityTitle: "Previous match", size: .small)
    private let next = DSButton(icon: "chevron.down", accessibilityTitle: "Next match", size: .small)
    private let caseButton = DSButton(title: "Aa", variant: .ghost, size: .small)
    private let done = DSButton(title: "Done", variant: .ghost, size: .small)

    override init(frame: NSRect) {
        super.init(frame: frame)
        input.showsHalo = false
        field.delegate = self
        field.setAccessibilityLabel("Find in terminal")
        count.font = .monospacedDigitSystemFont(ofSize: DS.TextRole.meta.font.pointSize, weight: .regular)
        count.textColor = DS.Color.text3
        count.alignment = .right
        previous.toolTip = "Previous Match (⇧⌘G)"
        next.toolTip = "Next Match (⌘G)"
        previous.target = self
        previous.action = #selector(previousMatch)
        next.target = self
        next.action = #selector(nextMatch)
        caseButton.isToggle = true
        caseButton.isMuted = true
        caseButton.toolTip = "Match Case"
        caseButton.accessibilityTitle = "Match case"
        caseButton.target = self
        caseButton.action = #selector(fieldChanged)
        done.target = self
        done.action = #selector(close)
        let controls = NSStackView(views: [count, previous, next, caseButton, done])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = DS.Space.s4
        controls.setCustomSpacing(DS.Space.s8, after: count)
        let separator = DSDivider()
        for view in [input, controls, separator] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let preferredWidth = input.widthAnchor.constraint(equalToConstant: 320)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DS.Size.terminalTabStrip),
            input.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.s8),
            input.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),
            input.heightAnchor.constraint(equalToConstant: DS.Size.controlSmall),
            input.widthAnchor.constraint(greaterThanOrEqualToConstant: 120), preferredWidth,
            input.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -DS.Space.s8),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.s8),
            controls.centerYAnchor.constraint(equalTo: input.centerYAnchor),
            count.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor), separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: DS.Border.hairline),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        DS.Color.canvas.setFill()
        dirtyRect.fill()
    }

    var searchText: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    var options: SearchOptions { SearchOptions(caseSensitive: caseButton.isSelected) }

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
    @objc private func previousMatch() { delegate?.findBar(self, next: false) }
    @objc private func nextMatch() { delegate?.findBar(self, next: true) }

    func controlTextDidChange(_ notification: Notification) { fieldChanged() }
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
