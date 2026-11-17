import AppKit
import BelloCore
import DesignSystem

/// A swatch: the token over the canvas, its name and value for the current variant.
@MainActor
final class Swatch: NSView {
    let token: DS.ColorToken

    init(_ token: DS.ColorToken) {
        self.token = token
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 168, height: 64) }

    override func draw(_ dirtyRect: NSRect) {
        let chip = NSRect(x: 0, y: 0, width: bounds.width, height: 34)
        DSDraw.fill(chip, radius: DS.Radius.md, color: token.nsColor)
        DSDraw.ring(chip, radius: DS.Radius.md, color: DS.Color.border)
        if token.group == .text {
            DSDraw.text("Aa text", in: chip.insetBy(dx: 8, dy: 0), font: DS.TextRole.body.font, color: DS.Color.canvas)
        }
        DSDraw.text(token.name, in: NSRect(x: 0, y: 36, width: bounds.width, height: 14), font: DS.TextRole.labelEmph.font, color: DS.Color.text)
        let variant = DS.Variant(effectiveAppearance)
        DSDraw.text(token.value(variant).description, in: NSRect(x: 0, y: 50, width: bounds.width, height: 14), font: DS.TextRole.meta.font, color: DS.Color.text3)
    }
}

/// Text-token chips: each text colour on each surface it is used on.
@MainActor
final class TextOnSurface: NSView {
    let surface: DS.ColorToken

    init(_ surface: DS.ColorToken) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 168, height: 120) }

    override func draw(_ dirtyRect: NSRect) {
        DSDraw.fill(bounds, radius: DS.Radius.md, color: surface.nsColor)
        DSDraw.ring(bounds, radius: DS.Radius.md, color: DS.Color.border)
        let variant = DS.Variant(effectiveAppearance)
        let bg = surface.value(variant).over(DS.ColorToken.canvas.value(variant))
        var y: CGFloat = 8
        DSDraw.text(surface.name, in: NSRect(x: 10, y: y, width: bounds.width - 20, height: 14), font: DS.TextRole.metaEmph.font, color: DS.Color.text3)
        y += 18
        for name in ["text", "text2", "text3", "text4"] {
            let token = DS.ColorToken.named(name)!
            let ratio = token.value(variant).contrast(on: bg)
            DSDraw.text(name, in: NSRect(x: 10, y: y, width: 60, height: 18), font: DS.TextRole.body.font, color: token.nsColor)
            DSDraw.text(String(format: "%.1f:1", ratio), in: NSRect(x: 80, y: y, width: 70, height: 18), font: DS.TextRole.meta.font, color: token.nsColor, alignment: .right)
            y += 21
        }
    }
}

@MainActor
enum Sheets {
    // MARK: Tokens

    static func tokens() -> Sheet {
        let sheet = Sheet(width: 1180)
        sheet.heading("Colour tokens")
        sheet.caption("visual-language.md §1. Each chip is the token over `canvas`; value shown for this appearance.")
        for group in DS.ColorToken.Group.allCases {
            let tokens = DS.ColorToken.all.filter { $0.group == group }
            for chunk in stride(from: 0, to: tokens.count, by: 5) {
                let slice = Array(tokens[chunk..<min(chunk + 5, tokens.count)])
                sheet.row(chunk == 0 ? group.rawValue : "", slice.map(Swatch.init), gap: 16)
            }
        }
        sheet.heading("Text on surfaces (WCAG ratio)")
        sheet.row("", ["canvas", "sidebar", "raised", "message", "rowActive"].map { TextOnSurface(DS.ColorToken.named($0)!) }, gap: 16)
        sheet.heading("Type roles (base 13)")
        for role in DS.TextRole.allCases {
            let s = role.spec
            let sample = makeLabel("\(role.rawValue) — The flake comes from MarkdownStream 0123456789", role: role, color: DS.Color.text)
            sample.attributedStringValue = NSAttributedString(
                string: "The flake comes from MarkdownStream sharing one buffer 0123456789", attributes: role.attributes(color: DS.Color.text))
            sheet.row("\(role.rawValue) \(Int(s.size * 10) / 10)/\(Int(s.lineHeight))", [sample], sizes: [NSSize(width: 820, height: role.lineHeight)], height: max(22, role.lineHeight))
        }
        sheet.heading("Radii")
        let radii: [(String, CGFloat)] = [("xs 4", DS.Radius.xs), ("sm 6", DS.Radius.sm), ("md 8", DS.Radius.md), ("lg 10", DS.Radius.lg), ("xl 16", DS.Radius.xl)]
        sheet.row("", radii.map { name, radius in
            let card = DSCard(style: .raised)
            card.radius = radius
            let label = makeLabel(name, role: .meta, color: DS.Color.text3)
            label.frame = NSRect(x: 10, y: 8, width: 80, height: 14)
            card.addSubview(label)
            return card
        }, sizes: Array(repeating: NSSize(width: 120, height: 64), count: radii.count), gap: 16)
        return sheet
    }

    // MARK: Controls

    static func button(_ title: String, _ variant: DSButton.Variant, size: DSButton.Size = .regular, hint: String? = nil, symbol: String? = nil, state: String = "rest") -> DSButton {
        let button = DSButton(title: title, variant: variant, size: size, symbolName: symbol, shortcutHint: hint)
        apply(state, to: button)
        return button
    }

    static func apply(_ state: String, to control: DSControl) {
        switch state {
        case "hover": control.setDisplayState(hovered: true)
        case "pressed": control.setDisplayState(hovered: true, pressed: true)
        case "focused": control.setDisplayState(focused: true)
        case "disabled": control.isEnabled = false
        case "selected": control.isSelected = true
        default: break
        }
    }

    static let states = ["rest", "hover", "pressed", "focused", "disabled"]

    static func controls() -> Sheet {
        let sheet = Sheet(width: 1180)
        sheet.heading("Buttons")
        sheet.caption("rest · hover · pressed · focused (keyboard) · disabled. Pressed also scales to 0.97 on screen (not in stills).")
        for variant in DSButton.Variant.allCases {
            let title = ["primary": "Allow once", "outline": "Always allow", "ghost": "Retry", "destructive": "Delete"][variant.rawValue]!
            let hint = variant == .primary ? "⌥⌘Y" : (variant == .outline ? "⇧⌥⌘Y" : nil)
            sheet.row(variant.rawValue, states.map { button(title, variant, hint: hint, state: $0) })
        }
        sheet.row("small", DSButton.Variant.allCases.map { button($0.rawValue.capitalized, $0, size: .small) } + [button("Commit 3", .outline, size: .small, symbol: "arrow.triangle.branch")])
        sheet.row("with glyph", [
            button("Open", .outline, symbol: "arrow.up.forward.square"), button("Commit", .outline, hint: "⇧⌘C", symbol: "arrow.triangle.branch"),
            button("Add project", .ghost, symbol: "plus"), button("Stop", .outline, symbol: "stop.fill"),
        ])
        let truncated = button("Always allow for this project", .outline, hint: "⇧⌥⌘Y")
        let truncated2 = button("Always allow for this project", .outline, hint: "⇧⌥⌘Y")
        sheet.row("narrow (hint dropped first)", [button("Always allow for this project", .outline, hint: "⇧⌥⌘Y"), truncated, truncated2],
                  sizes: [nil, NSSize(width: 200, height: 28), NSSize(width: 140, height: 28)])
        let icons = ["sidebar.left", "square.and.pencil", "apple.terminal", "sidebar.right", "doc.on.doc", "paperclip", "ellipsis"]
        sheet.row("icon", icons.enumerated().map { index, name in
            let b = DSButton(icon: name, accessibilityTitle: name)
            apply(index == 3 ? "selected" : (index == 1 ? "hover" : (index == 2 ? "focused" : "rest")), to: b)
            return b
        } + [DSButton(icon: "gearshape", accessibilityTitle: "Settings", size: .small)])

        sheet.heading("Tabs and segmented")
        let tabs = DSTabBar(items: [
            DSChoiceItem(id: "changes", title: "Changes", symbolName: "plusminus", count: 3),
            DSChoiceItem(id: "files", title: "Files", symbolName: "doc.on.doc"),
            DSChoiceItem(id: "browser", title: "Browser", symbolName: "globe"),
            DSChoiceItem(id: "terminal", title: "Terminal", symbolName: "apple.terminal"),
            DSChoiceItem(id: "agents", title: "Agents", symbolName: "point.3.connected.trianglepath.dotted", count: 2),
        ], selectedID: "changes")
        tabs.choiceButtons[2].setDisplayState(hovered: true)
        tabs.choiceButtons[3].setDisplayState(focused: true)
        sheet.row("tab bar (hover Browser, focus Terminal)", [tabs])
        let effort = DSSegmented(items: ["Low", "Medium", "High"].map { DSChoiceItem(id: $0, title: $0) }, selectedID: "High")
        let layout = DSSegmented(items: [
            DSChoiceItem(id: "unified", title: "", symbolName: "rectangle.split.1x2", accessibilityLabel: "Unified"),
            DSChoiceItem(id: "split", title: "", symbolName: "rectangle.split.2x1", accessibilityLabel: "Split"),
        ], selectedID: "unified")
        sheet.row("segmented", [effort, layout])

        sheet.heading("Selects and fields")
        let selects: [DSSelectButton] = [
            DSSelectButton(title: "This turn", chevron: .upDown),
            DSSelectButton(title: "Build", symbolName: "hammer", chevron: .down, size: .small),
            DSSelectButton(title: "Claude Sonnet 4.5", symbolName: "sparkle", chevron: .down, size: .small),
            DSSelectButton(title: "High", symbolName: "cpu", chevron: .down, size: .small),
            DSSelectButton(title: "Ask", symbolName: "lock", chevron: .down, size: .small),
        ]
        selects[2].isOpen = true
        selects[3].setDisplayState(hovered: true)
        selects[4].setDisplayState(focused: true)
        sheet.row("select (open, hover, focus)", selects)
        let field = DSTextField(placeholder: "Branch name")
        let focusedField = DSTextField(placeholder: "Branch name")
        focusedField.stringValue = "fix/parser-recovery"
        focusedField.setDisplayFocused(true)
        let search = DSTextField(style: .search, placeholder: "Search")
        search.shortcutHint = "⌘K"
        sheet.row("text field (rest, focused)", [field, focusedField], sizes: [NSSize(width: 240, height: 34), NSSize(width: 240, height: 34)])
        sheet.row("search field", [search], sizes: [NSSize(width: 384, height: 34)])

        sheet.heading("Toggles")
        for kind in DSToggle.Kind.allCases {
            let views: [DSControl] = [
                DSToggle(kind: kind, title: "Off"), DSToggle(kind: kind, title: "On", isOn: true),
                { let t = DSToggle(kind: kind, title: "Hover"); t.setDisplayState(hovered: true); return t }(),
                { let t = DSToggle(kind: kind, title: "Focused", isOn: true); t.setDisplayState(focused: true); return t }(),
                { let t = DSToggle(kind: kind, title: "Disabled", isOn: true); t.isEnabled = false; return t }(),
            ]
            sheet.row(kind.rawValue, views, gap: 24)
        }

        sheet.heading("Pills, key caps, counts")
        let running = DSPill("2 running", tone: .info)
        running.showsSpinner = true
        sheet.row("pills", [running, DSPill("1 needs you", tone: .warning), DSPill("1 failed", tone: .danger), DSPill("Done", tone: .success),
                             DSPill("@explore"), DSPill("Free", tone: .success), DSPill("Approval", tone: .warning, symbolName: "exclamationmark.shield")])
        let needs = CountBadge()
        needs.isProminent = true
        needs.tint = DS.Color.warningText
        needs.count = 2
        let plain = CountBadge()
        plain.count = 7
        sheet.row("kbd / counts", [DSKbd("⌘K"), DSKbd("⇧⌘M"), DSKbd("esc"), DSKbd("↩"), DSKbd("↑↓"), needs, plain])

        sheet.heading("Status glyphs (glyph + word)")
        let statuses: [SessionStatus] = [.running, .awaitingApproval, .awaitingAnswer, .failed, .finishedUnread, .stopping, .idle, .unknown]
        sheet.row("status", statuses.map { status in
            let stack = NSStackView()
            stack.spacing = 6
            let glyph = DSStatusGlyphView()
            glyph.status = status
            glyph.showsIdle = true
            glyph.setFrameSize(NSSize(width: 14, height: 14))
            stack.addArrangedSubview(glyph)
            glyph.widthAnchor.constraint(equalToConstant: 14).isActive = true
            glyph.heightAnchor.constraint(equalToConstant: 14).isActive = true
            let glyphInfo = StatusGlyph(status)
            stack.addArrangedSubview(makeLabel(glyphInfo.label, role: .meta, color: glyphInfo.tone == .neutral ? DS.Color.text3 : glyphInfo.tint))
            return stack
        }, sizes: Array(repeating: NSSize(width: 118, height: 18), count: statuses.count), gap: 4)
        let done = DSStatusGlyphView()
        done.symbolOverride = "checkmark"
        done.toneOverride = .success
        let project = ProjectIcon()
        sheet.row("done, project icon", [done, project], sizes: [NSSize(width: 14, height: 14), NSSize(width: 16, height: 16)])

        sheet.heading("Rows, cards, dividers")
        sheet.row("row backgrounds", [DSRowStyle.rest, .hover, .selected, .active].map { style in rowSample(style, focused: false) } + [rowSample(.active, focused: true)],
                  sizes: Array(repeating: NSSize(width: 168, height: 28), count: 5))
        let raised = DSCard(style: .raised)
        let inset = DSCard(style: .inset)
        let tinted = DSCard(style: .tinted(.warning))
        let message = DSCard(style: .message)
        for (card, text) in [(raised, "raised · r16"), (inset, "inset · codeFill · r8"), (tinted, "tinted warning 4.5 %"), (message, "message bubble")] {
            let label = makeLabel(text, role: .label, color: DS.Color.text2)
            label.frame = NSRect(x: 12, y: 10, width: 180, height: 16)
            card.addSubview(label)
        }
        sheet.row("cards", [raised, inset, tinted, message], sizes: Array(repeating: NSSize(width: 200, height: 64), count: 4), gap: 16)
        sheet.row("divider", [DSDivider()], sizes: [NSSize(width: 400, height: 1)], height: 12)

        sheet.heading("Toast, empty state, scroller")
        let toast = UndoToastView()
        toast.translatesAutoresizingMaskIntoConstraints = true
        toast.show("Archived “Tidy CI cache keys”")
        sheet.row("toast (solid fallback)", [toast], sizes: [NSSize(width: 340, height: 36)])
        let empty = EmptyStateView(symbolName: "tray", title: "No threads yet", detail: "Start a thread to put an agent to work in this project.", actionTitle: "New thread")
        sheet.row("empty state", [empty], sizes: [NSSize(width: 420, height: 200)])
        sheet.row("scroller knob", [scrollerSample()], sizes: [NSSize(width: 200, height: 120)])
        return sheet
    }

    static func rowSample(_ style: DSRowStyle, focused: Bool) -> NSView {
        let background = DSRowBackgroundView()
        background.style = style
        background.showsFocusRing = focused
        let label = makeLabel(focused ? "focused" : "\(style)", role: .body, color: DS.Color.sidebarText)
        label.frame = NSRect(x: 10, y: 5, width: 140, height: 18)
        let container = NSView()
        background.frame = NSRect(x: 0, y: 0, width: 168, height: 28)
        container.addSubview(background)
        container.addSubview(label)
        return container
    }

    static func scrollerSample() -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        scroll.documentView = doc
        DSScroller.install(on: scroll)
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        scroll.verticalScroller?.knobProportion = 0.3
        return scroll
    }

    // MARK: Menus and glass

    static func modelPickerEntries() -> [DSMenuEntry] {
        [
            .header(id: "h-anthropic", title: "Anthropic", trailing: "Connected"),
            .row(DSMenuRow(id: "sonnet", title: "Claude Sonnet 4.5", trailing: "200K   $3 / $15", isChecked: true)),
            .row(DSMenuRow(id: "opus", title: "Claude Opus 4.1", trailing: "200K   $15 / $75")),
            .row(DSMenuRow(id: "haiku", title: "Claude Haiku 4.5", trailing: "200K   $1 / $5")),
            .header(id: "h-zen", title: "OpenCode Zen", trailing: "Free models"),
            .row(DSMenuRow(id: "pickle", title: "Big Pickle", trailing: "200K", trailingEmphasis: "Free")),
            .row(DSMenuRow(id: "grok", title: "Grok Code Fast 1", trailing: "256K", trailingEmphasis: "Free")),
            .separator(id: "s1"),
            .header(id: "h-off", title: "Not connected"),
            .row(DSMenuRow(id: "openai", title: "OpenAI", link: "Connect…", recedes: true)),
            .row(DSMenuRow(id: "copilot", title: "GitHub Copilot", link: "Connect…", recedes: true)),
        ]
    }

    static func picker() -> NSView {
        let glass = DSGlassView(surface: .popover)
        let content = glass.contentView
        let search = DSTextField(style: .search, placeholder: "Search models")
        search.showsHalo = false
        search.shortcutHint = "⇧⌘M"
        let list = DSMenuListView(entries: modelPickerEntries())
        list.highlight("opus")
        let divider = DSDivider()
        let divider2 = DSDivider()
        let effortLabel = makeLabel("Reasoning", role: .body, color: DS.Color.text2)
        let effort = DSSegmented(items: ["Low", "Medium", "High"].map { DSChoiceItem(id: $0, title: $0) }, selectedID: "High")
        let footer = NSStackView(views: [DSKbd("↑↓"), makeLabel("select", role: .label, color: DS.Color.text3), DSKbd("↩"), makeLabel("choose", role: .label, color: DS.Color.text3),
                                         DSKbd("⌘D"), makeLabel("favourite", role: .label, color: DS.Color.text3)])
        footer.spacing = 6
        let esc = DSKbd("esc")
        let width: CGFloat = 400
        search.frame = NSRect(x: 4, y: 4, width: width - 8, height: 32)
        let listHeight = list.intrinsicContentSize.height
        list.frame = NSRect(x: 0, y: 40, width: width, height: listHeight)
        divider.frame = NSRect(x: 0, y: 40 + listHeight, width: width, height: 1)
        effortLabel.frame = NSRect(x: 12, y: 50 + listHeight, width: 100, height: 18)
        let effortSize = effort.intrinsicContentSize
        effort.frame = NSRect(x: width - 8 - effortSize.width, y: 46 + listHeight, width: effortSize.width, height: effortSize.height)
        divider2.frame = NSRect(x: 0, y: 76 + listHeight, width: width, height: 1)
        footer.frame = NSRect(x: 10, y: 84 + listHeight, width: 300, height: 20)
        esc.frame = NSRect(x: width - 10 - esc.intrinsicContentSize.width, y: 85 + listHeight, width: esc.intrinsicContentSize.width, height: 18)
        for view in [search, list, divider, effortLabel, effort, divider2, footer, esc] as [NSView] { content.addSubview(view) }
        glass.frame = NSRect(x: 0, y: 0, width: width, height: 112 + listHeight)
        let flipped = FlippedContainer()
        flipped.addSubview(glass)
        return flipped
    }

    static func paletteSample() -> NSView {
        let glass = DSGlassView(surface: .popover, radius: DS.Radius.xl)
        let entries: [DSMenuEntry] = [
            .header(id: "threads", title: "Threads"),
            .row(DSMenuRow(id: "t1", title: "Fix flaky parser recovery test", symbolName: "circle.dotted", trailing: "atlas · Working", shortcut: "↩", reservesCheckSlot: false)),
            .row(DSMenuRow(id: "t2", title: "Split parseExpression into rules", trailing: "atlas · Settled 3d", reservesCheckSlot: false, reservesIconSlot: true)),
            .header(id: "actions", title: "Actions"),
            .row(DSMenuRow(id: "a1", title: "New thread in atlas", symbolName: "square.and.pencil", shortcut: "⌘N", reservesCheckSlot: false)),
            .row(DSMenuRow(id: "a2", title: "Toggle terminal", symbolName: "apple.terminal", shortcut: "⌃`", reservesCheckSlot: false)),
            .row(DSMenuRow(id: "a3", title: "Show changes", symbolName: "plusminus", shortcut: "⇧⌘D", reservesCheckSlot: false)),
        ]
        let list = DSMenuListView(entries: entries)
        list.look = .palette
        list.highlight("t1")
        let width: CGFloat = 600
        let input = makeLabel("pars", role: .prose, color: DS.Color.text)
        input.font = .systemFont(ofSize: 15)
        let mag = NSImageView(image: DSDraw.symbol("magnifyingglass", pointSize: 14) ?? NSImage())
        mag.contentTintColor = DS.Color.text3
        let scope = DSPill("All")
        let rule = DSDivider()
        mag.frame = NSRect(x: 16, y: 16, width: 16, height: 16)
        input.frame = NSRect(x: 42, y: 14, width: 300, height: 20)
        scope.frame = NSRect(x: width - 16 - scope.intrinsicContentSize.width, y: 15, width: scope.intrinsicContentSize.width, height: 18)
        rule.frame = NSRect(x: 0, y: 48, width: width, height: 1)
        let h = list.intrinsicContentSize.height
        list.frame = NSRect(x: 4, y: 52, width: width - 8, height: h)
        for view in [mag, input, scope, rule, list] as [NSView] { glass.contentView.addSubview(view) }
        glass.frame = NSRect(x: 0, y: 0, width: width, height: 60 + h)
        let flipped = FlippedContainer()
        flipped.addSubview(glass)
        return flipped
    }

    static func menus() -> Sheet {
        let sheet = Sheet(width: 1290)
        sheet.heading("Menu panel / model picker and palette (glass, solid fallback)")
        sheet.caption("In-process rendering cannot capture NSVisualEffectView, so glass surfaces show their Reduce Transparency fallback (`raised`).")
        let picker = picker()
        let palette = paletteSample()
        sheet.row("", [picker, palette], sizes: [NSSize(width: 420, height: 520), NSSize(width: 620, height: 340)], gap: 24)
        return sheet
    }

    // MARK: Composition (compare with docs/design/mock/main-*.png)

    static func composition() -> Sheet {
        let sheet = Sheet(width: 1080)
        sheet.heading("Composition: approval card attached to the composer")
        let container = FlippedContainer()
        let card = DSCard(style: .tinted(.warning))
        card.frame = NSRect(x: 0, y: 0, width: 860, height: 150)
        let shield = DSStatusGlyphView()
        shield.status = .awaitingApproval
        shield.pointSize = 14
        shield.frame = NSRect(x: 18, y: 18, width: 16, height: 16)
        let question = makeLabel("Run a command?", role: .title, color: DS.Color.text)
        question.frame = NSRect(x: 44, y: 16, width: 140, height: 20)
        let reason = makeLabel("Clears the test cache before rerunning", role: .body, color: DS.Color.text2)
        reason.frame = NSRect(x: 168, y: 16, width: 400, height: 20)
        let time = makeLabel("just now", role: .meta, color: DS.Color.text4)
        time.alignment = .right
        time.frame = NSRect(x: 740, y: 18, width: 100, height: 16)
        let preview = DSCard(style: .inset)
        preview.frame = NSRect(x: 44, y: 44, width: 796, height: 34)
        let command = makeLabel("$  rm -rf .build/test-cache && swift test --parallel", role: .code, color: DS.Color.text)
        command.frame = NSRect(x: 12, y: 8, width: 600, height: 18)
        preview.addSubview(command)
        let risk = makeLabel("Deletes files", role: .label, color: DS.Color.text2)
        risk.frame = NSRect(x: 64, y: 98, width: 200, height: 16)
        let riskGlyph = DSStatusGlyphView()
        riskGlyph.symbolOverride = "exclamationmark.triangle"
        riskGlyph.toneOverride = .warning
        riskGlyph.frame = NSRect(x: 44, y: 99, width: 14, height: 14)
        let allow = DSButton(title: "Allow once", variant: .primary, shortcutHint: "⌥⌘Y")
        let always = DSButton(title: "Always allow", variant: .outline, shortcutHint: "⇧⌥⌘Y")
        let deny = DSButton(title: "Deny", variant: .outline, shortcutHint: "⌥⌘N")
        var x: CGFloat = 840
        for button in [allow, always, deny] {
            let w = button.intrinsicContentSize.width
            x -= w
            button.frame = NSRect(x: x, y: 92, width: w, height: 28)
            x -= 10
        }
        for view in [shield, question, reason, time, preview, risk, riskGlyph, allow, always, deny] as [NSView] { card.addSubview(view) }

        let composer = DSGlassView(surface: .composer)
        composer.frame = NSRect(x: 0, y: 134, width: 860, height: 110)
        let prompt = makeLabel("Then add a regression test for nested fences", role: .composer, color: DS.Color.text)
        prompt.frame = NSRect(x: 18, y: 16, width: 600, height: 21)
        let attach = DSButton(icon: "paperclip", accessibilityTitle: "Attach", size: .small)
        attach.frame = NSRect(x: 10, y: 72, width: 26, height: 26)
        var cx: CGFloat = 42
        for (title, symbol) in [("Build", "hammer"), ("Claude Sonnet 4.5", "sparkle"), ("High", "cpu"), ("Ask", "lock")] {
            let select = DSSelectButton(title: title, symbolName: symbol, chevron: .down, size: .small)
            select.horizontalPadding = 8
            let w = select.intrinsicContentSize.width
            select.frame = NSRect(x: cx, y: 73, width: w, height: 24)
            composer.contentView.addSubview(select)
            cx += w + 4
        }
        let stop = DSButton(title: "Stop", variant: .outline, size: .small, symbolName: "stop.fill")
        let stopW = stop.intrinsicContentSize.width
        stop.frame = NSRect(x: 860 - 12 - 30 - 8 - stopW, y: 73, width: stopW, height: 24)
        let send = SendButtonSample()
        send.frame = NSRect(x: 860 - 12 - 30, y: 70, width: 30, height: 30)
        for view in [prompt, attach, stop, send] as [NSView] { composer.contentView.addSubview(view) }
        container.addSubview(card)
        container.addSubview(composer)
        sheet.row("", [container], sizes: [NSSize(width: 860, height: 250)])

        sheet.heading("Sidebar rows")
        let rows = FlippedContainer()
        var y: CGFloat = 0
        let samples: [(SessionStatus?, String, String, DSRowStyle)] = [
            (.awaitingApproval, "Migrate sessions to passkeys", "1m", .rest),
            (.awaitingAnswer, "Pick a CI cache strategy", "6m", .selected),
            (.running, "Fix flaky parser recovery test", "now", .active),
            (nil, "Release checklist 2.4", "2d", .hover),
            (nil, "Bump swift-markdown to 0.9", "1d", .rest),
        ]
        for (status, title, time, style) in samples {
            let bg = DSRowBackgroundView()
            bg.style = style
            bg.frame = NSRect(x: 8, y: y, width: 248, height: 28)
            rows.addSubview(bg)
            let glyph = DSStatusGlyphView()
            if let status { glyph.status = status }
            glyph.frame = NSRect(x: 18, y: y + 7, width: 14, height: 14)
            rows.addSubview(glyph)
            let label = makeLabel(title, role: .body, color: status == nil && time == "1d" ? DS.Color.text3 : DS.Color.sidebarText)
            label.frame = NSRect(x: 40, y: y + 5, width: 170, height: 18)
            rows.addSubview(label)
            let t = makeLabel(time, role: .meta, color: DS.Color.text4)
            t.alignment = .right
            t.frame = NSRect(x: 210, y: y + 7, width: 36, height: 14)
            rows.addSubview(t)
            y += 30
        }
        let sidebar = SidebarBackground()
        sidebar.addSubview(rows)
        rows.frame = NSRect(x: 0, y: 8, width: 264, height: y)
        sheet.row("", [sidebar], sizes: [NSSize(width: 264, height: y + 16)])
        return sheet
    }
}

@MainActor
final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class SidebarBackground: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        DS.Color.sidebar.setFill()
        bounds.fill()
        DS.Color.border.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}

/// The 30 pt accent Send circle (ComposerKit owns the real one; this shows the recipe).
@MainActor
final class SendButtonSample: NSView {
    override func draw(_ dirtyRect: NSRect) {
        DSDraw.fill(bounds, radius: bounds.width / 2, color: DS.Color.accent)
        if let arrow = DSDraw.symbol("arrow.up", pointSize: 13, weight: .semibold) {
            DSDraw.draw(template: arrow, in: bounds, color: DS.Color.onAccent)
        }
    }
}
