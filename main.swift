import AppKit
import WebKit
import Carbon

/// 테스트 훅(docs/CONNECT.md §7). 평소엔 모두 꺼져 있다.
enum TestMode {
    static let env = ProcessInfo.processInfo.environment
    /// SYNAPSE_TEST_* 가 하나라도 있으면 단축키·메뉴 막대 아이콘·사용자 설정 저장을 하지 않는다.
    static let active = env.keys.contains { $0.hasPrefix("SYNAPSE_TEST_") }
    static let offscreen = env["SYNAPSE_TEST_OFFSCREEN"] == "1"
    static let exitAfter = env["SYNAPSE_TEST_EXIT"] == "1"
    static let scriptPath = env["SYNAPSE_TEST_SCRIPT"]
    static let snapshotPath = env["SYNAPSE_TEST_SNAPSHOT"]
    /// MCP 로그인 시험: 실제 브라우저 대신 인가 주소를 직접 요청한다(모의 서버가 바로 리디렉트).
    static let fakeBrowser = env["SYNAPSE_TEST_FAKE_BROWSER"] == "1"
    /// 시나리오 시간 한도(초). 기본 60초 — 긴 사용성 시나리오(dev/ui-test)는 SYNAPSE_TEST_TIMEOUT으로 늘린다.
    static let scriptTimeout = Double(env["SYNAPSE_TEST_TIMEOUT"] ?? "").flatMap { $0 > 0 ? $0 : nil } ?? 60
    /// 시험 실행에서는 다른 앱·Finder·브라우저를 열지 않고 무엇을 열려 했는지만 남긴다(사용자 화면을 건드리지 않게).
    static func intercept(_ what: String, _ target: String) -> Bool {
        guard active else { return false }
        print("TEST_OPEN \(what) \(target)")
        fflush(stdout)
        return true
    }
}

/// 메뉴 막대 아이콘 위의 작은 점. 클릭은 아래 버튼으로 흘려보낸다.
final class StatusDot: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    // 화면 밖 시험 모드에서는 시스템이 창을 화면 안으로 끌어오지 못하게 한다.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        TestMode.offscreen ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

// activate(ignoringOtherApps:)는 14에서 deprecated지만 단축키(Carbon)로 부를 때 가장 확실해 셀렉터로 호출한다.
private func forceActivate() {
    let selector = NSSelectorFromString("activateIgnoringOtherApps:")
    guard let method = class_getInstanceMethod(NSApplication.self, selector) else { NSApp.activate(); return }
    typealias Activate = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(method_getImplementation(method), to: Activate.self)(NSApp, selector, true)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    private static let frameKey = "synapse.windowFrame"
    private static let pinnedKey = "synapse.pinned"
    private static let autoHideKey = "synapse.autoHide"
    private static let showDoneKey = "synapse.showDone"
    private static let defaultSize = NSSize(width: 1180, height: 760)
    private static let minimumSize = NSSize(width: 860, height: 560)

    private var panel: SearchPanel!
    private var webView: WKWebView!
    private var statusItem: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var previousApplication: NSRunningApplication?
    private var shortcutText = "⌃⌥Space"
    private var registeredModifiers: UInt32 = UInt32(controlKey | optionKey)
    private var documentReady = false
    private var documentURL: URL?
    private var isHiding = false
    private var transitionToken = 0
    private var pinned = TestMode.active ? false : UserDefaults.standard.bool(forKey: AppDelegate.pinnedKey)
    // v0.4: 기본은 "그대로 두기". 켜면 다른 앱으로 전환할 때 창을 숨긴다(v0.3 동작).
    private var autoHide = TestMode.active ? false : UserDefaults.standard.bool(forKey: AppDelegate.autoHideKey)
    // v0.6: 끝난 티켓을 지도에 보일지 (기본 숨김). 시험 실행에서는 저장하지 않는다.
    private var showDone = TestMode.active ? false : UserDefaults.standard.bool(forKey: AppDelegate.showDoneKey)
    var testRunScheduled = false
    private var library: Library!
    // v0.5 사서(Brain). 열지 못하면 nil — 그때 앱은 사서 없이 동작하고 브리지는 오류를 돌려준다.
    private var brain: BrainAPI?
    // v0.8 Claude 연결(docs/V08.md §4). 사서가 없어도 만든다(aiStatus는 늘 답한다).
    private var ai: AIService?
    private var statusDot: NSView?
    private var pendingWaiting = false
    private var brainStopped = false
    private var brainStateRefreshing = false
    private var brainStateDirty = false
    private let engineQueue = DispatchQueue(label: "synapse.engine", qos: .userInitiated, attributes: .concurrent)
    private var lastErrorRetry = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(ProcessInfo.processInfo.environment["SYNAPSE_REGULAR_APP"] == "1" ? .regular : .accessory)
        createMenus()
        if !TestMode.active { createStatusItem() }
        startLibrary()
        createPanel()
        installNavMonitor()
        if !TestMode.active { registerShortcut() }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationResigned),
                                               name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationBecameActive),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceActivated(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if TestMode.offscreen { showOffscreen() } else { showPanel() }
    }

    @objc private func workspaceActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        previousApplication = app
    }

    // MARK: Menus

    private func createMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Synapse 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(title: "편집", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "다시 실행", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)

        let windowItem = NSMenuItem(title: "창", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "창")
        let close = NSMenuItem(title: "창 닫기", action: #selector(hideByUser), keyEquivalent: "w")
        close.target = self
        windowMenu.addItem(close)
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "Synapse") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "◌"
        }
        statusItem.button?.toolTip = "Synapse · 클릭해서 열기, 우클릭으로 메뉴"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        if let button = statusItem.button {
            // 정리 대기 표시: 아이콘 오른쪽 위의 작은 점 하나(숫자 없음). 아이콘은 템플릿 그대로 두고 점만 겹친다.
            let dot = StatusDot()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            dot.layer?.cornerRadius = 3
            dot.isHidden = true
            button.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6),
                dot.topAnchor.constraint(equalTo: button.topAnchor, constant: 5),
                dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -5),
            ])
            statusDot = dot
        }
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false) {
            guard let button = statusItem.button else { return }
            makeStatusMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        } else {
            togglePanel()
        }
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let show = NSMenuItem(title: "Synapse 열기    \(shortcutText)", action: #selector(showFromMenu), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let pin = NSMenuItem(title: "창 고정", action: #selector(togglePinned), keyEquivalent: "")
        pin.target = self
        pin.state = pinned ? .on : .off
        menu.addItem(pin)
        let hide = NSMenuItem(title: "다른 앱으로 전환하면 창 숨기기", action: #selector(toggleAutoHide), keyEquivalent: "")
        hide.target = self
        hide.state = autoHide ? .on : .off
        menu.addItem(hide)
        let reset = NSMenuItem(title: "창 크기·위치 초기화", action: #selector(resetFromMenu), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        if brain != nil {
            menu.addItem(.separator())
            let librarian = NSMenuItem(title: brainStopped ? "사서 다시 시작" : "사서 멈추기", action: #selector(toggleBrainStopped), keyEquivalent: "")
            librarian.target = self
            menu.addItem(librarian)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Synapse 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func showFromMenu() { showPanel() }
    @objc private func resetFromMenu() { resetFrame(); showPanel() }

    @objc private func togglePinned() {
        setPinned(!pinned)
        run("window.synapseSetPinned?.(\(pinned))")
    }

    func setAutoHide(_ value: Bool) {
        autoHide = value
        if !TestMode.active { UserDefaults.standard.set(value, forKey: AppDelegate.autoHideKey) }
    }

    var autoHideEnabled: Bool { autoHide }

    @objc private func toggleAutoHide() { setAutoHide(!autoHide) }

    private func setPinned(_ value: Bool) {
        pinned = value
        panel?.level = value ? .floating : .normal
        if !TestMode.active { UserDefaults.standard.set(value, forKey: AppDelegate.pinnedKey) }
    }

    // MARK: Panel

    private func createPanel() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "synapse")
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "synapseAPI")
        let bootstrap = "document.documentElement.classList.add('is-native'); window.__SYNAPSE_NATIVE__ = {pinned: \(pinned), autoHide: \(autoHide), showDone: \(showDone)};"
        configuration.userContentController.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        webView.frame = effect.bounds
        webView.autoresizingMask = [.width, .height]
        effect.addSubview(webView)

        panel = SearchPanel(contentRect: NSRect(origin: .zero, size: AppDelegate.defaultSize),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "Synapse"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = pinned ? .floating : .normal
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = AppDelegate.minimumSize
        panel.delegate = self
        panel.contentView = effect

        guard let html = Bundle.main.url(forResource: "Graph", withExtension: "html") else {
            let alert = NSAlert()
            alert.messageText = "화면 파일을 찾을 수 없습니다."
            alert.informativeText = "Synapse.app 전체를 함께 이동한 뒤 다시 실행해 주세요."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        documentURL = html.standardizedFileURL
        webView.loadFileURL(html, allowingReadAccessTo: html)
    }

    private func screenUnderMouse() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main
    }

    private func savedFrame() -> NSRect? {
        guard let text = UserDefaults.standard.string(forKey: AppDelegate.frameKey) else { return nil }
        let rect = NSRectFromString(text)
        return rect.width >= 200 && rect.height >= 200 ? rect : nil
    }

    private func clamp(_ frame: NSRect, to visible: NSRect) -> NSRect {
        let width = min(frame.width, visible.width), height = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func centered(_ size: NSSize, on visible: NSRect) -> NSRect {
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height * 0.04)
        return clamp(NSRect(origin: origin, size: size), to: visible)
    }

    private func defaultSize(on visible: NSRect) -> NSSize {
        NSSize(width: min(AppDelegate.defaultSize.width, visible.width - 80), height: min(AppDelegate.defaultSize.height, visible.height - 80))
    }

    private func frameForShowing(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        if let saved = savedFrame() {
            if screen.frame.contains(NSPoint(x: saved.midX, y: saved.midY)) { return clamp(saved, to: visible) }
            return centered(saved.size, on: visible)
        }
        return centered(defaultSize(on: visible), on: visible)
    }

    private func applyMinimumSize(for visible: NSRect) {
        panel.minSize = NSSize(width: min(AppDelegate.minimumSize.width, visible.width), height: min(AppDelegate.minimumSize.height, visible.height))
    }

    private func resetFrame() {
        guard let screen = (panel.isVisible ? panel.screen : nil) ?? screenUnderMouse() else { return }
        let visible = screen.visibleFrame
        applyMinimumSize(for: visible)
        let frame = centered(defaultSize(on: visible), on: visible)
        panel.setFrame(frame, display: true, animate: panel.isVisible)
        if !TestMode.active { UserDefaults.standard.set(NSStringFromRect(frame), forKey: AppDelegate.frameKey) }
    }

    private func saveFrame() {
        guard panel.isVisible, !isHiding, !TestMode.active else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: AppDelegate.frameKey)
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

    @objc private func togglePanel() {
        if panel.isVisible && !isHiding && NSApp.isActive && panel.isKeyWindow { hidePanel(restore: true) }
        else { showPanel() }
    }

    @objc private func hideByUser() { hidePanel(restore: true) }

    private func showPanel() {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = front
        }
        transitionToken += 1
        isHiding = false
        if !panel.isVisible {
            if let screen = screenUnderMouse() {
                applyMinimumSize(for: screen.visibleFrame)
                panel.setFrame(frameForShowing(on: screen), display: true)
            }
            panel.alphaValue = 0
        }
        forceActivate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(webView)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        saveFrame()
        run("window.synapseVisibility?.(true); window.synapseFocus?.()")
        print("PANEL_SHOWN")
        fflush(stdout)
    }

    private func hidePanel(restore: Bool, auto: Bool = false) {
        guard panel.isVisible, !isHiding else { return }
        let target = restore && NSApp.isActive ? previousApplication : nil
        isHiding = true
        transitionToken += 1
        let token = transitionToken
        run("window.synapseVisibility?.(false)")
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, self.isHiding, self.transitionToken == token else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.isHiding = false
            target?.activate(options: [])
            if auto { print("AUTO_HIDDEN") }
            print("PANEL_HIDDEN")
            fflush(stdout)
        })
    }

    @objc private func applicationResigned() {
        if panel.isVisible && autoHide && !pinned && !TestMode.offscreen { hidePanel(restore: false, auto: true) }
    }

    /// 읽지 못해 오류 상태인 폴더 출처(예: 앱을 다시 빌드한 뒤 데스크탑 접근이 막힘)는 앱이 다시 활성화될 때
    /// 한 번 더 읽어 본다. 사용자가 시스템 설정에서 허용하고 돌아오면 바로 색인된다. 30초에 한 번까지.
    @objc private func applicationBecameActive() {
        guard library != nil, Date().timeIntervalSince(lastErrorRetry) > 30 else { return }
        lastErrorRetry = Date()
        let library: Library = self.library
        engineQueue.async {
            let sources = library.statusJSON()["sources"] as? [[String: Any]] ?? []
            for source in sources where (source["state"] as? String) == "error" {
                guard let kind = source["kind"] as? String, kind == "folder" || kind == "obsidian",
                      let id = source["id"] as? String else { continue }
                library.reindex(id: id)
            }
        }
    }

    // v0.6 N: 마우스 옆 버튼(뒤로·앞으로)과 트랙패드 스와이프를 화면의 뒤로/앞으로로 바꾼다. 우리 창 안의 이벤트만 소비한다.
    private var navMonitor: Any?
    private func installNavMonitor() {
        guard navMonitor == nil else { return }
        navMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseUp, .swipe]) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel, panel.isVisible else { return event }
            switch event.type {
            case .otherMouseUp:
                // 버튼 번호: 3 = 뒤로, 4 = 앞으로 (대부분의 마우스 옆 버튼)
                guard event.buttonNumber == 3 || event.buttonNumber == 4 else { return event }
                self.run("window.synapseNav?.('\(event.buttonNumber == 3 ? "back" : "forward")')")
                return nil
            case .swipe:
                // deltaX > 0 이면 뒤로, < 0 이면 앞으로 (AppKit의 swipe 관례. Chromium·Safari도 같은 부호로 처리하는 것으로 알고 있으나 이 환경에서는 실제 트랙패드로 확인하지 못했다)
                guard event.deltaX != 0 else { return event }
                self.run("window.synapseNav?.('\(event.deltaX > 0 ? "back" : "forward")')")
                return nil
            default:
                return event
            }
        }
    }

    private func run(_ script: String) {
        guard documentReady else { return }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func pushState() {
        let data = (try? JSONEncoder().encode(shortcutText)) ?? Data("\"\"".utf8)
        let text = String(data: data, encoding: .utf8) ?? "\"\""
        run("window.synapseHotkeyStatus?.(\(text)); window.synapseSetPinned?.(\(pinned)); window.synapseVisibility?.(\(panel.isVisible && !isHiding))")
        if panel.isVisible && !isHiding { run("window.synapseFocus?.()") }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hidePanel(restore: true)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        ai?.shutdown()          // v0.8: 돌고 있는 Claude 프로세스를 끝낸다(SIGTERM → SIGKILL)
        brain?.stop()
        library?.stop()
        if let hotKey = hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler = eventHandler { RemoveEventHandler(eventHandler) }
    }

    // MARK: Hotkey

    private func registerShortcut() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context = context, let event = event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x53594E50, identifier.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            let owner = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            owner.togglePanel()
            return noErr
        }, 1, &type, pointer, &eventHandler)

        guard handlerStatus == noErr else {
            shortcutText = "메뉴 막대에서 열기"
            print("HOTKEY_HANDLER_FAILED \(handlerStatus)")
            fflush(stdout)
            return
        }
        let identifier = EventHotKeyID(signature: 0x53594E50, id: 1)
        var result = RegisterEventHotKey(UInt32(kVK_Space), registeredModifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr {
            registeredModifiers = UInt32(controlKey | optionKey | cmdKey)
            result = RegisterEventHotKey(UInt32(kVK_Space), registeredModifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
            shortcutText = result == noErr ? "⌃⌥⌘Space" : "메뉴 막대에서 열기"
        }
        print("HOTKEY \(result == noErr ? "REGISTERED" : "UNAVAILABLE") \(shortcutText)")
        fflush(stdout)
    }

    // MARK: Web bridge

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "hide":
            hidePanel(restore: true)
        case "startDrag":
            if let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseDragged {
                panel.performDrag(with: event)
            }
        case "resetWindowFrame":
            resetFrame()
        case "setPinned":
            if let value = body["value"] as? Bool { setPinned(value) }
        case "ready":
            pushState()
            print("BRIDGE_READY")
            fflush(stdout)
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        documentReady = true
        pushState()
        print("UI_READY")
        fflush(stdout)
        scheduleTestRun()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        documentReady = false
        guard let url = documentURL else { return }
        webView.loadFileURL(url, allowingReadAccessTo: url)
        print("WEB_PROCESS_RELOAD")
        fflush(stdout)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.isFileURL,
              url.standardizedFileURL == documentURL else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
}

// MARK: - synapseAPI bridge (docs/CONNECT.md §4)

struct BridgeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func koreanMessage(_ error: Error) -> String {
    if let bridge = error as? BridgeError { return bridge.message }
    let text = (error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription
    return text.isEmpty ? "알 수 없는 오류가 났어요." : text
}

/// WKWebView 응답 핸들러는 한 번만 부를 수 있고 스레드를 가리지 않는다. 메인 큐에서 한 번만 부르도록 감싼다.
private final class Reply: @unchecked Sendable {
    private let handler: (Any?, String?) -> Void
    private var done = false
    init(_ handler: @escaping (Any?, String?) -> Void) { self.handler = handler }
    func value(_ value: Any) {
        DispatchQueue.main.async { [self] in
            guard !done else { return }
            done = true
            if JSONSerialization.isValidJSONObject(value) { handler(value, nil) }
            else { handler(nil, "응답을 만들지 못했어요.") }
        }
    }
    func fail(_ message: String) {
        DispatchQueue.main.async { [self] in
            guard !done else { return }
            done = true
            handler(nil, message)
        }
    }
}

/// 사이트 선택 왕복 동안 로그인 결과(자격 증명)를 메모리에만 잠시(10분) 들고 있는다. 디스크에는 쓰지 않는다.
private enum PendingMCPAuth {
    private static let lock = NSLock()
    private static var items: [String: (secret: String, at: Date)] = [:]
    static func put(_ key: String, _ secret: String) { lock.lock(); items[key] = (secret, Date()); lock.unlock() }
    static func take(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let item = items.removeValue(forKey: key), Date().timeIntervalSince(item.at) < 600 else { return nil }
        return item.secret
    }
}

/// 진행 중인 MCP 로그인 작업. 화면의 취소(cancelMCP)가 이 작업을 멈춘다(MCPAuthError.cancelled로 끝난다).
private enum MCPLogin {
    private static let lock = NSLock()
    private static var current: Task<Void, Never>?
    static func begin(_ task: Task<Void, Never>) { lock.lock(); current?.cancel(); current = task; lock.unlock() }
    static func cancel() { lock.lock(); current?.cancel(); current = nil; lock.unlock() }
}

extension AppDelegate {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let reply = Reply(replyHandler)
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let method = body["method"] as? String else {
            return reply.fail("잘못된 요청이에요.")
        }
        let params = body["params"] as? [String: Any] ?? [:]
        let library: Library = self.library
        switch method {
        case "status":
            engineQueue.async { reply.value(library.statusJSON()) }
        case "view":
            engineQueue.async { reply.value(library.viewJSON(params)) }
        case "document":
            guard let id = params["id"] as? String else { return reply.fail("문서 번호가 없어요.") }
            engineQueue.async {
                // 리더는 기본 선택 미리보기처럼 자동으로도 문서를 부르므로 여기서는 "봤음"을 기록하지 않는다.
                // 사용자가 일부러 연 경우만 화면이 track('view')로 알린다(docs/V05.md §4.5).
                if let doc = library.documentJSON(id: id) { reply.value(doc) } else { reply.fail("문서를 찾을 수 없어요.") }
            }
        case "open":
            guard let id = params["id"] as? String else { return reply.fail("문서 번호가 없어요.") }
            let reveal = (params["target"] as? String) == "reveal"
            let obsidian = (params["target"] as? String) == "obsidian"     // v0.6: 옵시디언은 이렇게 부른 때만
            engineQueue.async { [weak self] in
                guard let target = library.openTarget(id: id) else { return reply.fail("문서를 찾을 수 없어요.") }
                DispatchQueue.main.async {
                    do { try self?.openOriginal(target, reveal: reveal, obsidian: obsidian); reply.value(["ok": true]); self?.autoTrack("open", id) }
                    catch { reply.fail(koreanMessage(error)) }
                }
            }
        case "revealPath":
            // v0.9: 작업 지도·정리 계획의 폴더를 Finder에서 보기. 켜진 로컬 출처·그 볼트·~/IdeaProjects 안만 연다.
            guard let raw = params["path"] as? String, raw.hasPrefix("/") else { return reply.fail("경로가 없어요.") }
            // 실제 경로(심볼릭 링크·/private 해석). 링크를 따라 밖으로 나가는 경로는 아래 루트 검사에서 걸린다
            guard let real = realpath(raw, nil) else { return reply.fail("폴더를 찾을 수 없어요. 옮겨졌을 수 있어요.") }
            let path = Indexer.nfc(String(cString: real))
            free(real)
            let locals = library.sourceConfigs().filter { $0.enabled && ($0.kind == .folder || $0.kind == .obsidian) }
            var roots = locals.compactMap { $0.path.map { Indexer.nfc(Indexer.realPath($0)) } } + VaultMap.detect(sources: locals).roots
            roots.append(Indexer.nfc(Indexer.realPath(NSHomeDirectory() + "/IdeaProjects")))
            guard roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return reply.fail("연결한 폴더 밖이라 열 수 없어요.") }
            guard FileManager.default.fileExists(atPath: path) else { return reply.fail("폴더를 찾을 수 없어요. 옮겨졌을 수 있어요.") }
            if TestMode.intercept("reveal", path) { return reply.value(["ok": true]) }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            reply.value(["ok": true])
        case "addSource":
            addSource(kind: (params["kind"] as? String) ?? "folder", reply: reply)
        case "addAtlassian":
            addAtlassian(params, reply: reply)
        case "removeSource":
            guard let id = params["id"] as? String else { return reply.fail("출처 번호가 없어요.") }
            engineQueue.async { library.removeSource(id: id); reply.value(["ok": true]) }
        case "setSourceEnabled":
            guard let id = params["id"] as? String, let enabled = params["enabled"] as? Bool else { return reply.fail("요청 값이 부족해요.") }
            engineQueue.async { library.setSourceEnabled(id: id, enabled: enabled); reply.value(["ok": true]) }
        case "reindex":
            let id = params["id"] as? String
            engineQueue.async { library.reindex(id: id); reply.value(["ok": true]) }
        case "getPreferences":
            reply.value(["autoHide": autoHide, "showDone": showDone])
        case "setPreference":
            guard let key = params["key"] as? String, key == "autoHide" || key == "showDone", let value = params["value"] as? Bool else {
                return reply.fail("알 수 없는 설정이에요.")
            }
            if key == "showDone" {
                showDone = value
                if !TestMode.active { UserDefaults.standard.set(value, forKey: AppDelegate.showDoneKey) }
            } else { setAutoHide(value) }
            reply.value(["ok": true, "autoHide": autoHide, "showDone": showDone])
        case "sourceDetails":
            guard let id = params["id"] as? String else { return reply.fail("출처 번호가 없어요.") }
            engineQueue.async { reply.value(library.sourceDetailsJSON(id: id)) }
        case "updateSource":
            guard let id = params["id"] as? String else { return reply.fail("출처 번호가 없어요.") }
            let kinds = (params["includeKinds"] as? [String])
            let folders = (params["excludeFolders"] as? [String])
            engineQueue.async {
                do { reply.value(["ok": true, "source": try library.updateSource(id: id, includeKinds: kinds, excludeFolders: folders)]) }
                catch { reply.fail(koreanMessage(error)) }
            }
        case "readRaw":
            guard let id = params["id"] as? String else { return reply.fail("문서 번호가 없어요.") }
            engineQueue.async {
                do { reply.value(try library.readRawJSON(id: id)) } catch { reply.fail(koreanMessage(error)) }
            }
        case "saveRaw":
            guard let id = params["id"] as? String, let text = params["text"] as? String,
                  let fingerprint = params["fingerprint"] as? String else { return reply.fail("저장할 내용이 부족해요.") }
            engineQueue.async {
                do {
                    let saved = try library.saveRaw(id: id, text: text, fingerprint: fingerprint)
                    reply.value(saved)
                    if (saved["ok"] as? Bool) == true { self.autoTrack("save", id) }   // 충돌(ok:false)은 저장이 아니다
                } catch { reply.fail(koreanMessage(error)) }
            }
        case "mcpStatus":
            engineQueue.async { reply.value(MCPRegistration.status()) }
        case "mcpRegister":
            guard let client = params["client"] as? String else { return reply.fail("클라이언트를 정해 주세요.") }
            engineQueue.async { reply.value(MCPRegistration.register(client: client)) }
        case "addMCP":
            addMCP(params, reply: reply)
        case "cancelMCP":
            MCPLogin.cancel()
            reply.value(["ok": true])
        case "openHelp":
            guard (params["topic"] as? String) == "atlassian-token",
                  let url = URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens") else {
                return reply.fail("알 수 없는 도움말이에요.")
            }
            if !TestMode.intercept("url", url.absoluteString) { NSWorkspace.shared.open(url) }
            reply.value(["ok": true])
        // v0.6 obsidian: 옵시디언 없이 쓰기 — 그림 읽기 · 새 노트 · 제목 제안 · 바깥 주소 열기
        case "readAsset":
            guard let id = params["id"] as? String, let target = params["target"] as? String else { return reply.fail("그림 정보가 부족해요.") }
            engineQueue.async { reply.value(library.readAsset(id: id, target: target)) }
        case "createNote":
            let title = (params["title"] as? String) ?? ""
            let folder = params["folder"] as? String, text = params["text"] as? String, sid = params["source"] as? String
            engineQueue.async {
                do { reply.value(try library.createNote(sourceId: sid, folder: folder, title: title, text: text)) }
                catch { reply.value(["ok": false, "error": koreanMessage(error)]) }
            }
        case "suggestTitles":
            let q = (params["q"] as? String) ?? ""
            let limit = (params["limit"] as? NSNumber)?.intValue ?? 12
            engineQueue.async { reply.value(library.suggestTitles(q: q, limit: limit)) }
        case "openURL":
            guard let url = NotesURL.allowed((params["url"] as? String) ?? "") else { return reply.value(["ok": false, "error": "열 수 없는 주소예요. http·https·mailto만 열어요."]) }
            DispatchQueue.main.async {
                if !TestMode.intercept("url", url.absoluteString) { NSWorkspace.shared.open(url) }
                reply.value(["ok": true])
            }
        // v0.6 T: 휴지통 · 직접 옮기기 (COMMON §3 C3). 사서 큐에서 처리하고, 바뀌면 사서 이벤트(pending·log·home)와 파일 감시(changed)가 화면을 다시 그린다.
        case "trashInfo", "trashDocs", "listTrash", "restoreTrash", "purgeTrash", "moveDocs":
            handleTrashMethod(method, params, reply: reply)
        case "testSnapshot" where TestMode.active:
            // 시험 전용(dev/ui-test): 시나리오 중간 화면을 PNG로 남긴다
            guard let path = params["path"] as? String, !path.isEmpty else { return reply.fail("저장할 경로가 없어요.") }
            webView.takeSnapshot(with: nil) { image, error in
                guard let image = image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    return reply.fail(error?.localizedDescription ?? "스냅샷을 만들지 못했어요.")
                }
                do {
                    try png.write(to: URL(fileURLWithPath: path))
                    reply.value(["ok": true, "path": path, "width": Int(image.size.width), "height": Int(image.size.height)])
                } catch { reply.fail(error.localizedDescription) }
            }
        case "testResize" where TestMode.active:
            guard let w = (params["width"] as? NSNumber)?.doubleValue, let h = (params["height"] as? NSNumber)?.doubleValue, w >= 320, h >= 240 else {
                return reply.fail("크기가 올바르지 않아요.")
            }
            panel.setFrame(NSRect(origin: panel.frame.origin, size: NSSize(width: w, height: h)), display: true)
            reply.value(["ok": true])
        // v0.7 C: 글을 시스템 클립보드에 직접 쓴다(WKWebView에서 navigator.clipboard·execCommand가 막힐 때 대안). 시험 실행은 글자 수만 남긴다.
        case "copyText":
            guard let text = params["text"] as? String else { return reply.fail("복사할 글이 없어요.") }
            if TestMode.active {
                print("TEST_COPY \(text.count)"); fflush(stdout)
                return reply.value(["ok": true, "chars": text.count])
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            reply.value(["ok": pb.setString(text, forType: .string), "chars": text.count])
        default:
            // v0.8 Claude 연결(aiStatus … copyRich) → 사서 브리지 순서로 넘긴다
            if !handleAIMethod(method, params, reply: reply) && !handleBrainMethod(method, params, reply: reply) {
                reply.fail("지원하지 않는 요청이에요: \(method)")
            }
        }
    }

    fileprivate func addAtlassian(_ params: [String: Any], reply: Reply) {
        func text(_ key: String) -> String { (params[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        let site = text("site"), email = text("email"), token = text("token")
        guard !site.isEmpty, !email.isEmpty, !token.isEmpty else {
            return reply.value(["ok": false, "error": "사이트 주소, 이메일, API 토큰을 모두 입력해 주세요."])
        }
        func list(_ value: Any?) -> [String]? {
            let items: [String]
            if let array = value as? [String] { items = array }
            else if let line = value as? String { items = line.split(whereSeparator: { ",\n".contains($0) }).map(String.init) }
            else { return nil }
            let cleaned = items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return cleaned.isEmpty ? nil : cleaned
        }
        let spaces = list(params["spaces"])
        let jqlText = text("jql")
        let jql = jqlText.isEmpty ? nil : jqlText
        let library: Library = self.library
        Task.detached {
            do {
                let source = try await library.addAtlassian(site: site, email: email, token: token, spaces: spaces, jql: jql)
                reply.value(["ok": true, "source": source])
            } catch {
                reply.value(["ok": false, "error": koreanMessage(error)])
            }
        }
    }

    fileprivate func addSource(kind: String, reply: Reply) {
        guard kind == "folder" || kind == "obsidian" else { return reply.fail("알 수 없는 출처 종류예요.") }
        let obsidian = kind == "obsidian"
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = false
        open.canCreateDirectories = false
        open.prompt = "선택"
        open.message = obsidian ? "옵시디언 볼트 폴더를 선택하세요." : "연결할 폴더를 선택하세요."
        let library: Library = self.library
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = open.url else { return reply.value(["ok": false, "cancelled": true]) }
            let path = url.path
            var warning: String?
            if obsidian {
                var isDir: ObjCBool = false
                if !(FileManager.default.fileExists(atPath: url.appendingPathComponent(".obsidian").path, isDirectory: &isDir) && isDir.boolValue) {
                    warning = "이 폴더에서 .obsidian 폴더를 찾지 못했어요. 옵시디언 볼트가 맞는지 확인해 주세요. 그래도 폴더는 연결했어요."
                }
            }
            self?.engineQueue.async {
                do {
                    let source = try library.addFolder(path: path, obsidian: obsidian)
                    var result: [String: Any] = ["ok": true, "source": source]
                    if let warning = warning { result["warning"] = warning }
                    reply.value(result)
                } catch {
                    reply.value(["ok": false, "error": koreanMessage(error)])
                }
            }
        }
        if panel.isVisible { open.beginSheetModal(for: panel, completionHandler: handle) }
        else { open.begin(completionHandler: handle) }
    }

    /// 브라우저 로그인(OAuth) 후 Confluence·Jira를 MCP로 연결한다 (V04 §6.4). 창은 그대로 둔다.
    fileprivate func addMCP(_ params: [String: Any], reply: Reply) {
        guard ((params["server"] as? String) ?? "atlassian") == "atlassian" else { return reply.fail("지원하지 않는 MCP 서버예요.") }
        let given = (params["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let urlText = given.isEmpty ? (MCPRegistration.codexAtlassianURL() ?? "https://mcp.atlassian.com/v1/mcp") : given
        // https만 받는다. 이 Mac 안(127.0.0.1·localhost)의 서버만 http 허용(모의 서버 시험용).
        guard let serverURL = URL(string: urlText), let host = serverURL.host,
              serverURL.scheme == "https" || (serverURL.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else {
            return reply.fail("MCP 서버 주소가 올바르지 않아요.")
        }
        let chosen = (params["site"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let library: Library = self.library
        let task = Task.detached {
            var secret = (chosen?.isEmpty == false) ? PendingMCPAuth.take(urlText) : nil
            if secret == nil {
                do {
                    secret = try await MCPAuth.authorize(serverURL: serverURL, openURL: { url in
                        if TestMode.fakeBrowser {
                            Task.detached { _ = try? await URLSession.shared.data(from: url) }   // 리디렉트를 따라 루프백까지 간다
                        } else {
                            DispatchQueue.main.async { if !TestMode.intercept("url", url.absoluteString) { NSWorkspace.shared.open(url) } }
                        }
                    })
                } catch {
                    let cancelled: Bool
                    if let auth = error as? MCPAuthError { cancelled = auth == .cancelled || auth == .timedOut }
                    else { cancelled = error is CancellationError }
                    return reply.value(["ok": false, "cancelled": cancelled, "error": koreanMessage(error)])
                }
            }
            guard let token = secret else { return reply.value(["ok": false, "cancelled": true]) }
            var config = SourceConfig(id: UUID().uuidString, kind: .mcp, name: "Atlassian", path: nil, site: nil, email: nil,
                                      confluenceSpaces: nil, jiraJQL: nil, enabled: true, addedAt: Date(),
                                      mcpURL: urlText, mcpSite: nil)
            do {
                var host: String? = nil
                if let chosen = chosen, !chosen.isEmpty { host = URL(string: chosen)?.host ?? chosen }
                else {
                    let sites = try await AtlassianMCPConnector(config: config, token: token).sites()
                    if sites.count > 1 {
                        PendingMCPAuth.put(urlText, token)
                        return reply.value(["ok": false, "needSite": true, "sites": sites.map { ["name": $0.name, "url": $0.url] }])
                    }
                    host = sites.first.flatMap { URL(string: $0.url)?.host }
                }
                guard let siteHost = host else { return reply.value(["ok": false, "error": "연결할 수 있는 Atlassian 사이트가 없어요."]) }
                config.mcpSite = siteHost
                config.name = "Atlassian · \(siteHost)"
                let source = try await library.addRemote(config: config, secret: token)
                reply.value(["ok": true, "source": source])
            } catch {
                reply.value(["ok": false, "error": koreanMessage(error)])
            }
        }
        MCPLogin.begin(task)
    }

    /// 원본 열기 (§7). 파일 → 옵시디언 소스면 Obsidian, 아니면 기본 앱 / reveal → Finder / 웹 → 기본 브라우저.
    fileprivate func openOriginal(_ target: (location: String, sourceKind: SourceKind, isFile: Bool), reveal: Bool, obsidian: Bool = false) throws {
        let workspace = NSWorkspace.shared
        if target.isFile {
            let fileURL = URL(fileURLWithPath: target.location)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { throw BridgeError("원본 파일을 찾을 수 없어요. 옮겨졌거나 삭제됐을 수 있어요.") }
            if TestMode.intercept(reveal ? "reveal" : obsidian ? "obsidian" : "file", fileURL.path) { return }
            if reveal {
                workspace.activateFileViewerSelecting([fileURL])
            } else if obsidian {
                // v0.6: 옵시디언은 사용자가 "옵시디언에서 열기"를 고른 때만 (설치돼 있고 볼트의 md일 때)
                guard target.sourceKind == .obsidian, ["md", "markdown"].contains(fileURL.pathExtension.lowercased()),
                      workspace.urlForApplication(withBundleIdentifier: "md.obsidian") != nil,
                      let url = URL(string: "obsidian://open?path=" + Self.percentEncode(fileURL.path)) else {
                    throw BridgeError("옵시디언이 설치돼 있지 않거나 옵시디언 볼트의 노트가 아니에요.")
                }
                workspace.open(url)
            } else {
                workspace.open(fileURL)
            }
        } else {
            guard let url = URL(string: target.location), url.scheme == "https" || url.scheme == "http" else {
                throw BridgeError("원본 주소가 올바르지 않아요.")
            }
            if TestMode.intercept("url", url.absoluteString) { return }
            workspace.open(url)
        }
        // v0.4: 원본을 연 뒤에도 창은 그대로 둔다.
    }

    private static func percentEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? text
    }
}

// MARK: - MCP 등록 (V04 §5.3): Codex · Claude Desktop · Claude Code

/// 설정 파일 위치의 뿌리. SYNAPSE_TEST_CONFIG_HOME이 있으면 ~ 대신 그 폴더(시험 전용).
/// 이때는 PATH도 보지 않고 그 폴더 안에서만 `claude`를 찾는다.
enum MCPRegistration {
    static let name = "synapse"
    static var testRoot: String? { TestMode.env["SYNAPSE_TEST_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } }
    static var root: URL { URL(fileURLWithPath: testRoot ?? NSHomeDirectory(), isDirectory: true) }
    static var codexConfig: URL { root.appendingPathComponent(".codex/config.toml") }
    static var desktopConfig: URL { root.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json") }
    static var claudeJSON: URL { root.appendingPathComponent(".claude.json") }
    static var serverPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/synapse-mcp").path }

    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static var claudeCodeCommand: String { "claude mcp add --scope user \(name) -- \(shellQuote(serverPath))" }

    static func claudeExecutable() -> String? {
        var dirs = [".local/bin", ".claude/local", ".npm-global/bin", ".bun/bin", ".volta/bin"].map { root.appendingPathComponent($0).path }
        if testRoot == nil {
            dirs += ["/opt/homebrew/bin", "/usr/local/bin"]
            dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        }
        return dirs.map { $0 + "/claude" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func hint(_ client: String) -> String {
        switch client {
        case "codex": return "Codex를 다시 시작하면 synapse 도구가 보여요."
        case "claudeDesktop": return "Claude 데스크톱 앱을 완전히 종료한 뒤 다시 열면 synapse 도구가 보여요."
        default: return "새 Claude Code 대화를 시작하면 synapse 도구가 보여요."
        }
    }

    // MARK: 상태

    static func status() -> [String: Any] {
        let fm = FileManager.default
        var clients: [String: String] = [:]
        // Codex
        if let text = try? String(contentsOf: codexConfig, encoding: .utf8), tomlCommand(in: text) == serverPath { clients["codex"] = "registered" }
        else { clients["codex"] = fm.fileExists(atPath: codexConfig.deletingLastPathComponent().path) ? "absent" : "unavailable" }
        // Claude Desktop
        if jsonCommand(at: desktopConfig, path: ["mcpServers", name]) == serverPath { clients["claudeDesktop"] = "registered" }
        else { clients["claudeDesktop"] = fm.fileExists(atPath: desktopConfig.deletingLastPathComponent().path) ? "absent" : "unavailable" }
        // Claude Code
        if jsonCommand(at: claudeJSON, path: ["mcpServers", name]) == serverPath { clients["claudeCode"] = "registered" }
        else { clients["claudeCode"] = claudeExecutable() != nil ? "absent" : "unavailable" }
        return ["serverPath": serverPath, "serverExists": fm.isExecutableFile(atPath: serverPath),
                "clients": clients, "claudeCodeCommand": claudeCodeCommand]
    }

    static func jsonCommand(at url: URL, path: [String]) -> String? {
        guard let data = try? Data(contentsOf: url), var node = try? JSONSerialization.jsonObject(with: data) else { return nil }
        for key in path { guard let next = (node as? [String: Any])?[key] else { return nil }; node = next }
        return (node as? [String: Any])?["command"] as? String
    }

    // MARK: TOML (필요한 부분만 줄 단위로 고친다. 사용자의 다른 설정·줄바꿈 형식은 그대로 둔다)

    static func tomlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// 따옴표 밖의 `#` 주석을 떼고 앞뒤 공백·\r을 지운다.
    private static func clean(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        var out = ""
        for ch in line {
            if let q = quote {
                out.append(ch)
                if escaped { escaped = false } else if ch == "\\" && q == "\"" { escaped = true } else if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" { quote = ch; out.append(ch) }
            else if ch == "#" { break }
            else { out.append(ch) }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 공백·따옴표를 뺀 비교용 모양: `[ mcp_servers . "synapse" ]` → `[mcp_servers.synapse]`
    private static func compact(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace && $0 != "\"" && $0 != "'" })
    }

    private static func sectionRange(in lines: [String], header: String) -> Range<Int>? {
        let wanted = compact(header)
        guard let start = lines.firstIndex(where: { compact(clean($0)) == wanted }) else { return nil }
        var end = start + 1
        while end < lines.count, !clean(lines[end]).hasPrefix("[") { end += 1 }
        return start..<end
    }

    /// `[mcp_servers]` 아래 `synapse = {…}`, 최상위 `mcp_servers.synapse… =` 같은, 안전하게 고칠 수 없는 형태로 이미 있는가.
    private static func hasUneditableSynapse(_ lines: [String]) -> Bool {
        var section = ""
        for raw in lines {
            let line = clean(raw)
            if line.isEmpty { continue }
            if line.hasPrefix("[") { section = compact(line); continue }
            let key = compact(line)
            func matches(_ prefix: String) -> Bool {
                guard key.hasPrefix(prefix) else { return false }
                let rest = key.dropFirst(prefix.count)
                return rest.hasPrefix(".") || rest.hasPrefix("=")
            }
            if section.isEmpty && matches("mcp_servers.\(name)") { return true }
            if section == "[mcp_servers]" && matches(name) { return true }
        }
        return false
    }

    private static func unquote(_ raw: String) -> String? {
        let value = clean(raw)
        guard value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q else { return nil }
        let inner = String(value.dropFirst().dropLast())
        return q == "'" ? inner : inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func keyValueIndex(_ key: String, in lines: [String], range: Range<Int>) -> (Int, String)? {
        for index in range {
            let t = clean(lines[index])
            guard t.hasPrefix(key) else { continue }
            let rest = t.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("=") { return (index, String(rest.dropFirst())) }
        }
        return nil
    }

    private static func tomlValue(_ key: String, in lines: [String], range: Range<Int>) -> String? {
        keyValueIndex(key, in: lines, range: range).flatMap { unquote($0.1) }
    }

    static func tomlCommand(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let range = sectionRange(in: lines, header: "[mcp_servers.\(name)]") else { return nil }
        return tomlValue("command", in: lines, range: range)
    }

    /// Codex가 쓰는 Atlassian MCP 주소(`[mcp_servers.atlassian]`의 url). 없으면 nil.
    static func codexAtlassianURL() -> String? {
        guard let text = try? String(contentsOf: codexConfig, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard let range = sectionRange(in: lines, header: "[mcp_servers.atlassian]"),
              let url = tomlValue("url", in: lines, range: range), url.hasPrefix("https://") else { return nil }
        return url
    }

    /// 고친 TOML. 안전하게 고칠 수 없으면 nil(자동 편집 안 함).
    static func updatedTOML(_ text: String) -> String? {
        let eol = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: "\n")
        let commandLine = "command = \(tomlString(serverPath))"
        if let range = sectionRange(in: lines, header: "[mcp_servers.\(name)]") {
            let cr: (String) -> String = { $0.hasSuffix("\r") ? "\r" : "" }
            if let (index, _) = keyValueIndex("command", in: lines, range: range) { lines[index] = commandLine + cr(lines[index]) }
            else { lines.insert(commandLine + cr(lines[range.lowerBound]), at: range.lowerBound + 1) }
            return lines.joined(separator: "\n")
        }
        if hasUneditableSynapse(lines) { return nil }
        var out = text
        if !out.isEmpty && out.utf8.last != 10 { out += eol }   // "\r\n"은 글자 하나라 hasSuffix("\n")이 거짓이다
        if !out.isEmpty { out += eol }
        return out + "[mcp_servers.\(name)]" + eol + commandLine + eol
    }

    static var codexSnippet: String { "[mcp_servers.\(name)]\ncommand = \(tomlString(serverPath))" }

    // MARK: 등록 (한 번에 하나씩: 전용 직렬 큐)

    private static let registrationQueue = DispatchQueue(label: "synapse.mcp-registration")

    private static func fail(_ client: String, _ message: String, command: String? = nil) -> [String: Any] {
        ["ok": false, "client": client, "error": message, "command": command ?? claudeCodeCommand]
    }

    /// 심볼릭 링크(dotfiles 관리자)는 끝까지 따라가 실제 파일에 쓴다. 끊어진 링크는 그 목적지에 새로 만든다.
    static func resolvedTarget(_ url: URL) -> URL {
        let fm = FileManager.default
        var current = url
        for _ in 0..<16 {
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: current.path) else { break }
            current = destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return current
    }

    /// 내용이 바뀔 때만 쓴다. 실제 파일 옆에 임시 파일(원래 권한, 없으면 0600)을 만들어 교체하므로 권한이 넓어지는 순간이 없다.
    /// 백업(`<파일>.synapse-bak`)은 아직 없을 때만 만든다 — Synapse를 쓰기 전 원본을 지키기 위해.
    private static func write(_ data: Data, to link: URL) throws -> Bool {
        let fm = FileManager.default
        let target = resolvedTarget(link)
        let existing = try? Data(contentsOf: target)
        if existing == data { return false }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var permissions = 0o600
        if existing != nil {
            if let value = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber { permissions = value.intValue & 0o777 }
            let backup = URL(fileURLWithPath: target.path + ".synapse-bak")
            if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: target, to: backup) }
        }
        let temp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).synapse-tmp-\(getpid())")
        try? fm.removeItem(at: temp)
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: permissions]) else {
            throw BridgeError("임시 파일을 만들지 못했어요.")
        }
        try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
        if rename(temp.path, target.path) != 0 {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: temp)
            throw BridgeError(reason)
        }
        return true
    }

    static func register(client: String) -> [String: Any] {
        if TestMode.active && testRoot == nil {
            return fail(client, "시험 실행에서는 SYNAPSE_TEST_CONFIG_HOME 없이 등록할 수 없어요.")
        }
        return registrationQueue.sync {
            guard FileManager.default.isExecutableFile(atPath: serverPath) else {
                return fail(client, "synapse-mcp 파일을 찾을 수 없어요. Synapse.app을 다시 설치해 주세요.")
            }
            do {
                switch client {
                case "codex": return try registerCodex()
                case "claudeDesktop": return try registerDesktop()
                case "claudeCode": return registerClaudeCode()
                default: return fail(client, "알 수 없는 클라이언트예요.")
                }
            } catch {
                return fail(client, "설정 파일을 쓰지 못했어요: \(koreanDescription(error))")
            }
        }
    }

    private static func koreanDescription(_ error: Error) -> String {
        (error as? BridgeError)?.message ?? error.localizedDescription
    }

    private static func registerCodex() throws -> [String: Any] {
        let target = resolvedTarget(codexConfig)
        var current = ""
        if FileManager.default.fileExists(atPath: target.path) {
            guard let text = try? String(contentsOf: target, encoding: .utf8) else {
                return fail("codex", "Codex 설정 파일을 읽을 수 없어요(UTF-8이 아니에요). 파일은 건드리지 않았어요.", command: codexSnippet)
            }
            current = text
        }
        guard let updated = updatedTOML(current) else {
            return fail("codex", "Codex 설정에 synapse가 다른 형태로 이미 있어서 자동으로 고치지 않았어요. config.toml에서 직접 아래처럼 바꿔 주세요.",
                        command: codexSnippet)
        }
        let changed = try write(Data(updated.utf8), to: codexConfig)
        return ["ok": true, "client": "codex", "changed": changed, "path": target.path, "restartHint": hint("codex")]
    }

    private static func registerDesktop() throws -> [String: Any] {
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: resolvedTarget(desktopConfig)), !data.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return fail("claudeDesktop", "Claude 데스크톱 설정 파일을 읽을 수 없어요. 파일은 건드리지 않았어요.")
            }
            config = parsed
        }
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        var entry = servers[name] as? [String: Any] ?? [:]
        entry["command"] = serverPath
        servers[name] = entry
        config["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let changed = try write(data + Data("\n".utf8), to: desktopConfig)
        return ["ok": true, "client": "claudeDesktop", "changed": changed, "path": resolvedTarget(desktopConfig).path,
                "restartHint": hint("claudeDesktop")]
    }

    private static func runClaude(_ executable: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        if testRoot != nil { environment["HOME"] = root.path }
        // 앱은 launchd의 짧은 PATH로 뜬다. npm·Homebrew의 claude(#!/usr/bin/env node)가 node를 찾도록 PATH를 넓힌다.
        let existing = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var paths = [URL(fileURLWithPath: executable).deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"] + existing
        var seen = Set<String>()
        paths = paths.filter { seen.insert($0).inserted }
        environment["PATH"] = paths.joined(separator: ":")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate(); return (-2, "시간이 너무 오래 걸렸어요.") }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `~/.claude.json`의 기존 synapse 항목(stdio만)을 `claude mcp add` 인자로 되돌릴 수 있게 만든다.
    private static func previousAddArguments() -> [String]? {
        guard let data = try? Data(contentsOf: claudeJSON),
              let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entry = (top["mcpServers"] as? [String: Any])?[name] as? [String: Any],
              let command = entry["command"] as? String, (entry["type"] as? String ?? "stdio") == "stdio" else { return nil }
        let env = (entry["env"] as? [String: String] ?? [:]).sorted { $0.key < $1.key }.flatMap { ["-e", "\($0.key)=\($0.value)"] }
        return ["mcp", "add", "--scope", "user"] + env + [name, "--", command] + (entry["args"] as? [String] ?? [])
    }

    private static func registerClaudeCode() -> [String: Any] {
        guard let claude = claudeExecutable() else {
            return ["ok": false, "client": "claudeCode", "unavailable": true,
                    "error": "claude 명령을 찾지 못했어요. 터미널에서 아래 명령을 직접 실행해 주세요.",
                    "command": claudeCodeCommand, "restartHint": hint("claudeCode")]
        }
        if jsonCommand(at: claudeJSON, path: ["mcpServers", name]) == serverPath {   // 이미 등록됨
            return ["ok": true, "client": "claudeCode", "changed": false, "restartHint": hint("claudeCode")]
        }
        let previous = previousAddArguments()
        var removed = false
        if jsonCommand(at: claudeJSON, path: ["mcpServers", name]) != nil {   // 경로가 달라진 옛 등록은 지우고 다시 등록
            removed = runClaude(claude, ["mcp", "remove", "--scope", "user", name]).0 == 0
        }
        let (code, output) = runClaude(claude, ["mcp", "add", "--scope", "user", name, "--", serverPath])
        guard code == 0 else {
            var restored = ""
            if removed, let previous = previous {   // 지우기만 되고 등록이 실패했으면 이전 등록을 되살린다
                restored = runClaude(claude, previous).0 == 0 ? " 이전 등록은 그대로 두었어요." : " 이전 등록을 되살리지 못했어요."
            }
            return ["ok": false, "client": "claudeCode", "error": "claude mcp add가 실패했어요: \(String(output.prefix(200)))\(restored)",
                    "command": claudeCodeCommand]
        }
        return ["ok": true, "client": "claudeCode", "changed": true, "restartHint": hint("claudeCode")]
    }
}

// MARK: - 사서(Brain): 수명 · 이벤트 · 메뉴 막대 · 브리지 (docs/V05.md §8)

extension AppDelegate {
    private static let brainMethods: Set<String> = [
        "home", "why", "feedback", "week", "map", "pending", "decide", "decideBundle", "undo", "aiLog",
        "brainSettings", "setBrainSetting", "policy", "approvePolicy", "claudeInstruction", "track", "runBatch", "folders",
        "setProjectScope",   // v0.7 B
        "tickets",  // v0.7 A 티켓 화면
        // v0.9 작업 지도 · 정리 비서 (docs/V09.md §8)
        "workMap", "workMapDetail", "tidyPlan", "tidyDecide", "tidyDecideGroup", "tidyUndo", "tidyPromote",
        "tidyRules", "tidySetRule", "tidyRunRules",
    ]
    private static let brainSettingKeys: Set<String> = Set<String>([
        BrainSetting.sessionsEnabled, BrainSetting.sessionsRequestText, "sessions.clear", BrainSetting.stopped, BrainSetting.mcpRemoteBodies,
        BrainSetting.appleNoticeShown, BrainSetting.mcpDirectApply,
        BrainSetting.homeUrgentScope,   // v0.7 B
    ]).union(TidySetting.appKeys)       // v0.9 정리 설정
    private static let trackEvents: Set<String> = ["open", "view", "edit", "save"]

    /// 사서를 연다. 실패해도 앱은 사서 없이 동작한다(브리지가 오류를 돌려주고, 화면은 home 대신 기존 global로 간다).
    func startBrain(home: URL) {
        let lib: Library = library
        do {
            let opened = try Brain(home: home, mode: .app, sources: { lib.sourceConfigs() })
            opened.onEvent = { [weak self] kind in self?.brainEvent(kind) }      // 메인 큐
            // v0.9 §8: 정리 비서의 '색인에서 빼기'·되돌리기가 출처 제외 폴더를 바꾸는 길 (기존 형식은 그대로)
            opened.setSourceExcludesUpdater { id, add, remove in
                guard let src = lib.sourceConfigs().first(where: { $0.id == id }) else { return "출처를 찾을 수 없어요." }
                var list = Indexer.excludedFolders(src)
                for a in add.map({ Indexer.nfc($0).trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }) where !a.isEmpty && !list.contains(a) {
                    list.append(a)
                }
                let drop = Set(remove.map { Indexer.nfc($0).trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) })
                list.removeAll { drop.contains($0) }
                do { _ = try lib.updateSource(id: id, includeKinds: src.includeKinds, excludeFolders: list); return nil }
                catch { return (error as? LibraryError)?.message ?? error.localizedDescription }
            }
            brain = opened
        } catch {
            brain = nil
            print("BRAIN_UNAVAILABLE \(error.localizedDescription)")
            fflush(stdout)
        }
    }

    /// 사서 → 화면: 해당 데이터를 다시 요청하라고 알린다. 메뉴 막대 점도 여기서 갱신한다.
    fileprivate func brainEvent(_ kind: BrainEventKind) {
        run("window.synapseBrainEvent && window.synapseBrainEvent({type: \"\(kind.rawValue)\"})")
        if kind == .home || kind == .pending || kind == .settings { refreshBrainState() }
    }

    /// 정리 대기 수·비상 정지 여부를 사서에서 다시 읽는다(엔진 큐). 읽는 동안 온 알림은 한 번 더 읽는 것으로 합친다.
    func refreshBrainState() {
        guard let brain = brain else { return }
        if brainStateRefreshing { brainStateDirty = true; return }
        brainStateRefreshing = true
        engineQueue.async { [weak self] in
            let p = brain.pending()
            let cards = (p["cards"] as? [Any])?.count ?? 0
            let more = (p["more"] as? NSNumber)?.intValue ?? 0
            let stopped = (p["stopped"] as? Bool) ?? false
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.applyBrainState(waiting: cards + more > 0, stopped: stopped)
                self.brainStateRefreshing = false
                if self.brainStateDirty { self.brainStateDirty = false; self.refreshBrainState() }
            }
        }
    }

    private func applyBrainState(waiting: Bool, stopped: Bool) {
        brainStopped = stopped
        let changed = waiting != pendingWaiting
        pendingWaiting = waiting
        statusDot?.isHidden = !waiting
        statusItem?.button?.toolTip = waiting ? "Synapse · 정리할 것이 있어요" : "Synapse · 클릭해서 열기, 우클릭으로 메뉴"
        if TestMode.active && changed { print("STATUS_DOT \(waiting ? 1 : 0)"); fflush(stdout) }
    }

    /// 우클릭 메뉴 "사서 멈추기 / 다시 시작" (brain.stopped 토글).
    @objc fileprivate func toggleBrainStopped() {
        guard let brain = brain else { return }
        let next = brainStopped ? "0" : "1"
        engineQueue.async { [weak self] in
            _ = brain.setSetting(key: BrainSetting.stopped, value: next)
            DispatchQueue.main.async {
                self?.brainStopped = (next == "1")
                self?.refreshBrainState()
                self?.run("window.synapseBrainEvent && (window.synapseBrainEvent({type: \"settings\"}), window.synapseBrainEvent({type: \"home\"}))")
            }
        }
    }

    /// Synapse 안의 사람 활동(열기·보기·저장)을 사서에 알린다. 엔진 큐에서 부른다.
    fileprivate func autoTrack(_ event: String, _ id: String) {
        guard let brain = brain else { return }
        engineQueue.async { brain.track(event: event, docId: id) }
    }

    /// §8.2 사서 브리지 17개. 사서 메서드는 스레드 안전하므로 기존처럼 엔진 큐에서 처리한다. 처리했으면 true.
    fileprivate func handleBrainMethod(_ method: String, _ params: [String: Any], reply: Reply) -> Bool {
        guard AppDelegate.brainMethods.contains(method) else { return false }
        guard let brain = brain else {
            reply.value(["ok": false, "error": "사서를 열지 못했어요"])
            return true
        }
        func text(_ key: String) -> String? { (params[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func number(_ key: String) -> Int? {
            guard let n = params[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.intValue
        }
        func go(_ work: @escaping () -> [String: Any]) { engineQueue.async { reply.value(work()) } }
        func need(_ key: String, _ message: String, _ use: (String) -> Void) {
            if let v = text(key) { use(v) } else { reply.fail(message) }
        }
        switch method {
        case "home": go { brain.home() }
        case "why": need("id", "문서 번호가 없어요.") { id in go { brain.why(id: id) } }
        case "feedback":
            guard let id = text("id"), let action = text("action") else { reply.fail("요청 값이 부족해요."); break }
            let scope = text("scope")
            go { brain.feedback(id: id, action: action, scope: scope) }
        case "week":
            let offset = number("offset") ?? 0
            go { brain.week(offset: offset) }
        case "map": go { brain.map() }
        case "pending": go { brain.pending() }
        case "decide":
            guard let id = text("id"), let action = text("action") else { reply.fail("요청 값이 부족해요."); break }
            let to = text("to")
            go { brain.decide(id: id, action: action, to: to) }
        case "decideBundle": need("id", "묶음 번호가 없어요.") { id in go { brain.decideBundle(id: id) } }
        case "undo":
            let batch = text("batchId")
            go { brain.undo(batchId: batch) }
        case "aiLog":
            let limit = min(max(number("limit") ?? 100, 1), 1000)
            go { brain.aiLog(limit: limit) }
        case "brainSettings": go { brain.settings() }
        case "setBrainSetting":
            guard let key = text("key"), AppDelegate.brainSettingKeys.contains(key) else { reply.fail("알 수 없는 설정이에요."); break }
            var value: String
            if let t = params["value"] as? String { value = t }
            else if let n = params["value"] as? NSNumber { value = CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "1" : "0") : n.stringValue }
            else { reply.fail("설정 값이 없어요."); break }
            if value == "true" { value = "1" } else if value == "false" { value = "0" }
            engineQueue.async { [weak self] in
                let result = brain.setSetting(key: key, value: value)
                reply.value(result)
                if key == BrainSetting.stopped { DispatchQueue.main.async { self?.refreshBrainState() } }
            }
        case "policy": go { brain.policy() }
        case "approvePolicy": go { brain.approvePolicy() }
        case "claudeInstruction":
            guard let context = text("context") else { reply.fail("지시문 종류가 없어요."); break }
            let id = text("id")
            go { brain.claudeInstruction(context: context, id: id) }
        case "track":
            guard let event = text("event"), AppDelegate.trackEvents.contains(event), let docId = text("docId") else {
                reply.fail("활동 종류나 문서 번호가 올바르지 않아요."); break
            }
            go { brain.track(event: event, docId: docId); return ["ok": true] }
        case "runBatch": go { brain.runBatchNow() }
        case "setProjectScope":   // v0.7 B: 프로젝트를 업무/개인으로 (scope: work | personal | auto)
            guard let project = text("project"), let scope = text("scope") else { reply.fail("프로젝트와 scope가 필요해요."); break }
            go { brain.setProjectScope(project: project, scope: scope) }
        case "folders":
            // 정리함 목적지 고르기용: 규칙표가 허용하는 기존 폴더 경로 (policy().folders에서 꺼낸다)
            go {
                let list = (brain.policy()["folders"] as? [[String: Any]]) ?? []
                return ["folders": list.compactMap { $0["path"] as? String }]
            }
        case "tickets":
            let mine = (params["mine"] as? NSNumber).map { $0.boolValue } ?? false
            go { brain.tickets(mine: mine) }
        // v0.9 작업 지도 · 정리 비서 (docs/V09.md §8)
        case "workMap": go { brain.workMap() }
        case "workMapDetail": need("id", "항목 번호가 없어요.") { id in go { brain.workMapDetail(id: id) } }
        case "tidyPlan": go { brain.tidyPlan() }
        case "tidyDecide":
            guard let id = text("id"), let action = text("action"),
                  ["approve", "reject", "later", "dismiss", "to"].contains(action) else { reply.fail("요청 값이 부족해요."); break }
            let to = text("to")
            if action == "to" && to == nil { reply.fail("옮길 폴더를 골라 주세요."); break }
            go { brain.tidyDecide(id: id, action: action, to: to) }
        case "tidyDecideGroup":
            // ids = 화면이 확인 창에서 보여 준 카드 (그 사이 새로 들어온 제안은 승인하지 않는다)
            let ids = (params["ids"] as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty }
            need("group", "묶음이 없어요.") { g in go { brain.tidyDecideGroup(group: g, ids: ids) } }
        case "tidyUndo":
            let batch = text("batchId")
            go { brain.tidyUndo(batchId: batch) }
        case "tidyPromote":
            guard let sig = text("signature") else { reply.fail("규칙이 없어요."); break }
            let accept = (params["accept"] as? NSNumber).map { $0.boolValue } ?? false
            go { brain.tidyPromote(signature: sig, accept: accept) }
        case "tidyRules": go { brain.tidyRules() }
        case "tidySetRule":
            guard let sig = text("signature"), let state = text("state"), ["auto", "ask", "off"].contains(state) else {
                reply.fail("규칙과 상태(auto · ask · off)가 필요해요."); break
            }
            go { brain.tidySetRule(signature: sig, state: state) }
        case "tidyRunRules": go { brain.tidyRunRules() }
        default: return false
        }
        return true
    }
}

// MARK: - v0.6 T: 휴지통 · 직접 옮기기 브리지

extension AppDelegate {
    fileprivate func handleTrashMethod(_ method: String, _ params: [String: Any], reply: Reply) {
        guard let brain = brain else { return reply.value(["ok": false, "error": "사서를 열지 못했어요"]) }
        var ids = (params["ids"] as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty } ?? []
        if ids.isEmpty, let one = params["id"] as? String, !one.isEmpty { ids = [one] }
        let batch = (params["batch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        func go(_ work: @escaping () -> [String: Any]) { engineQueue.async { reply.value(work()) } }
        switch method {
        case "listTrash": go { brain.listTrash() }
        case "restoreTrash":
            guard !ids.isEmpty || batch != nil else { return reply.fail("되살릴 항목이 없어요.") }
            go { brain.restoreTrash(ids: ids.isEmpty ? nil : ids, batch: batch) }
        default:
            guard !ids.isEmpty else { return reply.fail("문서 번호가 없어요.") }
            if ids.count > 500 { return reply.fail("한 번에 500개까지만 할 수 있어요.") }
            switch method {
            case "trashInfo": go { brain.trashInfo(ids: ids) }
            case "trashDocs":
                let reason = params["reason"] as? String
                go { brain.trashDocs(ids: ids, reason: reason) }
            case "purgeTrash": go { brain.purgeTrash(ids: ids) }
            default:
                guard let to = params["to"] as? String else { return reply.fail("옮길 폴더를 골라 주세요.") }
                go { brain.moveDocs(ids: ids, to: to) }
            }
        }
    }
}

// MARK: - v0.8 Claude 연결: 수명 · 이벤트 · 브리지 (docs/V08.md §7)

extension AppDelegate {
    private static let aiMethods: Set<String> = [
        "aiStatus", "setAISetting", "aiTest", "aiDigest", "aiTask", "aiCancel", "aiRuns", "aiRun", "copyRich",
        "jiraPropose", "jiraApply",   // §6 Jira 제안 — 사서와 JiraApply로 처리한다(Claude 실행과 무관)
    ]

    /// 사서를 연 뒤에 부른다. 사서가 없어도 만든다(aiStatus는 늘 답하고, 정리는 "정리할 내용이 없어요"가 된다).
    /// synapse-mcp는 번들의 Contents/MacOS/synapse-mcp. 시험 실행(TestMode)은 SYNAPSE_CLAUDE_BIN이 없으면 Claude가 없는 것으로 본다.
    func startAI(home: URL) {
        let mcp = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("synapse-mcp")
        let service = AIService(home: home, brain: brain, digests: SynapseDigests(brain: brain as? Brain, library: library),
                                mcpBinary: mcp.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil },
                                testMode: TestMode.active)
        service.onEvent = { [weak self] event in self?.aiEvent(event) }     // 메인 큐
        // v0.9 §5: Claude 정리 계획(tidy)이 저장되면 정리 비서가 제안으로 넣는다 (자동 규칙이면 바로 적용)
        service.onDigestResult = { [weak self] kind, _, result, runId in
            guard kind == "tidy", let self = self, let brain = self.brain else { return }
            self.engineQueue.async { _ = brain.tidyIngest(result: result, runId: runId) }
        }
        ai = service
    }

    /// AIService → 화면: window.synapseAIEvent({type: status|run|digest}). 실행이 제안을 올리면 사서 pending 알림으로 넘긴다.
    fileprivate func aiEvent(_ event: AIEvent) {
        if case .proposals = event { brainEvent(.pending); return }
        guard let payload = event.json, let json = jsonString(payload) else { return }
        run("window.synapseAIEvent && window.synapseAIEvent(\(json))")
    }

    /// §7 표의 AI 브리지. 무거운 일(정리 입력 만들기·Claude 찾기)은 엔진 큐에서 한다. 처리했으면 true.
    fileprivate func handleAIMethod(_ method: String, _ params: [String: Any], reply: Reply) -> Bool {
        guard AppDelegate.aiMethods.contains(method) else { return false }
        if method == "copyRich" { copyRich(params, reply: reply); return true }
        if method == "jiraPropose" || method == "jiraApply" { handleJiraMethod(method, params, reply: reply); return true }
        guard let ai = ai else {
            reply.value(["ok": false, "error": "Claude 연결을 준비하지 못했어요"])
            return true
        }
        func text(_ key: String) -> String? { (params[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func number(_ key: String) -> Int? {
            guard let n = params[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.intValue
        }
        func go(_ work: @escaping () -> [String: Any]) { engineQueue.async { reply.value(work()) } }
        switch method {
        case "aiStatus": go { ai.status() }
        case "setAISetting":
            guard let key = text("key") else { reply.fail("설정 이름이 없어요."); break }
            let value: String
            if let t = params["value"] as? String { value = t }
            else if let n = params["value"] as? NSNumber { value = CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "1" : "0") : n.stringValue }
            else if params["value"] == nil || params["value"] is NSNull { value = "" }
            else { reply.fail("설정 값이 올바르지 않아요."); break }
            go { ai.setSetting(key: key, value: value) }
        case "aiTest":
            ai.test { reply.value($0) }
        case "aiDigest":
            guard let kind = text("kind") else { reply.fail("정리 종류가 없어요."); break }
            let offset = number("offset"), docId = text("docId"), mode = text("run") ?? "none"
            go { ai.digest(kind: kind, offset: offset, docId: docId, run: mode) }
        case "aiTask":
            let prompt = (params["prompt"] as? String) ?? ""
            let preset = text("preset")
            let context = (params["context"] as? [String: Any]) ?? [:]
            let lib: Library = library
            go {
                // 맥락 블록에 열려 있는 문서의 제목을 넣는다(본문은 넣지 않는다 — 필요하면 Claude가 get_note로 읽는다)
                var ctx = context
                if let id = ctx["docId"] as? String, !id.isEmpty, ctx["title"] == nil,
                   let title = (lib.documentJSON(id: id)?["doc"] as? [String: Any])?["title"] as? String {
                    ctx["title"] = title
                }
                return ai.startTask(prompt: prompt, preset: preset, context: ctx)
            }
        case "aiCancel":
            guard let id = text("runId") else { reply.fail("실행 번호가 없어요."); break }
            go { ai.cancel(runId: id) }
        case "aiRuns":
            let limit = min(max(number("limit") ?? 20, 1), 200)
            go { ai.runs(limit: limit) }
        case "aiRun":
            guard let id = text("runId") else { reply.fail("실행 번호가 없어요."); break }
            go { ai.run(id: id) }
        default: return false
        }
        return true
    }

    /// §6 Jira 제안. jiraPropose: 티켓 화면의 Claude 정리 제안을 정리함에 올린다(출처 Claude).
    /// jiraApply: 사람이 승인한 제안 하나를 연결된 Atlassian 계정으로 반영한다(되돌릴 수 없다 — 화면이 확인을 받은 뒤 부른다).
    fileprivate func handleJiraMethod(_ method: String, _ params: [String: Any], reply: Reply) {
        guard let brain = brain else { return reply.value(["ok": false, "error": "사서를 열지 못했어요"]) }
        if method == "jiraPropose" {
            guard let items = (params["items"] as? [Any])?.compactMap({ $0 as? [String: Any] }), !items.isEmpty else {
                return reply.fail("올릴 제안이 없어요.")
            }
            // 출처를 시키기 실행(claude)과 나눠 하루 한도를 따로 센다 — 실행 하나가 한도를 채워도 티켓 화면의 반영은 막히지 않게
            engineQueue.async { reply.value(brain.proposeJira(items: items, origin: "claude-digest", runId: nil)) }
            return
        }
        guard let id = (params["id"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { return reply.fail("제안 번호가 없어요.") }
        var overrides: [String: Any] = [:]
        if let body = params["body"] as? String { overrides["body"] = body }
        if let to = params["to"] as? String { overrides["to"] = to }
        let lib: Library = library
        Task.detached { reply.value(await JiraApply.run(brain: brain, library: lib, id: id, overrides: overrides)) }
    }

    /// 클립보드에 글과 HTML을 함께 쓴다(Confluence에 붙이면 글머리표가 산다). 시험 실행은 copyText처럼 글자 수만 남긴다.
    fileprivate func copyRich(_ params: [String: Any], reply: Reply) {
        guard let text = params["text"] as? String else { return reply.fail("복사할 글이 없어요.") }
        let html = (params["html"] as? String) ?? ""
        if TestMode.active {
            print("TEST_COPY \(text.count)"); fflush(stdout)
            return reply.value(["ok": true, "chars": text.count, "htmlChars": html.count])
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes(html.isEmpty ? [.string] : [.html, .string], owner: nil)
        var ok = pb.setString(text, forType: .string)
        if !html.isEmpty {
            // 문자 집합이 없으면 붙여 넣는 쪽(브라우저)이 한글을 깨뜨릴 수 있어 utf-8을 밝힌다
            let body = html.range(of: "charset", options: .caseInsensitive) == nil ? "<meta charset=\"utf-8\">" + html : html
            ok = pb.setString(body, forType: .html) && ok
        }
        reply.value(["ok": ok, "chars": text.count])
    }
}

// MARK: - Library composition root, events, test hooks

extension AppDelegate {
    func startLibrary() {
        Plugins.extract = { try Extractors.extract(fileAt: $0) }
        Plugins.supportedExtensions = Extractors.supportedExtensions
        Plugins.makeRemote = { config, token in
            switch config.kind {
            case .mcp: return AtlassianMCPConnector(config: config, token: token)
            default: return AtlassianConnector(config: config, token: token)
            }
        }
        // 시험 실행은 사용자 키체인을 건드리지 않는다.
        Plugins.secrets = TestMode.active ? MemorySecretStore() : KeychainSecretStore()

        let env = TestMode.env
        let home: URL
        if let custom = env["SYNAPSE_HOME"], !custom.isEmpty {
            home = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        } else if TestMode.active {
            // 시험 실행이 사용자의 실제 자료 폴더를 건드리지 않도록 임시 폴더를 쓴다.
            home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("synapse-test-home-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support", isDirectory: true)
            home = base.appendingPathComponent("Synapse", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        library = Library(home: home)
        startBrain(home: home)
        startAI(home: home)
        library.onEvent = { [weak self] event in self?.forward(event) }
        library.start()
        brain?.start()
        refreshBrainState()
        print("LIBRARY_HOME \(home.path)")
        fflush(stdout)
    }

    private func forward(_ event: LibraryEvent) {
        var payload: [String: Any]
        switch event {
        case let .progress(sourceId, done, total, phase):
            payload = ["type": "progress", "sourceId": sourceId, "done": done, "total": total, "phase": phase]
        case let .changed(reason):
            payload = ["type": "changed", "reason": reason]
            brain?.indexChanged()      // 사서가 1초 디바운스 뒤 새·바뀐 문서를 처리한다
        case let .sourceError(sourceId, message):
            payload = ["type": "error", "sourceId": sourceId, "message": message]
        }
        guard let json = jsonString(payload) else { return }
        let deliver: () -> Void = { [weak self] in self?.run("window.synapseLibraryEvent?.(\(json))") }
        if Thread.isMainThread { deliver() } else { DispatchQueue.main.async { deliver() } }
    }

    func jsonString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber || value is NSNull,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// SYNAPSE_TEST_OFFSCREEN=1: 창을 화면 밖에 두고, 앱을 활성화하지 않은 채 웹뷰만 살려 둔다.
    func showOffscreen() {
        let size = panel.frame.size
        // 화면 밖 창은 WebKit이 가려진 창으로 보고 페이지를 숨김 상태로 둔다(rAF·상태 확인이 멈춘다).
        // 시험 실행에서만 가림 감지를 끈다(비공개 설정 — 없으면 그냥 넘어간다).
        if webView.responds(to: Selector(("_setWindowOcclusionDetectionEnabled:"))) {
            webView.setValue(false, forKey: "windowOcclusionDetectionEnabled")
        }
        panel.setFrame(NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        print("PANEL_OFFSCREEN")
        fflush(stdout)
    }

    func scheduleTestRun() {
        guard TestMode.scriptPath != nil || TestMode.snapshotPath != nil || TestMode.exitAfter, !testRunScheduled else { return }
        testRunScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.runTestScript() }
    }

    private func runTestScript() {
        guard let path = TestMode.scriptPath else { return takeTestSnapshot() }
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("TEST_ERROR cannot read script \(path)")
            return takeTestSnapshot()
        }
        var finished = false
        let finish: () -> Void = { [weak self] in
            if finished { return }
            finished = true
            fflush(stdout)
            self?.takeTestSnapshot()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + TestMode.scriptTimeout) {
            if !finished { print("TEST_ERROR script timeout"); finish() }
        }
        webView.callAsyncJavaScript(source, arguments: [:], in: nil, in: .page) { [weak self] result in
            switch result {
            case .success(let value):
                let text = self?.jsonString(value) ?? "null"
                print("TEST_RESULT \(text)")
            case .failure(let error):
                print("TEST_ERROR \(error.localizedDescription)")
            }
            finish()
        }
    }

    private func takeTestSnapshot() {
        guard let path = TestMode.snapshotPath else { return finishTest() }
        webView.takeSnapshot(with: nil) { [weak self] image, error in
            if let image = image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                do { try png.write(to: URL(fileURLWithPath: path)); print("TEST_SNAPSHOT \(path) \(Int(image.size.width))x\(Int(image.size.height))") }
                catch { print("TEST_ERROR snapshot write: \(error.localizedDescription)") }
            } else {
                print("TEST_ERROR snapshot: \(error?.localizedDescription ?? "no image")")
            }
            self?.finishTest()
        }
    }

    private func finishTest() {
        fflush(stdout)
        if TestMode.exitAfter { NSApp.terminate(nil) }
    }
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
