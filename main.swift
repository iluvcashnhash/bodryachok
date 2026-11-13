import Cocoa
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import ServiceManagement
import UserNotifications

// Бодрячок — menu bar app that keeps the Mac awake (Amphetamine-style).
//
// What "awake" means here:
//  • system idle sleep is blocked (PreventUserIdleSystemSleep);
//  • unless "allow display sleep" is on, the display, screen saver and the idle
//    lock screen are blocked too (PreventUserIdleDisplaySleep);
//  • closed-lid mode flips `pmset disablesleep 1` for the session, so the Mac keeps
//    running with the lid shut. That needs root, so a one-time setup installs a
//    sudoers rule that allows exactly `pmset -a disablesleep 0|1` without a password.
//
// Safety rails for closed-lid mode (it is the only risky part):
//  • it is dropped when macOS reports the Mac is overheating (thermal state serious+);
//  • by default it only works on AC power;
//  • the screen is locked the moment the lid closes;
//  • if the app dies, `disablesleep` is put back by (1) a watchdog shell, (2) the app
//    on next launch, (3) a login agent that checks every minute — even after a reboot.

private let pmset = "/usr/bin/pmset"
private let sudoersPath = "/etc/sudoers.d/bodryachok"
private let bundleID = "local.bodryachok"
private let agentLabel = "local.bodryachok.failsafe"

enum Session {
    case indefinite
    case until(Date)
    case whileApp(pid_t, String)
    /// Request only: turned into `.until` when the session actually starts.
    case forMinutes(Int)
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var session: Session?
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var userActivityAssertion: IOPMAssertionID = 0
    private var timer: Timer?
    private var ticks = 0
    private var watchdogStarted = false

    /// Closed-lid mode was switched off for the rest of this session because the Mac got hot.
    private var lidBlockedByHeat = false
    private var lidWasClosed = false
    private var lidFailureShown = false
    /// The user chose "start anyway" below the battery limit — the limit is off for this session.
    private var ignoreBatteryLimit = false
    /// Why the last session ended on its own (shown in the menu until the next session).
    private var lastEnd: String?
    /// When closed-lid mode was dropped because of heat (shown in the menu).
    private var heatNote: String?
    private var termSource: DispatchSourceSignal?
    private lazy var hasLid: Bool = lidState() != nil

    private let d = UserDefaults.standard

    // MARK: Settings

    private var allowDisplaySleep: Bool {
        get { d.bool(forKey: "allowDisplaySleep") }
        set { d.set(newValue, forKey: "allowDisplaySleep") }
    }
    private var closedLidMode: Bool {
        get { d.bool(forKey: "closedLidMode") }
        set { d.set(newValue, forKey: "closedLidMode") }
    }
    private var lidOnlyOnAC: Bool {
        get { d.object(forKey: "lidOnlyOnAC") as? Bool ?? false }
        set { d.set(newValue, forKey: "lidOnlyOnAC") }
    }
    private var lockOnLidClose: Bool {
        get { d.object(forKey: "lockOnLidClose") as? Bool ?? true }
        set { d.set(newValue, forKey: "lockOnLidClose") }
    }
    /// End the session when on battery and the charge drops below this (0 = never).
    private var batteryLimit: Int {
        get { d.object(forKey: "batteryLimit") as? Int ?? 20 }
        set { d.set(newValue, forKey: "batteryLimit") }
    }
    private var startOnLaunch: Bool {
        get { d.bool(forKey: "startOnLaunch") }
        set { d.set(newValue, forKey: "startOnLaunch") }
    }
    /// True while we have `disablesleep 1` set — read by the fail-safe agent too.
    private var lidSleepDisabledByUs: Bool {
        get { d.bool(forKey: "lidSleepDisabledByUs") }
        set { d.set(newValue, forKey: "lidSleepDisabledByUs"); d.synchronize() }
    }
    private var isLidHelperInstalled: Bool { FileManager.default.fileExists(atPath: sudoersPath) }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: a second copy would undo the first one's closed-lid state.
        let me = NSRunningApplication.current
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != me.processIdentifier
        }
        if !others.isEmpty { exit(0) }

        // If we died with closed-lid sleep disabled, put it back first.
        if lidSleepDisabledByUs && !setLidSleepDisabled(false) {
            alert("Сон с закрытой крышкой всё ещё отключён",
                  "Не получилось вернуть настройку автоматически. Выполни в Терминале:\nsudo pmset -a disablesleep 0")
        }
        if isLidHelperInstalled { installFailsafeAgent() }   // repair if missing

        // On notched Macs with a crowded menu bar new items land under the notch.
        let posKey = "NSStatusItem Preferred Position bodryachok"
        if d.object(forKey: posKey) == nil { d.set(260, forKey: posKey) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "bodryachok"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.checkSafety() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            // Re-assert everything after a wake, in case anything was dropped.
            if self?.session != nil { self?.applyPowerState() }
        }

        // `kill` and logout send SIGTERM — quit cleanly so sleep settings are restored at once.
        signal(SIGTERM, SIG_IGN)
        termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource?.setEventHandler { NSApp.terminate(nil) }
        termSource?.resume()

        UNUserNotificationCenter.current().delegate = self

        if startOnLaunch {
            if let low = lowBattery() {
                lastEnd = "Автозапуск пропущен: заряд \(low)% ниже порога \(batteryLimit)%"
            } else {
                start(.indefinite)
            }
        }
        updateIcon()
        DispatchQueue.main.async { [weak self] in self?.showWelcomeOnce() }
    }

    func applicationWillTerminate(_ notification: Notification) { stop() }

    // Opening the app again (Finder, Spotlight) pops the menu under the cursor —
    // a fallback for when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        buildMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return false
    }

    // Left click opens the menu (like Amphetamine), right click / ⌃-click toggles.
    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        let quickToggle = e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true
        if quickToggle {
            session == nil ? userStart(.indefinite) : stop()
        } else {
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false

        m.addItem(disabled(statusText()))
        if session == nil, let lastEnd { m.addItem(disabled(lastEnd)) }
        if let heatNote { m.addItem(disabled(heatNote)) }
        else if let note = lidNote() { m.addItem(disabled(note)) }
        if let b = battery() {
            m.addItem(disabled("Батарея: \(b.percent)%" + (b.onBattery ? "" : ", от сети")))
        }
        m.addItem(.separator())

        if session != nil {
            m.addItem(item("Завершить сессию", #selector(stopAction)))
            m.addItem(.separator())
        }

        m.addItem(disabled(session == nil ? "Новая сессия" : "Заменить сессию"))
        m.addItem(item("Бессрочно", #selector(startIndefinitely)))
        m.addItem(submenu("Минуты", [5, 10, 15, 30, 45].map {
            let i = item("\($0) мин", #selector(startForMinutes(_:))); i.tag = $0; return i
        }))
        m.addItem(submenu("Часы", [1, 2, 3, 4, 5, 6, 8, 12, 24].map {
            let i = item(hoursTitle($0), #selector(startForMinutes(_:))); i.tag = $0 * 60; return i
        }))
        m.addItem(item("До времени…", #selector(startUntilTime)))
        m.addItem(submenu("Пока работает приложение", runningAppItems()))
        m.addItem(.separator())

        let lid = item("Не спать с закрытой крышкой", #selector(toggleClosedLid))
        lid.state = closedLidMode ? .on : .off
        lid.toolTip = "Mac продолжит работать с закрытой крышкой. Выключается сам при перегреве."
        if hasLid { m.addItem(lid) }   // desktops have no lid

        let disp = item("Разрешить сон экрана", #selector(toggleDisplaySleep))
        disp.state = allowDisplaySleep ? .on : .off
        disp.toolTip = "Экран может гаснуть и блокироваться, а сам Mac продолжает работать."
        m.addItem(disp)
        m.addItem(.separator())

        let batteryItems: [NSMenuItem] = [0, 10, 20, 30, 50].map {
            let i = item($0 == 0 ? "Никогда" : "\($0)%", #selector(setBatteryLimit(_:)))
            i.tag = $0; i.state = batteryLimit == $0 ? .on : .off; return i
        }
        var settings: [NSMenuItem] = [submenu("Завершать при заряде ниже", batteryItems)]
        let ac = item("Крышка — только от сети", #selector(toggleLidOnlyOnAC))
        ac.state = lidOnlyOnAC ? .on : .off
        ac.toolTip = "От батареи режим закрытой крышки не работает — Mac уснёт, как обычно."
        let lock = item("Блокировать экран при закрытии крышки", #selector(toggleLockOnLidClose))
        lock.state = lockOnLidClose ? .on : .off
        if hasLid { settings += [ac, lock] }
        settings.append(.separator())
        let sol = item("Включать сессию при запуске", #selector(toggleStartOnLaunch))
        sol.state = startOnLaunch ? .on : .off
        settings.append(sol)
        let login = item("Запускать при входе в систему", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        settings.append(login)
        if isLidHelperInstalled {
            settings.append(.separator())
            settings.append(item("Удалить доступ для режима крышки…", #selector(uninstallLidHelper)))
        }
        m.addItem(submenu("Настройки", settings))
        m.addItem(.separator())
        m.addItem(disabled("Правый клик по чашке — вкл/выкл"))
        m.addItem(item("Выйти", #selector(quit), key: "q"))
        return m
    }

    private func runningAppItems() -> [NSMenuItem] {
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && $0.localizedName != nil }
            .sorted { $0.localizedName!.localizedCaseInsensitiveCompare($1.localizedName!) == .orderedAscending }
        if apps.isEmpty { return [disabled("Нет открытых приложений")] }
        return apps.map { app in
            let i = item(app.localizedName!, #selector(startWhileApp(_:)))
            i.tag = Int(app.processIdentifier)
            if let icon = app.icon?.copy() as? NSImage { icon.size = NSSize(width: 16, height: 16); i.image = icon }
            return i
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }
    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }
    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let s = NSMenu(); s.autoenablesItems = false
        items.forEach { s.addItem($0) }
        i.submenu = s
        return i
    }
    private func hoursTitle(_ h: Int) -> String {
        let n = h % 100, l = h % 10
        if (11...14).contains(n) { return "\(h) часов" }
        if l == 1 { return "\(h) час" }
        if (2...4).contains(l) { return "\(h) часа" }
        return "\(h) часов"
    }

    // MARK: Actions

    @objc private func stopAction() { stop() }
    @objc private func startIndefinitely() { userStart(.indefinite) }
    @objc private func startForMinutes(_ s: NSMenuItem) { userStart(.forMinutes(s.tag)) }
    @objc private func startWhileApp(_ s: NSMenuItem) { userStart(.whileApp(pid_t(s.tag), s.title)) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func setBatteryLimit(_ s: NSMenuItem) { batteryLimit = s.tag }
    @objc private func toggleStartOnLaunch() { startOnLaunch.toggle() }
    @objc private func toggleLockOnLidClose() { lockOnLidClose.toggle() }

    @objc private func toggleLidOnlyOnAC() {
        lidOnlyOnAC.toggle()
        if session != nil { syncLidState() }
    }

    @objc private func toggleDisplaySleep() {
        allowDisplaySleep.toggle()
        if session != nil { applyPowerState() }
    }

    @objc private func toggleClosedLid() {
        if closedLidMode {
            closedLidMode = false
        } else {
            guard isLidHelperInstalled || installLidHelper() else { return }
            installFailsafeAgent()
            closedLidMode = true
            lidBlockedByHeat = false
            // The lid mode only works during a session — start one so the tick isn't a no-op.
            if session == nil { userStart(.indefinite); return }
        }
        if session != nil { syncLidState(); updateIcon() }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Не получилось изменить автозапуск", error.localizedDescription)
        }
    }

    @objc private func startUntilTime() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Не давать засыпать до:"
        a.addButton(withTitle: "Старт")
        a.addButton(withTitle: "Отмена")
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.dateValue = Date().addingTimeInterval(3600)
        a.accessoryView = picker
        guard a.runModal() == .alertFirstButtonReturn else { return }
        // Picked hour:minute; if it has already passed today, use tomorrow.
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: picker.dateValue)
        guard let target = cal.nextDate(after: Date(), matching: comps, matchingPolicy: .nextTime) else { return }
        userStart(.until(target))
    }

    // MARK: Session

    /// Battery percent if we're on battery below the limit, else nil.
    private func lowBattery() -> Int? {
        guard batteryLimit > 0, let b = battery(), b.onBattery, b.percent < batteryLimit else { return nil }
        return b.percent
    }

    /// A start requested by the user: explain a low battery instead of silently ending.
    private func userStart(_ s: Session) {
        var ignore = false
        if let low = lowBattery() {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Заряд \(low)% — ниже порога \(batteryLimit)%"
            a.informativeText = """
            При таком заряде «Бодрячок» сам завершает сессию, чтобы не посадить батарею в ноль.

            Если запустить всё равно, до конца этой сессии порог действовать не будет — Mac может \
            разрядиться полностью. Порог меняется в «Настройки → Завершать при заряде ниже».
            """
            a.addButton(withTitle: "Запустить всё равно")
            a.addButton(withTitle: "Отмена")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            ignore = true
        }
        // Durations count from the moment the user confirms, not from the click.
        if case .forMinutes(let m) = s {
            start(.until(Date().addingTimeInterval(TimeInterval(m * 60))), ignoreBattery: ignore)
        } else {
            start(s, ignoreBattery: ignore)
        }
    }

    private func start(_ s: Session, ignoreBattery: Bool = false) {
        session = s
        ignoreBatteryLimit = ignoreBattery
        lastEnd = nil
        heatNote = nil
        requestNotificationPermissionOnce()
        lidBlockedByHeat = false
        lidWasClosed = isLidClosed()
        applyPowerState()
        timer?.invalidate()
        ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)   // keep counting while the menu is open
        checkSafety()
        updateIcon()
    }

    /// `reason` is set when the session ends on its own; a manual stop passes nil.
    private func stop(reason: String? = nil) {
        if let reason, session != nil {
            lastEnd = "Сессия завершена в \(clock()): \(reason)"
            notify("Сессия завершена", reason.prefix(1).uppercased() + reason.dropFirst() + " — Mac снова может спать.")
        } else {
            lastEnd = nil
        }
        session = nil
        timer?.invalidate()
        timer = nil
        applyPowerState()
        updateIcon()
    }

    private func tick() {
        ticks += 1
        switch session {
        case .until(let end) where end <= Date():
            stop(reason: "время вышло"); return
        case .whileApp(let pid, let name):
            let app = NSRunningApplication(processIdentifier: pid)
            if app == nil || app!.isTerminated { stop(reason: "приложение «\(name)» закрылось"); return }
        default: break
        }
        if lidSleepDisabledByUs { checkLidLock() }
        if ticks % 5 == 0 { checkSafety() }
        if session == nil { return }
        if ticks % 30 == 0 && !allowDisplaySleep { declareUserActivity() }
        updateIcon()
    }

    /// Heat, battery and power-source checks. Safe to call any time.
    private func checkSafety() {
        guard session != nil else { return }
        if !ignoreBatteryLimit, lowBattery() != nil {
            stop(reason: "заряд ниже \(batteryLimit)%")
            return
        }
        let thermal = ProcessInfo.processInfo.thermalState
        if lidSleepDisabledByUs && !lidBlockedByHeat && (thermal == .serious || thermal == .critical) {
            lidBlockedByHeat = true
            heatNote = "Крышка: выключено в \(clock()) из-за перегрева"
            notify("Mac перегревается",
                   "Режим закрытой крышки выключен до конца сессии — с закрытой крышкой Mac теперь уснёт.")
        }
        syncLidState()
    }

    /// Lock the screen the moment the lid closes while we keep the Mac awake.
    private func checkLidLock() {
        let closed = isLidClosed()
        if closed && !lidWasClosed && lockOnLidClose { lockScreen() }
        lidWasClosed = closed
    }

    /// Brings assertions and closed-lid state in line with the current session + settings.
    private func applyPowerState() {
        releaseAssertions()
        if session != nil {
            let reason = "Bodryachok keeps Mac awake" as CFString
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &systemAssertion)
            if !allowDisplaySleep {
                // Display assertion also keeps the screen saver and idle lock screen away.
                IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &displayAssertion)
                declareUserActivity()
            }
        }
        syncLidState()
    }

    /// Whether `disablesleep` should be on right now, given every safety rule.
    private var wantLidSleepDisabled: Bool {
        guard session != nil, closedLidMode, isLidHelperInstalled, !lidBlockedByHeat else { return false }
        if lidOnlyOnAC, battery()?.onBattery == true { return false }
        return true
    }

    private func syncLidState() {
        let want = wantLidSleepDisabled
        guard want != lidSleepDisabledByUs else { return }
        if setLidSleepDisabled(want) { lidFailureShown = false; updateIcon(); return }
        // This runs every few seconds — show the failure once, not in a loop.
        if lidFailureShown && !want { return }
        lidFailureShown = true
        if want {
            closedLidMode = false
            alert("Режим закрытой крышки не включился",
                  "Не удалось выполнить pmset. Удали доступ в Настройках и включи режим снова.")
        } else {
            alert("Не получилось вернуть сон с закрытой крышкой",
                  "Выполни в Терминале:\nsudo pmset -a disablesleep 0")
        }
    }

    private func declareUserActivity() {
        IOPMAssertionDeclareUserActivity("Bodryachok keeps Mac awake" as CFString, kIOPMUserActiveLocal, &userActivityAssertion)
    }

    private func releaseAssertions() {
        for id in [systemAssertion, displayAssertion, userActivityAssertion] where id != 0 { IOPMAssertionRelease(id) }
        systemAssertion = 0; displayAssertion = 0; userActivityAssertion = 0
    }

    // MARK: Lid sensor & screen lock

    /// nil on Macs without a lid (desktops).
    private func lidState() -> Bool? {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IOPower:/IOPowerConnection/IOPMrootDomain")
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return v as? Bool
    }

    private func isLidClosed() -> Bool { lidState() ?? false }

    private func lockScreen() {
        // Same call the  → «Заблокировать экран» menu uses; falls back to display sleep,
        // which locks when a password is required after sleep (macOS default).
        typealias LockFn = @convention(c) () -> Void
        if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let sym = dlsym(h, "SACLockScreenImmediate") {
            unsafeBitCast(sym, to: LockFn.self)()
        } else {
            _ = run(pmset, ["displaysleepnow"])
        }
    }

    // MARK: Closed-lid mode (pmset disablesleep)

    @discardableResult
    private func setLidSleepDisabled(_ on: Bool) -> Bool {
        let ok = run("/usr/bin/sudo", ["-n", pmset, "-a", "disablesleep", on ? "1" : "0"])
        if ok {
            lidSleepDisabledByUs = on
            if on { startWatchdog(); lidWasClosed = isLidClosed() }
        }
        return ok
    }

    /// If the app dies while the lid mode is on, a tiny detached shell puts sleep back within seconds.
    private func startWatchdog() {
        guard !watchdogStarted else { return }
        watchdogStarted = true
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", """
            while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 3; done
            [ "$(/usr/bin/defaults read \(bundleID) lidSleepDisabledByUs 2>/dev/null)" = "1" ] || exit 0
            /usr/bin/sudo -n \(pmset) -a disablesleep 0 && /usr/bin/defaults write \(bundleID) lidSleepDisabledByUs -bool false
            """]
        try? p.run()
    }

    /// Login agent: every minute (and at login, so also after a reboot) it restores sleep
    /// if we left it disabled and the app is no longer running. Runs as the user, can only
    /// call the one pmset command the sudoers rule allows.
    private func installFailsafeAgent() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let supportDir = home.appendingPathComponent("Library/Application Support/Bodryachok")
        let script = supportDir.appendingPathComponent("failsafe.sh")
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
        let scriptBody = """
        #!/bin/sh
        # Бодрячок fail-safe: возвращает сон, если приложение умерло с pmset disablesleep 1.
        [ "$(/usr/bin/defaults read \(bundleID) lidSleepDisabledByUs 2>/dev/null)" = "1" ] || exit 0
        /usr/bin/pgrep -qx Bodryachok && exit 0
        /usr/bin/sudo -n \(pmset) -a disablesleep 0 && /usr/bin/defaults write \(bundleID) lidSleepDisabledByUs -bool false

        """
        let plistBody: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/bin/sh", script.path],
            "RunAtLoad": true,
            "StartInterval": 60,
            "ProcessType": "Background",
        ]
        do {
            try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            let unchanged = (try? String(contentsOf: script, encoding: .utf8)) == scriptBody && fm.fileExists(atPath: plist.path)
            try scriptBody.write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let data = try PropertyListSerialization.data(fromPropertyList: plistBody, format: .xml, options: 0)
            try data.write(to: plist, options: .atomic)
            let domain = "gui/\(getuid())"
            let loaded = run("/bin/launchctl", ["print", "\(domain)/\(agentLabel)"])
            if loaded && unchanged { return }
            if loaded { _ = run("/bin/launchctl", ["bootout", "\(domain)/\(agentLabel)"]) }
            _ = run("/bin/launchctl", ["bootstrap", domain, plist.path])
        } catch {
            NSLog("Bodryachok: fail-safe agent install failed: \(error)")
        }
    }

    private func removeFailsafeAgent() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"])
        try? FileManager.default.removeItem(at: home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist"))
        try? FileManager.default.removeItem(at: home.appendingPathComponent("Library/Application Support/Bodryachok"))
    }

    private func installLidHelper() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Режим закрытой крышки"
        a.informativeText = """
        Чтобы Mac не засыпал с закрытой крышкой, «Бодрячку» нужно один раз получить право \
        выполнять ровно одну системную команду — pmset disablesleep 0/1. macOS попросит пароль администратора.

        Защита: режим сам выключится при перегреве или низком заряде, \
        а экран блокируется сразу при закрытии крышки. Всё равно не клади работающий ноутбук в сумку.
        """
        a.addButton(withTitle: "Разрешить")
        a.addButton(withTitle: "Отмена")
        guard a.runModal() == .alertFirstButtonReturn else { return false }

        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            alert("Не получилось", "Необычное имя пользователя: \(user)"); return false
        }
        let rule = "\(user) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 0, \(pmset) -a disablesleep 1"
        let script = """
        T=$(/usr/bin/mktemp) && /usr/bin/printf '%s\\n' '\(rule)' > "$T" && /usr/sbin/visudo -cf "$T" >/dev/null \
        && /usr/bin/install -m 0440 -o root -g wheel "$T" \(sudoersPath); R=$?; /bin/rm -f "$T"; exit $R
        """
        guard runAsAdmin(script) else { return false }
        if run("/usr/bin/sudo", ["-n", pmset, "-a", "disablesleep", "0"]) { return true }
        alert("Не получилось", "Правило установлено, но sudo его не принимает.")
        return false
    }

    @objc private func uninstallLidHelper() {
        if lidSleepDisabledByUs { _ = setLidSleepDisabled(false) }
        if runAsAdmin("/bin/rm -f \(sudoersPath)") {
            closedLidMode = false
            removeFailsafeAgent()
            if session != nil { applyPowerState() }
        }
    }

    private func runAsAdmin(_ shell: String) -> Bool {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"«Бодрячок» хочет управлять сном Mac с закрытой крышкой.\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err, (err[NSAppleScript.errorNumber] as? Int) != -128 {   // -128 = user cancelled
            alert("Не получилось", (err[NSAppleScript.errorMessage] as? String) ?? "\(err)")
        }
        return err == nil
    }

    private func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: Battery

    private func battery() -> (percent: Int, onBattery: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onBattery = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            return (cur * 100 / max, onBattery)
        }
        return nil
    }

    // MARK: Status UI

    private func remaining() -> String? {
        guard case .until(let end) = session else { return nil }
        let s = max(0, Int(end.timeIntervalSinceNow.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    private func statusText() -> String {
        guard let session else { return "Выключено — Mac может спать" }
        var t: String
        switch session {
        case .indefinite: t = "Активно бессрочно"
        case .until: t = "Активно, осталось \(remaining() ?? "")"
        case .whileApp(_, let name): t = "Активно, пока открыто «\(name)»"
        case .forMinutes: t = "Активно"   // never stored: start() turns it into .until
        }
        if allowDisplaySleep { t += " · экран может гаснуть" }
        return t
    }

    /// Explains the closed-lid state when it's on in settings.
    private func lidNote() -> String? {
        guard closedLidMode, session != nil else { return nil }
        if lidSleepDisabledByUs { return "Крышку можно закрывать" }
        if lidBlockedByHeat { return "Крышка: выключено из-за перегрева" }
        if lidOnlyOnAC, battery()?.onBattery == true { return "Крышка: ждёт зарядку" }
        return "Крышка: не активно"
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let symbol = session != nil ? "cup.and.saucer.fill" : "cup.and.saucer"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Бодрячок")
        img?.isTemplate = true
        button.image = img
        button.imagePosition = .imageLeft
        var title: String
        switch session {
        case nil: title = ""
        case .until: title = " " + (remaining() ?? "")
        case .whileApp: title = " ▸"
        case .forMinutes: title = ""
        case .indefinite: title = " ∞"
        }
        if lidSleepDisabledByUs { title += " ⌄" }   // lid mode is live
        button.title = title
        button.toolTip = statusText() + (lidNote().map { "\n" + $0 } ?? "")
    }

    // MARK: Messages

    private func clock() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }

    /// Ask for notifications while the user is at the Mac, not when the lid is already shut.
    private func requestNotificationPermissionOnce() {
        guard !d.bool(forKey: "askedNotifications") else { return }
        d.set(true, forKey: "askedNotifications")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // Show our banners even when one of our own alerts made the app frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// First launch: the app has no window, so say where it lives.
    private func showWelcomeOnce() {
        guard !d.bool(forKey: "welcomed") else { return }
        d.set(true, forKey: "welcomed")
        alert("Бодрячок запущен", """
        Он живёт в меню-баре: ищи чашку справа вверху.

        • Левый клик — меню: сессии на время, режим закрытой крышки, настройки.
        • Правый клик — быстро включить или выключить.

        Если чашку не видно (её может закрыть вырез камеры), просто открой «Бодрячок» ещё раз — \
        меню появится под курсором.
        """)
    }

    private func notify(_ title: String, _ body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { DispatchQueue.main.async { NSSound.beep() }; return }
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body; c.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
