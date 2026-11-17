import AppKit
import DesignSystem

extension TranscriptController {
    func configureViews() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
        tableView.usesAutomaticRowHeights = false
        tableView.rowSizeStyle = .custom
        tableView.allowsColumnResizing = false
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.backgroundColor = .clear
        tableView.controller = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("Transcript")
        tableView.setAccessibilityRole(.list)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        DSScroller.install(on: scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.automaticallyAdjustsContentInsets = false

        jumpPill.onJump = { [weak self] in self?.jumpToLatest() }
        findBar.onChange = { [weak self] query in self?.setFindQuery(query) }
        findBar.onNext = { [weak self] in self?.findNext() }
        findBar.onPrevious = { [weak self] in self?.findPrevious() }
        findBar.onClose = { [weak self] in self?.closeFind() }

        emptyLabel.stringValue = "No messages yet. Send a prompt to start."
        emptyLabel.textColor = DS.Color.text3
        emptyLabel.font = DS.TextRole.body.font
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        container.wantsLayer = true
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        container.addSubview(jumpPill)
        container.addSubview(findBar)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            jumpPill.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            jumpPill.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            findBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            findBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -48),
        ])
        container.onAppearanceChange = { [weak self] in self?.appearanceChanged() }

        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.boundsChanged() }
            })
        observers.append(
            center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.clipFrameChanged() }
            })
        observers.append(
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.liveScrolling = true }
            })
        observers.append(
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.liveScrolling = false
                    self?.evaluateFollow()
                }
            })
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.appearanceChanged() }
            })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                    let window = notification.object as? NSWindow
                    let identifier = window.map(ObjectIdentifier.init)
                    MainActor.assumeIsolated {
                        guard let self, let identifier, self.tableView.window.map(ObjectIdentifier.init) == identifier else { return }
                        self.refreshVisibleRows()
                    }
                })
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.noteWheel(event) }
            return event
        }
    }
}
