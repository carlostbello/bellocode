import AppKit
import BelloCore
@testable import DesignSystem
import Testing

@MainActor
final class ActionSpy: NSObject {
    var count = 0
    @objc func fire(_ sender: Any?) { count += 1 }
}

@MainActor
func hostWindow(_ view: NSView, size: NSSize = NSSize(width: 300, height: 100)) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    view.frame = NSRect(x: 10, y: 10, width: max(view.intrinsicContentSize.width, 40), height: max(view.intrinsicContentSize.height, 20))
    window.contentView?.addSubview(view)
    return window
}

@MainActor
func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1)!
}

@MainActor
func key(_ characters: String, keyCode: UInt16, in window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
}

@MainActor
@Suite(.serialized) struct ControlTests {
    init() { DSControl.focusPolicy = .always }

    @Test func statePhaseOrdering() {
        #expect(DSControlState().phase == .rest)
        #expect(DSControlState(isHovered: true).phase == .hover)
        #expect(DSControlState(isHovered: true, isPressed: true).phase == .pressed)
        #expect(DSControlState(isEnabled: false, isHovered: true, isPressed: true).phase == .disabled)
    }

    @Test func buttonRecipes() {
        let rest = DSButtonRecipe(variant: .primary, state: DSControlState())
        #expect(rest.fill === DS.Color.accent && rest.text === DS.Color.onAccent && rest.topHighlight && rest.shadow)
        let hover = DSButtonRecipe(variant: .primary, state: DSControlState(isHovered: true))
        #expect(hover.fill === DS.Color.accentHover)
        let pressed = DSButtonRecipe(variant: .primary, state: DSControlState(isHovered: true, isPressed: true))
        #expect(!pressed.topHighlight)
        let outline = DSButtonRecipe(variant: .outline, state: DSControlState())
        #expect(outline.ring === DS.Color.borderStrong && outline.fill === DSButtonColors.outlineFill)
        #expect(DSButtonRecipe(variant: .outline, state: DSControlState(isHovered: true)).fill === DSButtonColors.outlineHover)
        #expect(DSButtonRecipe(variant: .ghost, state: DSControlState()).fill == nil)
        #expect(DSButtonRecipe(variant: .ghost, state: DSControlState(isHovered: true)).fill === DS.Color.fillHover)
        #expect(DSButtonRecipe(variant: .ghost, state: DSControlState(isSelected: true)).fill === DS.Color.fillHover)
        #expect(DSButtonRecipe(variant: .ghost, state: DSControlState(), muted: true).text === DS.Color.text2)
        #expect(DSButtonRecipe(variant: .destructive, state: DSControlState(isHovered: true)).fill === DS.Color.danger)
        // Never the accent as a row or ghost fill.
        for variant in [DSButton.Variant.ghost, .outline] {
            for state in [DSControlState(), DSControlState(isHovered: true), DSControlState(isSelected: true)] {
                #expect(DSButtonRecipe(variant: variant, state: state).fill !== DS.Color.accent)
            }
        }
    }

    @Test func mouseHoverPressAndClick() {
        let spy = ActionSpy()
        let button = DSButton(title: "Deny", target: spy, action: #selector(ActionSpy.fire(_:)))
        let window = hostWindow(button)
        let inside = NSPoint(x: 20, y: 20)
        button.mouseEntered(with: mouse(.mouseMoved, at: inside, in: window))
        #expect(button.controlState.isHovered)
        button.mouseDown(with: mouse(.leftMouseDown, at: inside, in: window))
        #expect(button.controlState.phase == .pressed)
        button.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 280, y: 90), in: window))
        #expect(!button.controlState.isPressed, "dragging out cancels the press")
        button.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 280, y: 90), in: window))
        #expect(spy.count == 0)
        button.mouseDown(with: mouse(.leftMouseDown, at: inside, in: window))
        button.mouseUp(with: mouse(.leftMouseUp, at: inside, in: window))
        #expect(spy.count == 1)
        button.mouseExited(with: mouse(.mouseMoved, at: .zero, in: window))
        #expect(!button.controlState.isHovered)
    }

    @Test func disabledIgnoresInputAndDims() {
        let spy = ActionSpy()
        let button = DSButton(title: "Send", variant: .primary, target: spy, action: #selector(ActionSpy.fire(_:)))
        let window = hostWindow(button)
        button.isEnabled = false
        #expect(button.alphaValue == DSControlState.disabledOpacity)
        #expect(!button.acceptsFirstResponder)
        button.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20), in: window))
        button.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20), in: window))
        #expect(!button.accessibilityPerformPress())
        #expect(spy.count == 0)
        #expect(button.controlState.phase == .disabled)
    }

    @Test func keyboardFocusAndActivation() {
        let spy = ActionSpy()
        let button = DSButton(title: "Allow once", variant: .primary, shortcutHint: "⌥⌘Y", target: spy, action: #selector(ActionSpy.fire(_:)))
        let window = hostWindow(button)
        #expect(window.makeFirstResponder(button))
        #expect(button.controlState.isFocused)
        button.keyDown(with: key(" ", keyCode: 49, in: window))
        button.keyDown(with: key("\r", keyCode: 36, in: window))
        #expect(spy.count == 2)
        window.makeFirstResponder(nil)
        #expect(!button.controlState.isFocused)
    }

    @Test func clicksDoNotStealFocusUnderDefaultPolicy() {
        DSControl.focusPolicy = .fullKeyboardAccess
        defer { DSControl.focusPolicy = .always }
        let button = DSButton(title: "Deny")
        _ = hostWindow(button)
        #expect(button.acceptsFirstResponder == (NSApp.isFullKeyboardAccessEnabled))
    }

    @Test func buttonAccessibility() {
        let button = DSButton(title: "Always allow", shortcutHint: "⇧⌥⌘Y")
        #expect(button.accessibilityRole() == .button)
        #expect(button.accessibilityLabel() == "Always allow")
        #expect(button.accessibilityHelp() == "Shortcut ⇧⌥⌘Y")
        let icon = DSButton(icon: "sidebar.right", accessibilityTitle: "Toggle right panel")
        #expect(icon.isIconOnly)
        #expect(icon.accessibilityLabel() == "Toggle right panel")
        #expect(icon.intrinsicContentSize == NSSize(width: 28, height: 28))
        let toggle = DSButton(icon: "apple.terminal", accessibilityTitle: "Terminal")
        toggle.isToggle = true
        _ = toggle.accessibilityPerformPress()
        #expect(toggle.isSelected)
        #expect(toggle.accessibilityValue() as? Int == 1)
    }

    @Test func shortcutHintDropsBeforeTitleTruncates() {
        let button = DSButton(title: "Always allow", shortcutHint: "⇧⌥⌘Y")
        button.frame = NSRect(x: 0, y: 0, width: button.fullWidth, height: 28)
        #expect(button.showsHint)
        button.frame.size.width = button.fullWidth - 10
        #expect(!button.showsHint)
        #expect(DSButton(title: "Deny", size: .small).intrinsicContentSize.height == 24)
    }

    @Test func togglesAndRadios() {
        let spy = ActionSpy()
        let checkbox = DSToggle(kind: .checkbox, title: "Notify", target: spy, action: #selector(ActionSpy.fire(_:)))
        let window = hostWindow(checkbox)
        #expect(checkbox.accessibilityRole() == .checkBox)
        #expect(window.makeFirstResponder(checkbox))
        checkbox.keyDown(with: key(" ", keyCode: 49, in: window))
        #expect(checkbox.isOn && spy.count == 1)
        #expect(checkbox.accessibilityValue() as? Int == 1)
        checkbox.keyDown(with: key(" ", keyCode: 49, in: window))
        #expect(!checkbox.isOn)
        let radio = DSToggle(kind: .radio, title: "Option A")
        _ = radio.accessibilityPerformPress()
        _ = radio.accessibilityPerformPress()
        #expect(radio.isOn, "a radio does not toggle off")
        #expect(radio.accessibilityRole() == .radioButton)
        let toggleSwitch = DSToggle(kind: .switch, title: "Agent control")
        #expect(toggleSwitch.accessibilityRole() == .checkBox)
        #expect(toggleSwitch.accessibilitySubrole() == .switch)
    }

    @Test func tabBarSelectionKeyboardAndAccessibility() {
        let tabs = DSTabBar(items: [
            DSChoiceItem(id: "changes", title: "Changes", symbolName: "plusminus", count: 3),
            DSChoiceItem(id: "files", title: "Files"),
            DSChoiceItem(id: "agents", title: "Agents", count: 2),
        ])
        var picked: [String] = []
        tabs.onSelect = { picked.append($0) }
        let window = hostWindow(tabs, size: NSSize(width: 500, height: 100))
        tabs.layoutSubtreeIfNeeded()
        #expect(tabs.selectedID == "changes")
        #expect(tabs.accessibilityRole() == .tabGroup)
        let first = tabs.choiceButtons[0]
        #expect(first.accessibilityRole() == .radioButton)
        #expect(first.accessibilityLabel() == "Changes, 3")
        #expect(first.accessibilityValue() as? Int == 1)
        #expect(window.makeFirstResponder(first))
        first.keyDown(with: key(String(UnicodeScalar(NSRightArrowFunctionKey)!), keyCode: 124, in: window))
        #expect(tabs.selectedID == "files" && picked == ["files"])
        #expect(window.firstResponder === tabs.choiceButtons[1])
        tabs.choiceButtons[1].keyDown(with: key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), keyCode: 123, in: window))
        tabs.choiceButtons[0].keyDown(with: key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), keyCode: 123, in: window))
        #expect(tabs.selectedID == "agents", "wraps")
        tabs.selectedID = "files"
        #expect(picked.count == 3, "setting selection in code does not report")
        #expect(tabs.choiceButtons[1].isSelected && !tabs.choiceButtons[2].isSelected)
    }

    @Test func menuListKeyboardSkipsHeadersAndDisabled() {
        let list = DSMenuListView(entries: [
            .header(id: "h", title: "Anthropic", trailing: "Connected"),
            .row(DSMenuRow(id: "a", title: "Sonnet", isChecked: true)),
            .row(DSMenuRow(id: "b", title: "Opus", isEnabled: false)),
            .separator(id: "s"),
            .row(DSMenuRow(id: "c", title: "Haiku")),
        ])
        var chosen: [String] = []
        list.onChoose = { chosen.append($0) }
        #expect(list.moveHighlight(by: 1) == "a")
        #expect(list.moveHighlight(by: 1) == "c")
        #expect(list.moveHighlight(by: 1) == "a")
        #expect(list.moveHighlight(by: -1) == "c")
        list.chooseHighlighted()
        #expect(chosen == ["c"])
        #expect(list.accessibilityRole() == .menu)
        let rows = list.subviews.compactMap { $0 as? DSMenuRowView }
        #expect(rows.count == 3)
        #expect(rows[0].accessibilityRole() == .menuItem && rows[0].accessibilityValue() as? String == "selected")
        #expect(rows[1].isAccessibilityEnabled() == false)
    }

    @Test func selectButtonIsAPopUp() {
        let select = DSSelectButton(title: "This turn")
        var opened = 0
        select.onOpen = { _ in opened += 1 }
        #expect(select.accessibilityRole() == .popUpButton)
        #expect(select.accessibilityValue() as? String == "This turn")
        _ = select.accessibilityPerformPress()
        #expect(opened == 1 && select.isOpen)
        select.isOpen = false
        select.title = "All turns"
        #expect(select.accessibilityValue() as? String == "All turns")
        #expect(select.accessibilityRole() == .popUpButton)
    }

    @Test func rowStyles() {
        #expect(DSRowStyle.resolve(hovered: true, selected: false, active: false) == .hover)
        #expect(DSRowStyle.resolve(hovered: true, selected: true, active: false) == .selected)
        #expect(DSRowStyle.resolve(hovered: true, selected: true, active: true) == .active)
        #expect(DSRowStyle.active.fill === DS.Color.rowActive)
        #expect(DSRowStyle.rest.fill == nil)
        for style in [DSRowStyle.hover, .selected, .active] { #expect(style.fill !== DS.Color.accent) }
    }

    @Test func statusGlyphViewAccessibilityAndClock() {
        let glyph = DSStatusGlyphView()
        glyph.status = .awaitingApproval
        #expect(glyph.accessibilityLabel() == "Needs approval")
        #expect(glyph.accessibilityRole() == .image)
        let window = hostWindow(glyph)
        DS.Accessibility.reduceMotionOverride = false
        defer { DS.Accessibility.reduceMotionOverride = nil }
        let before = DSStepClock.shared.subscriberCount
        glyph.status = .running
        #expect(DSStepClock.shared.subscriberCount == before + 1, "a running glyph on screen subscribes")
        glyph.removeFromSuperview()
        #expect(DSStepClock.shared.subscriberCount == before, "and pauses off-screen")
        window.close()
    }

    @Test func countBadgeAndPill() {
        let badge = CountBadge()
        badge.noun = "threads need you"
        badge.count = 2
        #expect(!badge.isHidden && badge.accessibilityLabel() == "2 threads need you")
        badge.isProminent = true
        #expect(badge.intrinsicContentSize.height == DS.Size.pill)
        badge.count = 0
        #expect(badge.isHidden)
        let pill = DSPill("1 failed", tone: .danger)
        #expect(pill.intrinsicContentSize.height == 18)
        #expect(pill.accessibilityRole() == .staticText)
    }

    @Test func glassFallsBackToSolid() {
        DSGlassView.forcesSolidFallback = true
        defer { DSGlassView.forcesSolidFallback = false }
        let glass = DSGlassView(surface: .popover)
        #expect(glass.isSolid)
        #expect(glass.radius == DS.Radius.lg)
        #expect(DSGlassView(surface: .composer).radius == DS.Radius.xl)
        DS.Accessibility.reduceTransparencyOverride = true
        DSGlassView.forcesSolidFallback = false
        defer { DS.Accessibility.reduceTransparencyOverride = nil }
        #expect(DSGlassView(surface: .popover).isSolid)
    }

    @Test func textFieldFocusLook() {
        let field = DSTextField(style: .search, placeholder: "Search")
        field.shortcutHint = "⌘K"
        let window = hostWindow(field, size: NSSize(width: 400, height: 100))
        field.frame = NSRect(x: 10, y: 10, width: 300, height: 34)
        #expect(!field.isFocused)
        #expect(window.makeFirstResponder(field.field))
        #expect(field.isFocused)
        #expect(field.field.isBezeled == false && field.field.drawsBackground == false)
    }
}
