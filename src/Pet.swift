import Cocoa
import WebKit
import Carbon.HIToolbox

// MARK: - Desktop pet

/// A pixel pet that lives in the top-right corner and treats the screen as a little world. It flies
/// out to the tops of your windows and walks along them, rides a window while you drag it, falls when
/// that window closes, and is covered by any window in front of the one it's standing on. It hides
/// behind window edges, desktop folders and the Dock, watches the cursor, can be picked up and
/// dropped, hops along the Dock and the folders on your desktop, eats files you drag into its mouth
/// (they go to the Trash), notices folders you open and the app you're in, and gets sleepier as the
/// plan's usage runs out. It dozes off when you go quiet, says hello when you come back (good morning on
/// a new day), and hints at bedtime late at night. Tapping it shows the usage stats. The behaviour lives
/// here; pet.html only draws it.
final class Pet: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    enum Layer: Equatable { case top, on(window: Int), onDesktop, onDock, behind(window: Int), underIcons, underDock }
    enum Gait: String { case walk, run, sneak }
    enum Side: String { case left = "peek-l", right = "peek-r", top = "peek-t" }
    enum AppKind { case music, call, code, other }

    /// Somewhere to stand: a window's top edge, the floor above the Dock (id 0), a Dock icon or a
    /// folder on the desktop. Icons get negative ids.
    struct Surface {
        enum Kind { case floor, window, dockIcon, desktopIcon }
        var id: Int; var minX: CGFloat; var maxX: CGFloat; var y: CGFloat; var kind: Kind = .window
        var isIcon: Bool { kind == .dockIcon || kind == .desktopIcon }
    }

    /// A Dock tile or a desktop folder, with what it's called.
    private struct Icon { let id: Int; let rect: CGRect; let name: String }

    struct Spot {
        var center: NSPoint    // body centre while hidden
        var approach: NSPoint  // a fully visible spot next to it, where it sneaks in from
        var side: Side
        var layer: Layer
        var window: CGRect?    // the window it's behind, to notice when that window moves
        var cover: CGRect?     // the icon or Dock in front of it
    }

    enum Step {
        case walk(to: NSPoint, speed: CGFloat, gait: Gait)  // straight line, for sneaking in and out of hiding
        case fly(to: NSPoint)
        case flyOnto(window: Int, at: CGFloat)  // above a spot on a window's top edge (0...1 across), following it
        case flyHome
        case fall
        case jump(to: NSPoint)       // where its feet land on another surface
        case stroll(TimeInterval)    // potter about on whatever it's standing on
        case carried
        case feed                    // mouth open for a file you're dragging over
        case focus                   // at its desk, working alongside you
        case nap                     // dozing where it stands because nobody's touched anything for a while
        case chase
        case wait(TimeInterval)
        case react(String, TimeInterval)
        case layer(Layer)
        case hide(Spot, TimeInterval)
        case settle
    }

    private struct Win {
        let id: Int, rect: CGRect, layer: Int, alpha: Double, pid: pid_t
        var isNormal: Bool { layer == 0 && alpha > 0.05 }
    }

    /// Wide enough for its speech bubbles; everything but the body lets clicks through.
    private static let size = NSSize(width: 260, height: 130)
    /// Body centre relative to the window origin; the 34×34 body box matches #pet in pet.html.
    private static let anchor = NSPoint(x: 130, y: 23)
    private static let half: CGFloat = 17
    /// The bedroom window, and where in it the sleeper's head lies (matches the bed art in pet.html).
    private static let bedSize = NSSize(width: 80, height: 66)
    private static let pillow = NSPoint(x: 45, y: 21)
    private static let awakeFor: TimeInterval = 300
    /// No mouse or keys for this long counts as away; when you come back, it says hello.
    private static let awayAfter: TimeInterval = 600
    /// Out and about with nobody touching anything for this long, it dozes off where it is.
    private static let napAfter: TimeInterval = 120

    private let panel: NSPanel
    private let root: NSView
    /// An all-but-invisible window over the open mouth that takes the file drop. The pet's own window
    /// lets clicks through most of the time, and macOS doesn't offer drops to windows like that.
    private let catcher: NSPanel
    private let mouth: PetDropView
    private let web: WKWebView
    /// Its bed in the top-right corner. It sleeps there until you click it.
    private let bed: NSPanel
    private let bedWeb: WKWebView
    private var bedReady = false
    private let mask = CAShapeLayer()
    private let home: () -> NSPoint
    private let myPid = ProcessInfo.processInfo.processIdentifier
    private var ready = false
    private var lastTick = Date()

    // What it's doing
    private var pos = NSPoint.zero
    private var plan: [Step] = []
    private var stepStart: Date?
    private var reactDone = false
    private var atHome = true
    private var layer: Layer = .top
    private var hiding: Spot?
    private var standing: Surface?
    private var standingRect = CGRect.zero
    private var vy: CGFloat = 0
    private var jumpFrom = NSPoint.zero
    private var strollUntil: Date?
    private var strollTarget: CGFloat?
    private var strollRest = Date.distantPast
    private var moved = false
    // Asleep in bed, or up for a while after you woke it
    private var inBed = true
    private var awakeSince = Date.distantPast
    private var awakeUntil = Date.distantPast
    private var shown = true
    private var saidGoodnight = false
    // A focus session: it sits at a little desk and works with you until the time's up
    private var focus: (start: Date, end: Date)?
    private var lastFocusSent = Date.distantPast
    // Whether you're at the computer, and the time of day
    private var lastActive = Date()            // your latest mouse or key input that it knows about
    private var lastPresence = Date.distantPast
    private var lastActiveSaved = Date.distantPast
    private lazy var seenDay = UserDefaults.standard.string(forKey: "lastSeenDay") ?? ""
    private var lastNudge = Date.distantPast   // the last "it's late" hint
    private var sky = ""

    // The screen around it
    private var world: [Win] = []
    private var lastWorld = Date.distantPast
    private var fastWorldUntil = Date.distantPast
    private var occluders: [CGRect] = []   // windows drawn in front of it, cut out of the sprite
    private var lastSpotCheck = Date.distantPast
    private var icons: [CGRect] = []
    private var iconsRead = Date.distantPast
    private var finderIDs: Set<Int>?
    private var folderNames: [Int: String] = [:]  // Finder windows' titles, and icon names, by surface id
    private var finderPid: (pid_t?, Date) = (nil, .distantPast)
    private var lastNotice = Date.distantPast
    private var lastDance = Date.distantPast
    private var quiet = false

    // The cursor
    private var hoverSince: Date?
    private var hoverAboveSince: Date?
    private var near = false
    private var sentMode = "sit"
    private var sentLook = (0, 0)
    private var rubXs: [(Date, CGFloat)] = []
    private var lastRub = Date.distantPast, lastStartle = Date.distantPast, lastCatch = Date.distantPast
    private var catchesForThisSpot = 0
    private var stillMouse = (NSPoint.zero, Date())
    private var pressStart: NSPoint?
    private var pressMonitor: Any?
    private var clickMonitor: Any?
    private var carrying = false
    private var shakeSamples: [(Date, NSPoint)] = []
    private var shakeLevel = 0
    private var shakenFor: TimeInterval = 0

    // Feeding: a file drag from another app, and how wide the mouth is open (0 shut ... 3 gaping)
    private var dragMonitor: Any?
    private var dragBase = NSPasteboard(name: .drag).changeCount
    private var fileDrag = false
    private var dragEnded: Date?  // the button came up; the drop itself lands a moment later
    private var snackDrag = -1    // the drag it already got up for, so it doesn't pop in and out
    private var gape = 0

    // Icons to hop on
    private var dockIcons: ([Icon], Date) = ([], .distantPast)
    private var desktopFolders: [Icon] = []

    #if DEBUG
    fileprivate var history: [String] = []
    fileprivate var fakeMouse: NSPoint?
    fileprivate var fakeLastInput: Date?
    fileprivate var fakeHour: Int?
    fileprivate var homeOverride: NSPoint?
    private var mouse: NSPoint { fakeMouse ?? NSEvent.mouseLocation }
    #else
    private var mouse: NSPoint { NSEvent.mouseLocation }
    #endif

    private(set) var energy = 0.7
    private var theme = "bubblegum"
    private var gear = ""
    private var topLevel: NSWindow.Level = .floating
    private var roams = true
    private var interactive = true

    /// Called with its body's frame when it's tapped, so the stats can pop up next to it.
    var onTap: ((NSRect) -> Void)?
    /// A window that travels beside it while it's showing (the stats pill).
    weak var companion: NSWindow?

    init(home: @escaping () -> NSPoint) {
        self.home = home
        let config = WKWebViewConfiguration()
        panel = PetPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        root = NSView(frame: NSRect(origin: .zero, size: Self.size))
        catcher = PetPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        mouth = PetDropView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        web = OverlayWebView(frame: NSRect(origin: .zero, size: Self.size), configuration: config)
        let bedConfig = WKWebViewConfiguration()
        bed = PetPanel(contentRect: NSRect(origin: .zero, size: Self.bedSize), styleMask: [.borderless, .nonactivatingPanel],
                       backing: .buffered, defer: false)
        bedWeb = OverlayWebView(frame: NSRect(origin: .zero, size: Self.bedSize), configuration: bedConfig)
        super.init()
        // When you were last here, so a morning after the app was quit still gets a hello.
        let saved = UserDefaults.standard.double(forKey: "lastActive")
        if saved > 0 { lastActive = Date(timeIntervalSince1970: saved) }
        config.userContentController.add(self, name: "pet")
        bedConfig.userContentController.add(self, name: "bed")

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        root.wantsLayer = true
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        root.addSubview(web)
        panel.contentView = root

        let page = Bundle.main.url(forResource: "pet", withExtension: "html")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("pet.html")
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())

        bed.isOpaque = false
        bed.backgroundColor = .clear
        bed.hasShadow = false
        bed.hidesOnDeactivate = false
        bed.isReleasedWhenClosed = false
        bed.collectionBehavior = panel.collectionBehavior
        bedWeb.setValue(false, forKey: "drawsBackground")
        bedWeb.underPageBackgroundColor = .clear
        bedWeb.navigationDelegate = self
        bedWeb.autoresizingMask = [.width, .height]
        bed.contentView = bedWeb
        if let bedPage = URL(string: page.absoluteString + "?bed") {
            bedWeb.loadFileURL(bedPage, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        placeBed()
        bed.level = topLevel
        bed.orderFrontRegardless()

        // It starts asleep in bed: its own window stays hidden and the bed shows it tucked in.
        place(homeCenter)
        panel.level = topLevel

        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(goHomeNow), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(goHomeNow), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Mouse clicks in other apps need no permission to watch (keys would).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.mouseDownElsewhere() }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] e in self?.draggedElsewhere(e) }
        // Faintly filled: the window server skips fully transparent pixels when it looks for a drop target.
        catcher.isOpaque = false
        catcher.backgroundColor = NSColor(white: 1, alpha: 0.012)
        catcher.hasShadow = false
        catcher.hidesOnDeactivate = false
        catcher.isReleasedWhenClosed = false
        catcher.collectionBehavior = panel.collectionBehavior
        catcher.contentView = mouth
        mouth.registerForDraggedTypes([.fileURL])
        mouth.canEat = { [weak self] in (self?.gape ?? 0) >= 2 }
        mouth.eat = { [weak self] urls in self?.dropped(urls) ?? false }
        mouth.log = { [weak self] line in self?.feedLog(line) }
        askForDockAccess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.readIcons()
            self?.readFolderNames()
        }
        #if DEBUG
        listenForDebugCommands()
        #endif
    }

    // MARK: Outside controls

    func apply(theme: String, level: NSWindow.Level, opacity: CGFloat, ghost: Bool, roams: Bool, shown: Bool) {
        topLevel = level
        if layer == .top || isMasked { panel.level = level }
        bed.level = level
        panel.alphaValue = opacity
        bed.alphaValue = opacity
        interactive = !ghost
        bed.ignoresMouseEvents = ghost
        if self.roams && !roams && !inBed { comeHome() }
        self.roams = roams
        self.theme = theme
        js("P.theme('\(theme)')")
        bedJS("B.theme('\(theme)')")
        self.shown = shown
        if shown {
            bed.orderFrontRegardless()
            if !inBed { panel.orderFrontRegardless() }
        } else {
            panel.orderOut(nil)
            bed.orderOut(nil)
            hideCatcher()
        }
    }

    var isShown: Bool { shown }

    /// Session % left (or weekly, whichever is lower), 0...1.
    func setEnergy(_ e: Double) {
        let old = energy
        energy = max(0, min(1, e))
        js("P.energy(\(energy))")
        // A fresh session while it's up: a big stretch.
        if old < 0.5, energy - old > 0.3, !inBed, plan.isEmpty { plan = [.react("wake", 3)] }
    }

    /// Flies to the cursor and says hi. From bed, that counts as waking it.
    func call() {
        guard shown else { return }
        if inBed { wakeUp() }
        leaveHome()
        endHiding()
        strollUntil = nil
        plan = [.layer(.top), .react("called", 1), .chase, .react("greet", 2.4), .wait(1.5), .flyHome, .settle]
        stepStart = nil
    }

    // MARK: Bed

    private var awake: Bool { Date() < awakeUntil }

    /// How interested it is in the desktop, from 0 (just dragged out of bed) to 1 (a few minutes in).
    private var curiosity: Double { min(1, max(0, Date().timeIntervalSince(awakeSince) / 200)) }

    /// The top-right corner it calls home (debug builds can move it, for filming).
    private var corner: NSPoint {
        #if DEBUG
        if let h = homeOverride { return h }
        #endif
        return home()
    }

    private func placeBed() {
        bed.setFrameOrigin(NSPoint(x: corner.x - Self.bedSize.width - 4, y: corner.y - Self.bedSize.height - 2))
    }

    private func bedJS(_ code: String) { if bedReady { bedWeb.evaluateJavaScript(code) } }

    private func bedClicked() {
        if inBed { return wakeUp(grumbling: true) }
        guard focus == nil else { return }  // busy at its desk
        if !awake, atHome, !isCarried {
            // Sitting up in bed to say something: a click gets it up properly, happily this time.
            wakeUp()
            let edge = NSPoint(x: bed.frame.minX + 6, y: pos.y)
            plan = [.react("greet", 2.4), .walk(to: edge, speed: 18, gait: .walk), .fall]
            stepStart = nil
            return
        }
        // Clicking the empty bed while it's out: time to come back.
        guard awake, !isCarried else { return }
        awakeUntil = Date()
        if case .react? = plan.first { plan = [plan[0]] } else { plan = [] }
        stepStart = nil
    }

    /// Up for a few minutes: it sits up on the bed, grumbles, and gets off.
    private func wakeUp(grumbling: Bool = false) {
        inBed = false
        atHome = false
        saidGoodnight = false
        awakeSince = Date()
        awakeUntil = Date().addingTimeInterval(Self.awakeFor)
        bedJS("B.occupied(false)")
        place(homeCenter)
        setLayer(.top)
        setMode("sit")
        js("P.home(false)")
        if shown {
            panel.orderFrontRegardless()
            // Clicking the bed brings the bed's window forward a moment later, which would hide it
            // behind its own blanket while it grumbles: step back in front.
            for delay in [0.2, 0.6] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, !self.inBed, self.shown else { return }
                    self.panel.orderFrontRegardless()
                }
            }
        }
        guard grumbling else { return }
        // Out of bed the slow way: grumble, shuffle to the edge, drop off.
        let edge = NSPoint(x: bed.frame.minX + 6, y: pos.y)
        plan = [.react("grumpy", 3.2), .walk(to: edge, speed: 18, gait: .walk), .fall]
        stepStart = nil
    }

    /// Climbs in: its own window goes away and the bed shows it asleep.
    private func goToBed() {
        endHiding()
        hideCatcher()
        standing = nil
        setLayer(.top)
        inBed = true
        atHome = true
        saidGoodnight = false
        place(homeCenter)
        setMode("sit")
        panel.orderOut(nil)
        bedJS("B.occupied(true)")
    }

    // MARK: Focus sessions

    var isFocusing: Bool { focus != nil }

    /// Sits down at its desk (bottom-right, above the Dock) and works alongside you. Its flower opens
    /// and the dots on its desk fill as the time goes by.
    func startFocus(minutes: Int) {
        guard shown else { return }
        let now = Date()
        focus = (now, now.addingTimeInterval(TimeInterval(minutes * 60)))
        if inBed { wakeUp() }
        awakeUntil = now.addingTimeInterval(TimeInterval(minutes * 60) + Self.awakeFor)  // plus a play break after
        leaveHome()
        endHiding()
        strollUntil = nil
        // Far enough from the edge that its speech bubbles stay on screen.
        let desk = NSPoint(x: homeArea.maxX - 100, y: homeArea.minY + Self.half)
        plan = [.layer(.top), .react("focusStart:\(minutes)", 1.9), .fly(to: NSPoint(x: desk.x, y: desk.y + 40)), .fall, .focus]
        stepStart = nil
        sendFocus()
    }

    /// Stopping early is fine: it says well done for what you did, then heads to bed soon.
    func endFocus() {
        guard let f = focus else { return }
        let minutes = Int(Date().timeIntervalSince(f.start) / 60)
        focus = nil
        js("P.focus(null)")
        awakeUntil = Date().addingTimeInterval(60)
        plan = [.react("focusStop:\(minutes)", 2.4)]
        stepStart = nil
    }

    /// The shortcut: start a 25-minute session, or, mid-session, say how long is left.
    func focusKey() {
        if focus != nil { interject("focusLeft:\(minutesLeft)", 2.4) } else { startFocus(minutes: 25) }
    }

    /// Time's up: a big bloom, how many you've done today, then it plays while you take a break.
    private func finishFocus() {
        focus = nil
        js("P.focus(null)")
        awakeSince = Date().addingTimeInterval(-200)  // curious straight away
        awakeUntil = Date().addingTimeInterval(Self.awakeFor)
        plan = [.react("focusDone:\(countFocusToday())", 3.8)]
        stepStart = nil
    }

    private func sendFocus() {
        guard let f = focus else { return }
        lastFocusSent = Date()
        let progress = min(1, max(0, Date().timeIntervalSince(f.start) / f.end.timeIntervalSince(f.start)))
        js("P.focus(\(progress))")
    }

    private var minutesLeft: Int { focus.map { max(1, Int(ceil($0.end.timeIntervalSinceNow / 60))) } ?? 0 }

    /// Sessions finished today, this one included.
    private func countFocusToday() -> Int {
        let d = UserDefaults.standard
        let today = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        let count = (d.string(forKey: "focusDay") == today ? d.integer(forKey: "focusCount") : 0) + 1
        d.set(today, forKey: "focusDay")
        d.set(count, forKey: "focusCount")
        return count
    }

    // MARK: Noticing you, and the time of day

    /// Seconds since your last mouse move, click or key press, in any app. Needs no permission.
    private var idleSeconds: TimeInterval {
        #if DEBUG
        if let f = fakeLastInput { return Date().timeIntervalSince(f) }
        #endif
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private var hour: Int {
        #if DEBUG
        if let h = fakeHour { return h }
        #endif
        return Calendar.current.component(.hour, from: Date())
    }

    private var isLate: Bool { hour >= 23 || hour < 4 }

    /// Once a second: did you just come back, have you gone quiet, is it late?
    private func checkPresence(_ now: Date) {
        // Not before both pages can show a hello, or it would be lost.
        guard ready, bedReady, now.timeIntervalSince(lastPresence) >= 1 else { return }
        lastPresence = now
        let idle = idleSeconds
        let latest = now.addingTimeInterval(-idle)
        if latest.timeIntervalSince(lastActive) > 0.5 {
            // You just did something. The gap since the last thing is how long you were gone
            // (the Mac sleeping overnight counts too, since this timer stops while it sleeps).
            let gap = latest.timeIntervalSince(lastActive)
            lastActive = latest
            if now.timeIntervalSince(lastActiveSaved) > 30 {
                lastActiveSaved = now
                UserDefaults.standard.set(lastActive.timeIntervalSince1970, forKey: "lastActive")
            }
            let newDay = firstTimeToday(now)
            if gap >= Self.awayAfter { cameBack(after: gap, newDay: newDay) }
        }
        updateSky()
        guard shown else { return }
        if idle >= Self.napAfter { maybeNap() }
        if idle < 3 { maybeNudge(now) }
    }

    /// True the first time you're here on a new day. Days turn over at 4am, so a late night still
    /// counts as the day before.
    private func firstTimeToday(_ now: Date) -> Bool {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now.addingTimeInterval(-4 * 3600))
        let key = "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
        guard key != seenDay else { return false }
        seenDay = key
        UserDefaults.standard.set(key, forKey: "lastSeenDay")
        return true
    }

    /// You're back. A short break gets a little wave; hours away get a big hello; the first time
    /// on a new morning gets a stretch and a good morning.
    private func cameBack(after gap: TimeInterval, newDay: Bool) {
        lastNudge = max(lastNudge, Date().addingTimeInterval(-40 * 60))  // no "it's late" straight after hello
        guard shown else { return }
        let kind = newDay && (4..<12).contains(hour) ? "morning"
            : newDay || gap >= 3 * 3600 ? "big" : gap >= 1800 ? "mid" : "small"
        let t: TimeInterval = kind == "small" ? 2.2 : kind == "mid" ? 2.8 : 4.6
        if focus != nil { return interject("welcome:focus", 2.4) }
        if inBed {
            // From bed, a short break only makes it stir; a long one, it sits up to say hello.
            return kind == "small" ? bedJS("B.stir()") : sitUp("welcome:\(kind)", t)
        }
        if case .nap? = plan.first { plan.removeFirst() }
        interject("welcome:\(kind)", t)
    }

    /// Sits up in bed for a moment without getting up, says its piece, and lies back down.
    private func sitUp(_ name: String, _ t: TimeInterval) {
        guard inBed else { return }
        inBed = false
        atHome = true
        saidGoodnight = true  // straight back to sleep afterwards, without the bedtime yawn
        bedJS("B.occupied(false)")
        place(homeCenter)
        setLayer(.top)
        setMode("sit")
        js("P.home(true)")
        plan = [.react(name, t), .settle]
        stepStart = nil
        if shown { panel.orderFrontRegardless() }
    }

    /// Nobody's touched anything for a couple of minutes: it looks round for you, then dozes off
    /// where it is. Never at its desk, where you might just be reading or writing on paper.
    private func maybeNap() {
        guard !inBed, awake, focus == nil, hiding == nil, standing != nil, !fileDrag else { return }
        switch plan.first {
        case .none, .stroll?, .wait?: break
        default: return
        }
        strollUntil = nil
        strollTarget = nil
        plan = [.react("nodoff", 2.6), .nap]
        stepStart = nil
    }

    /// Late at night, now and then, it yawns and suggests bed. Gently, and at most every 45 minutes.
    private func maybeNudge(_ now: Date) {
        guard isLate, focus == nil, !fileDrag, now.timeIntervalSince(lastNudge) > 45 * 60 else { return }
        if inBed {
            lastNudge = now
            return sitUp("nightNudge:\(hour)", 3.4)
        }
        guard awake, !isCarried, !isReacting else { return }
        if case .nap? = plan.first { return }  // waking up first
        lastNudge = now
        interject("nightNudge:\(hour)", 3.4)
    }

    /// Sun over the bed by day, moon and stars by night.
    private func updateSky() {
        let s = (7..<19).contains(hour) ? "day" : "night"
        guard s != sky else { return }
        sky = s
        bedJS("B.sky('\(s)')")
    }

    /// What it gets up to next while it's awake: shy and sleepy at first, more adventurous later.
    private func nextActivity() -> [Step] {
        let c = curiosity
        // Hide-and-seek and long trips only once it's properly interested.
        if c > 0.35, Double.random(in: 0..<1) < 0.25 * c, let spot = findSpot() {
            var p = hidePlan(spot)
            if case let .hide(s, t) = p[4] { p[4] = .hide(s, min(t, max(20, awakeUntil.timeIntervalSinceNow))) }
            return p
        }
        let outing = outingPlan()
        guard !outing.isEmpty else { return [.wait(3)] }
        var steps: [Step] = []
        if c > 0.3, Double.random(in: 0..<1) < 0.3 { steps.append(.react("wonder", 1)) }
        else if c < 0.25, Double.random(in: 0..<1) < 0.35 { steps.append(.react("yawn", 1.6)) }
        // Early on it potters about where it is; later it sets off for somewhere new.
        if c < 0.2, standing != nil { return steps + [.stroll(.random(in: 8...15))] }
        return steps + outing
    }

    // MARK: Page bridge

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === bedWeb {
            bedReady = true
            sky = ""  // resent on the next presence check
            bedJS("B.theme('\(theme)'); B.occupied(\(inBed))")
            return
        }
        ready = true
        js("P.theme('\(theme)'); P.energy(\(energy)); P.home(\(atHome)); P.mode('\(sentMode)'); P.gear('\(gear)')")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        if message.name == "bed" { return bedClicked() }
        switch cmd {
        case "down": pressed()
        case "done": reactDone = true
        default: break
        }
    }

    private func js(_ code: String) { if ready { web.evaluateJavaScript(code) } }

    private func jsString(_ s: String) -> String {
        String(decoding: (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    private func setMode(_ m: String) {
        guard m != sentMode else { return }
        sentMode = m
        js("P.mode('\(m)')")
    }

    private func setLook(_ x: Int, _ y: Int) {
        guard (x, y) != sentLook else { return }
        sentLook = (x, y)
        js("P.look(\(x), \(y))")
    }

    private func setNear(_ on: Bool) {
        guard on != near else { return }
        near = on
        js("P.near(\(on))")
    }

    // MARK: The loop

    private func tick() {
        let now = Date()
        let dt = CGFloat(min(now.timeIntervalSince(lastTick), 0.1))
        lastTick = now
        checkPresence(now)
        guard shown else { return }
        if inBed {
            // Asleep: only a file dragged over to the bed gets it up (for a snack).
            if fileDrag { snackFromBed() }
            if let c = companion, c.isVisible { placeCompanion(c) }  // stats from the menu, by the bed
            return
        }
        moved = false
        scanWorld(now)
        trackMouse(now)
        if fileDrag || gape > 0 || catcher.isVisible { feeding() }
        if let step = plan.first { run(step, now, dt) } else { idle(now) }
        if !occluders.isEmpty || root.layer?.mask != nil { updateMask() }
        if !moved { lookAtCursor() }
        if let c = companion, c.isVisible { placeCompanion(c) }
    }

    /// Lethargic when usage is low, and slow while it's still half asleep.
    private var pace: CGFloat {
        let e = 0.45 + 0.85 * CGFloat(energy)
        return awake ? e * CGFloat(0.55 + 0.6 * curiosity) : e
    }

    private func run(_ step: Step, _ now: Date, _ dt: CGFloat) {
        if stepStart == nil { stepStart = now; begin(step) }
        let elapsed = now.timeIntervalSince(stepStart ?? now)
        var done = false
        switch step {
        case let .walk(to, speed, gait):
            done = move(to, gait == .sneak ? speed : speed * pace, dt)
        case let .fly(to):
            done = move(to, 280 * pace, dt)
        case let .flyOnto(id, at):
            guard let w = world.first(where: { $0.id == id && $0.isNormal }) else { done = true; break }  // gone: just drop
            let x = w.rect.minX + Self.half + (w.rect.width - 2 * Self.half) * at
            done = move(NSPoint(x: x, y: min(w.rect.maxY + Self.half + 50, homeArea.maxY - Self.half)), 280 * pace, dt)
        case .flyHome:
            // While it's up, "home" can wait: it carries on exploring instead.
            done = awake || move(homeCenter, 300 * pace, dt)
            if done, !awake { setMode("sit") }  // landed on the bed
        case .fall:
            done = fall(dt)
        case let .jump(to):
            done = jump(to, elapsed)
        case let .stroll(duration):
            done = stroll(duration, now, dt)
        case .carried:
            let m = mouse
            place(NSPoint(x: m.x, y: m.y - 20))  // dangling from the cursor by its sprout
            moved = true
            shook(m, now, dt)
        case .focus:
            guard let f = focus else { done = true; break }
            if now.timeIntervalSince(lastFocusSent) >= 1 { sendFocus() }
            if now >= f.end { return finishFocus() }
        case .nap:
            moved = true  // eyes shut: it isn't watching the cursor
            if now.timeIntervalSince(lastActive) < 3 {
                // You're back (or never really left): it wakes with a start.
                plan[0] = .react("stir", 1.7)
                stepStart = nil
                return
            }
            done = !awake  // bored of waiting: bedtime comes and it heads home
        case .feed:
            // Hold still with the mouth open, nudged so the grown-up body stays on screen.
            let r = mouthBody(gape), area = homeArea
            let fit = NSPoint(x: pos.x + max(area.minX - r.minX, 0) + min(area.maxX - r.maxX, 0),
                              y: pos.y + max(area.minY - r.minY, 0) + min(area.maxY - r.maxY, 0))
            _ = move(fit, 400, dt, within: 1)
        case .chase:
            // Stop just under the cursor, where it's easy to pat.
            let m = mouse
            done = move(NSPoint(x: m.x, y: m.y - 32), 440 * pace, dt, within: 10) || elapsed > 12
        case let .wait(t):
            done = elapsed >= t
        case let .react(_, t):
            done = reactDone || elapsed >= t
        case let .layer(l):
            setLayer(l)
            done = true
        case let .hide(spot, t):
            if let was = spot.window, now.timeIntervalSince(lastSpotCheck) > 0.5 {
                lastSpotCheck = now
                if !windowStill(at: was) { return exposed() }
            }
            done = elapsed >= t
        case .settle:
            // Back into bed (with a yawn first), unless it still has time to play.
            if !awake, !saidGoodnight {
                saidGoodnight = true
                plan.insert(.react("bedtime", 1.8), at: 0)
                stepStart = nil
                return
            }
            if !awake { settle() }
            done = true
        }
        guard done else { return }
        if case .hide = step { endHiding() }
        if case .stroll = step { strollUntil = nil; strollTarget = nil }
        if !plan.isEmpty { plan.removeFirst() }
        stepStart = nil
    }

    private func begin(_ step: Step) {
        #if DEBUG
        let stamp = String(format: "%.1f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        history = Array((history + ["\(stamp) \(String(describing: step).prefix(60)) at \(Int(pos.x)),\(Int(pos.y)) on \(standing?.id ?? -1)"]).suffix(14))
        #endif
        switch step {
        case let .walk(_, _, gait): setMode(gait.rawValue)
        case .fly, .flyOnto, .chase: leaveSurface(); setMode("fly")
        case .flyHome: if !awake { leaveSurface(); setMode("fly") }
        case .fall: leaveSurface(); vy = 0; setMode("fall")
        case .jump: leaveSurface(); jumpFrom = pos; setMode("jump")
        case .carried: leaveSurface(); setMode("held")
        case .feed: setMode("gape")
        case .focus: setMode("work"); sendFocus()
        case .nap: setMode("nap"); setLook(0, 0)
        case .stroll: setMode("sit")
        case .wait: if sentMode != "fly" { setMode("sit") }
        case let .react(name, _):
            reactDone = false
            if sentMode != "fly" && sentMode != "held" { setMode("sit") }
            js("P.react(\(jsString(reactArg(name))))")
        case let .hide(spot, _):
            hiding = spot
            hoverSince = nil
            setMode(spot.side.rawValue)
        case .layer, .settle: break
        }
    }

    /// "peek:<window id>" becomes "peek:<folder name>" for the page.
    private func reactArg(_ name: String) -> String {
        guard name.hasPrefix("peek:"), let id = Int(name.dropFirst(5)) else { return name }
        return "peek:" + (folderNames[id] ?? "")
    }

    /// Heads straight for a body-centre point; true once it's there.
    private func move(_ target: NSPoint, _ speed: CGFloat, _ dt: CGFloat, within: CGFloat = 1.5) -> Bool {
        let dx = target.x - pos.x, dy = target.y - pos.y, d = hypot(dx, dy)
        if d <= within {
            if within < 2 { place(target) }
            return true
        }
        let s = min(d, speed * dt)
        place(NSPoint(x: pos.x + dx / d * s, y: pos.y + dy / d * s))
        moved = true
        setLook(abs(dx) > 2 ? (dx > 0 ? 1 : -1) : 0, 0)
        return false
    }

    private func place(_ c: NSPoint) {
        pos = c
        panel.setFrameOrigin(NSPoint(x: c.x - Self.anchor.x, y: c.y - Self.anchor.y))
    }

    private func body(at c: NSPoint) -> CGRect { CGRect(x: c.x - Self.half, y: c.y - Self.half, width: 2 * Self.half, height: 2 * Self.half) }

    /// Sitting up in bed, right where its head lies on the pillow.
    private var homeCenter: NSPoint {
        let bedOrigin = NSPoint(x: corner.x - Self.bedSize.width - 4, y: corner.y - Self.bedSize.height - 2)
        return NSPoint(x: bedOrigin.x + Self.pillow.x, y: bedOrigin.y + Self.pillow.y)
    }

    private var homeArea: NSRect { screen(for: body(at: homeCenter)).visibleFrame }

    private func screen(for rect: NSRect) -> NSScreen {
        NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private var isCarried: Bool { if case .carried? = plan.first { return true } else { return false } }
    private var isReacting: Bool { if case .react? = plan.first { return true } else { return false } }

    // MARK: Standing, walking, falling, jumping

    /// The floor above the Dock, the top edge of every window it fits on, the Dock's icons and the
    /// folders on the desktop when they're showing.
    private func surfaces() -> [Surface] {
        let area = homeArea
        var out: [Surface] = []
        let dock = dockShowing ? currentDockIcons() : []
        if let first = dock.first?.rect, let last = dock.last?.rect {
            // Over the Dock the icons are the floor; a shelf at their tops catches the gaps between them.
            out.append(Surface(id: 0, minX: area.minX, maxX: first.minX, y: area.minY, kind: .floor))
            out.append(Surface(id: 0, minX: last.maxX, maxX: area.maxX, y: area.minY, kind: .floor))
            out.append(Surface(id: -999, minX: first.minX, maxX: last.maxX, y: dock.map(\.rect.maxY).min() ?? area.minY, kind: .dockIcon))
            out += dock.map { Surface(id: $0.id, minX: $0.rect.minX, maxX: $0.rect.maxX, y: $0.rect.maxY, kind: .dockIcon) }
        } else {
            out.append(Surface(id: 0, minX: area.minX, maxX: area.maxX, y: area.minY, kind: .floor))
        }
        for w in world where w.isNormal && w.pid != myPid && canStand(on: w.rect) {
            out.append(Surface(id: w.id, minX: max(w.rect.minX, area.minX), maxX: min(w.rect.maxX, area.maxX), y: w.rect.maxY))
        }
        if desktopShowing {
            let normal = world.filter { $0.isNormal && $0.pid != myPid }.map(\.rect)
            for f in desktopFolders where area.contains(f.rect) && !normal.contains(where: { $0.intersects(f.rect.insetBy(dx: -4, dy: -4)) }) {
                out.append(Surface(id: f.id, minX: f.rect.minX, maxX: f.rect.maxX, y: f.rect.maxY, kind: .desktopIcon))
            }
        }
        return out
    }

    /// Wide enough, and with room above it under the menu bar.
    private func canStand(on r: CGRect) -> Bool {
        let area = homeArea
        return r.width >= 100 && r.maxY <= area.maxY - 44 && r.maxY >= area.minY + 30 && r.maxX > area.minX + 50 && r.minX < area.maxX - 50
    }

    /// Stretches of a surface where it would be seen standing: not under a window in front of that one.
    private func openSpans(_ s: Surface) -> [ClosedRange<CGFloat>] {
        if s.isIcon { return s.id == -999 ? [] : [s.minX + (s.maxX - s.minX) / 2 ... s.minX + (s.maxX - s.minX) / 2] }  // one spot, on top
        guard s.maxX - s.minX > 2 * Self.half else { return [] }
        var spans = [(s.minX + Self.half)...(s.maxX - Self.half)]
        guard s.id != 0 else { return spans }
        for w in world where w.isNormal && w.pid != myPid {
            if w.id == s.id { break }
            guard w.rect.minY < s.y + 2 * Self.half, w.rect.maxY > s.y else { continue }
            let cut = (w.rect.minX - Self.half)...(w.rect.maxX + Self.half)
            spans = spans.flatMap { span -> [ClosedRange<CGFloat>] in
                guard span.overlaps(cut) else { return [span] }
                var parts: [ClosedRange<CGFloat>] = []
                if span.lowerBound < cut.lowerBound { parts.append(span.lowerBound...cut.lowerBound) }
                if span.upperBound > cut.upperBound { parts.append(cut.upperBound...span.upperBound) }
                return parts
            }
        }
        return spans.filter { $0.upperBound - $0.lowerBound >= 16 }
    }

    private func land(on s: Surface, speed: CGFloat) {
        standing = s
        standingRect = world.first(where: { $0.id == s.id })?.rect ?? .zero
        switch s.kind {
        case .floor: setLayer(.top)
        case .window: setLayer(.on(window: s.id))
        case .dockIcon: setLayer(.onDock)
        case .desktopIcon: setLayer(.onDesktop)
        }
        setMode("sit")
        plan.insert(.react(speed > 1100 ? "land:big" : "land", 1.2), at: min(1, plan.count))
    }

    private func leaveSurface() {
        standing = nil
        switch layer {
        case .on, .onDesktop, .onDock: setLayer(.top)
        default: break
        }
    }

    /// Gravity, until it lands on the highest edge under it (the floor catches everything).
    private func fall(_ dt: CGFloat) -> Bool {
        vy = max(vy - 2300 * dt, -2600)
        let area = homeArea
        let x = min(max(pos.x, area.minX + Self.half), area.maxX - Self.half)
        let feet = pos.y - Self.half, next = pos.y + vy * dt
        moved = true
        let landing = surfaces()
            .filter { $0.minX + 8 <= x && x <= $0.maxX - 8 && $0.y <= feet + 1 && $0.y >= next - Self.half - 1 }
            .max { $0.y < $1.y }
        if let s = landing {
            place(NSPoint(x: x, y: s.y + Self.half))
            land(on: s, speed: -vy)
            return true
        }
        place(NSPoint(x: x, y: max(next, area.minY - 40)))
        return false
    }

    /// A hop in an arc to another edge.
    private func jump(_ feet: NSPoint, _ t: TimeInterval) -> Bool {
        let target = NSPoint(x: feet.x, y: feet.y + Self.half)
        let duration = 0.4 + Double(hypot(target.x - jumpFrom.x, target.y - jumpFrom.y)) / 1300
        let k = CGFloat(min(1, t / duration))
        let lift = max(36, target.y - jumpFrom.y + 36)
        place(NSPoint(x: jumpFrom.x + (target.x - jumpFrom.x) * k,
                      y: jumpFrom.y + (target.y - jumpFrom.y) * k + lift * 4 * k * (1 - k)))
        moved = true
        if abs(target.x - jumpFrom.x) > 2 { setLook(target.x > jumpFrom.x ? 1 : -1, 0) }
        guard k >= 1 else { return false }
        if let s = surfaces().first(where: { abs($0.y - feet.y) < 4 && $0.minX + 6 <= feet.x && feet.x <= $0.maxX - 6 }) {
            land(on: s, speed: 400)
        } else {
            plan.insert(.fall, at: min(1, plan.count))  // the edge moved away mid-jump
        }
        return true
    }

    private func stroll(_ duration: TimeInterval, _ now: Date, _ dt: CGFloat) -> Bool {
        if !awake { return true }  // bedtime
        if strollUntil == nil { strollUntil = now.addingTimeInterval(duration) }
        guard let s = standing else {
            plan.insert(.fall, at: 0)
            stepStart = nil
            return false
        }
        if let tx = strollTarget {
            if move(NSPoint(x: tx, y: s.y + Self.half), 70 * pace, dt) {
                strollTarget = nil
                strollRest = now.addingTimeInterval(.random(in: 1.2...3.5))
                setMode("sit")
            }
            return false
        }
        if now >= strollUntil ?? now { return true }
        if now >= strollRest { nextStrollMove(s, now) }
        return false
    }

    private func nextStrollMove(_ s: Surface, _ now: Date) {
        let r = Double.random(in: 0..<1)
        // On an icon there's nowhere to walk, so it mostly hops on to the next one.
        if r < (s.isIcon ? 0.7 : 0.15), let feet = jumpTarget(from: s) {
            plan.insert(.jump(to: feet), at: 0)
            stepStart = nil
            return
        }
        if r > 0.93, folderNames[s.id] != nil {
            plan.insert(.react("peek:\(s.id)", 2.2), at: 0)
            stepStart = nil
            return
        }
        let spans = openSpans(s)
        var target: CGFloat?
        if let c = restingCursor(now), abs(c.y - s.y) < 240,
           let span = spans.min(by: { distance(c.x, $0) < distance(c.x, $1) }) {
            target = min(max(c.x, span.lowerBound), span.upperBound)  // go see what the cursor's up to
        } else if let span = spans.randomElement() {
            target = CGFloat.random(in: span)
        }
        if let t = target, abs(t - pos.x) > 8 {
            strollTarget = t
            setMode("walk")
        } else {
            strollRest = now.addingTimeInterval(.random(in: 1.5...3))
        }
    }

    private func distance(_ x: CGFloat, _ span: ClosedRange<CGFloat>) -> CGFloat {
        span.contains(x) ? 0 : min(abs(x - span.lowerBound), abs(x - span.upperBound))
    }

    /// A nearby edge it could hop to.
    private func jumpTarget(from s: Surface) -> NSPoint? {
        var options: [NSPoint] = []
        for o in surfaces() where o.id != s.id {
            let dy = o.y - s.y
            guard dy > -320, dy < 170 else { continue }
            // From one icon, the next few icons over; from anywhere else, any edge in reach.
            let reach: CGFloat = s.isIcon && o.isIcon ? 170 : 260
            for span in openSpans(o) {
                let x = min(max(pos.x + .random(in: -60...60), span.lowerBound), span.upperBound)
                if abs(x - pos.x) < reach, abs(x - pos.x) > 4 || abs(dy) > 20 { options.append(NSPoint(x: x, y: o.y)) }
            }
        }
        return options.randomElement()
    }

    // MARK: Home and outings

    /// Nothing planned: keep exploring while it's up, otherwise yawn and head back to bed.
    private func idle(_ now: Date) {
        if focus != nil {
            plan = standing == nil ? [.fall, .focus] : [.focus]  // back to work after a pat or a hop
        } else if awake, roams, !quiet {
            readIcons()
            plan = nextActivity()
        } else {
            plan = [.flyHome, .settle]  // settling in plays the bedtime yawn
        }
        stepStart = nil
    }

    /// Fly to a window top (folders first) or the floor, drop onto it, potter about, fly home.
    private func outingPlan() -> [Step] {
        var options: [(Surface, ClosedRange<CGFloat>, Double)] = []
        for s in surfaces() {
            let weight: Double = s.kind == .floor ? 1 : s.isIcon ? 0.35 : isFinder(s.id) ? 3 : 1.6  // per icon
            for span in openSpans(s) { options.append((s, span, weight)) }
        }
        var roll = Double.random(in: 0..<max(options.reduce(0) { $0 + $1.2 }, 0.001))
        guard let pick = options.first(where: { roll -= $0.2; return roll < 0 }) ?? options.last else { return [] }
        let x = CGFloat.random(in: pick.1)
        return [.fly(to: NSPoint(x: x, y: min(pick.0.y + Self.half + 60, homeArea.maxY - Self.half))), .fall,
                .stroll(.random(in: 25...70)), .flyHome, .settle]
    }

    private func hidePlan(_ s: Spot) -> [Step] {
        [.fly(to: s.approach), .wait(0.5), .layer(s.layer),
         .walk(to: s.center, speed: 34, gait: .sneak), .hide(s, .random(in: 60...180)),
         .walk(to: s.approach, speed: 34, gait: .sneak), .layer(.top), .flyHome, .settle]
    }

    private func leaveHome() {
        guard atHome else { return }
        atHome = false
        js("P.home(false)")
    }

    private func settle() {
        setLook(0, 0)
        goToBed()
    }

    /// Back to bed early (roaming switched off, or you're on a call).
    private func comeHome() {
        awakeUntil = Date()
        endHiding()
        strollUntil = nil
        plan = [.layer(.top), .flyHome, .settle]
        stepStart = nil
    }

    /// The screen or Space changed under it: the bed moves with the corner, and so does the pet.
    @objc private func goHomeNow() {
        placeBed()
        guard !isCarried else { return }  // you've got it in hand
        endHiding()
        strollUntil = nil
        plan = []
        stepStart = nil
        if awake {
            leaveSurface()
            place(homeCenter)
        } else {
            goToBed()
        }
    }

    /// A file dragged toward the bed: it sits up, half asleep, to eat it, then goes straight back.
    private func snackFromBed() {
        guard interactive, snackDrag != dragBase, hypot(mouse.x - homeCenter.x, mouse.y - homeCenter.y) < 220 else { return }
        snackDrag = dragBase
        inBed = false
        atHome = true
        bedJS("B.occupied(false)")
        place(homeCenter)
        setLayer(.top)
        setMode("sit")
        if shown { panel.orderFrontRegardless() }
    }

    // MARK: Being found, picked up, patted, rubbed

    private func found() {
        endHiding()
        plan = [.layer(.top), .react("found", 3.5), .wait(0.5), .flyHome, .settle]
        stepStart = nil
    }

    /// Its hiding place moved away.
    private func exposed() {
        endHiding()
        plan = [.layer(.top), .react("exposed", 1.6), .flyHome, .settle]
        stepStart = nil
    }

    private func endHiding() {
        hiding = nil
        hoverSince = nil
        setNear(false)
    }

    /// Pauses whatever it's doing for a quick reaction; never cuts off a different reaction.
    private func interject(_ name: String, _ t: TimeInterval) {
        guard !isCarried else { return }
        if case let .react(current, _)? = plan.first {
            guard current == name else { return }
            plan.removeFirst()
        }
        plan.insert(.react(name, t), at: 0)
        stepStart = nil
    }

    /// The page saw a mouse-down on it: a tap if it's let go in place, a pick-up if it's dragged.
    private func pressed() {
        guard pressMonitor == nil else { return }
        pressStart = NSEvent.mouseLocation
        carrying = false
        pressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.press(event)
            return event
        }
    }

    private func press(_ event: NSEvent) {
        let m = NSEvent.mouseLocation
        if event.type == .leftMouseDragged, !carrying, let s = pressStart, hypot(m.x - s.x, m.y - s.y) > 5 {
            carrying = true
            pickUp()
        } else if event.type == .leftMouseUp {
            if let mon = pressMonitor { NSEvent.removeMonitor(mon) }
            pressMonitor = nil
            if carrying { carrying = false; drop() } else { tapped() }
        }
    }

    private func tapped() {
        if hiding != nil { return found() }
        // Sitting up in bed (saying hi, or that it's late): a tap gets it up, same as clicking the bed.
        // Otherwise the tap was lost behind its line and it lay straight back down.
        if atHome, !inBed { return bedClicked() }
        // At its desk, a tap gets a quiet "how long's left" rather than a fuss.
        interject(focus != nil ? "focusLeft:\(minutesLeft)" : "pat", focus != nil ? 2.4 : 1.6)
        onTap?(body(at: pos))
    }

    private func pickUp() {
        shakeSamples = []
        shakenFor = 0
        hideCatcher()
        endHiding()
        leaveHome()
        strollUntil = nil
        strollTarget = nil
        plan = [.carried]
        stepStart = nil
    }

    /// Let go: it falls onto whatever's underneath, looks around there for a bit, then flies home.
    private func drop() {
        leaveHome()
        let dizzy = shakenFor > 0.7
        if shakeLevel != 0 { shakeLevel = 0; js("P.shake(0)") }
        // Mid-focus, wherever you put it becomes its desk.
        let after: [Step] = focus != nil ? [.focus] : [.stroll(.random(in: 20...45)), .flyHome, .settle]
        plan = [.fall] + (dizzy ? [.react("dizzy", 2.8)] : []) + after
        stepStart = nil
    }

    private func mouseDownElsewhere() {
        dragBase = NSPasteboard(name: .drag).changeCount
        fileDrag = false
        dragEnded = nil
        clickedNearby()
    }

    /// Shaking it while you hold it: how often the cursor whips back the other way, at speed.
    private func shook(_ m: NSPoint, _ now: Date, _ dt: CGFloat) {
        shakeSamples = shakeSamples.filter { now.timeIntervalSince($0.0) < 0.6 } + [(now, m)]
        var turns = 0, lastX = 0, lastY = 0
        for (a, b) in zip(shakeSamples, shakeSamples.dropFirst()) {
            let t = CGFloat(max(b.0.timeIntervalSince(a.0), 0.001))
            let vx = (b.1.x - a.1.x) / t, vy = (b.1.y - a.1.y) / t
            if abs(vx) > 450 {
                let d = vx > 0 ? 1 : -1
                if lastX != 0, d != lastX { turns += 1 }
                lastX = d
            }
            if abs(vy) > 450 {
                let d = vy > 0 ? 1 : -1
                if lastY != 0, d != lastY { turns += 1 }
                lastY = d
            }
        }
        let level = turns >= 5 ? 3 : turns >= 3 ? 2 : turns >= 1 ? 1 : 0
        if level >= 2 { shakenFor += Double(dt) }
        guard level != shakeLevel else { return }
        shakeLevel = level
        js("P.shake(\(level))")
    }

    /// A click close by in another app makes it jump.
    private func clickedNearby() {
        let m = NSEvent.mouseLocation, now = Date()
        let d = hypot(m.x - pos.x, m.y - pos.y)
        guard panel.isVisible, focus == nil, d > 30, d < 110, hiding == nil, !atHome, now.timeIntervalSince(lastStartle) > 3 else { return }
        lastStartle = now
        interject("startle", 0.9)
    }

    private func trackMouse(_ now: Date) {
        let m = mouse
        if hypot(m.x - stillMouse.0.x, m.y - stillMouse.0.y) > 3 {
            stillMouse = (m, now)
            catchesForThisSpot = 0
        }
        let over = body(at: pos).insetBy(dx: -3, dy: -3).contains(m)
        let reachable = interactive && over && !covered(m)
        let wantsEvents = reachable || pressMonitor != nil
        // While a file is being dragged, feeding() decides whether the window takes the drop.
        if !fileDrag, panel.ignoresMouseEvents == wantsEvents { panel.ignoresMouseEvents = !wantsEvents }
        guard !isCarried else { return }

        if hiding != nil {
            if reachable {
                hoverSince = hoverSince ?? now
                if now.timeIntervalSince(hoverSince ?? now) > 0.15 { return found() }
            } else {
                hoverSince = nil
            }
            setNear(hypot(m.x - pos.x, m.y - pos.y) < 110)
            return
        }
        guard !fileDrag else { return }
        if reachable { rubbed(m, now) } else if !rubXs.isEmpty { rubXs = [] }

        // A cursor hovering just over its head is something to jump for, twice, until it moves. Not at
        // home, where the menu bar is right above it.
        let overhead = !atHome && focus == nil && abs(m.x - pos.x) < 26 && m.y > pos.y + 22 && m.y < pos.y + 100
        if overhead, energy >= 0.35, !isReacting, interactive, catchesForThisSpot < 2 {
            hoverAboveSince = hoverAboveSince ?? now
            if now.timeIntervalSince(hoverAboveSince ?? now) > 0.6, now.timeIntervalSince(lastCatch) > 4 {
                lastCatch = now
                catchesForThisSpot += 1
                hoverAboveSince = nil
                interject("catch", 1.2)
            }
        } else {
            hoverAboveSince = nil
        }
    }

    /// Where the cursor has been sitting still for a couple of seconds, if it has.
    private func restingCursor(_ now: Date) -> NSPoint? {
        now.timeIntervalSince(stillMouse.1) > 2 ? stillMouse.0 : nil
    }

    private func lookAtCursor() {
        let m = mouse, dx = m.x - pos.x, dy = m.y - pos.y
        guard hypot(dx, dy) < 450, hiding == nil else { return setLook(0, 0) }
        setLook(dx > 24 ? 1 : dx < -24 ? -1 : 0, dy > 40 ? 1 : 0)
    }

    /// Back-and-forth strokes over it, without clicking, count as petting.
    private func rubbed(_ m: NSPoint, _ now: Date) {
        rubXs = rubXs.filter { now.timeIntervalSince($0.0) < 0.9 } + [(now, m.x)]
        var turns = 0, last = 0
        for (a, b) in zip(rubXs, rubXs.dropFirst()) {
            let dx = b.1 - a.1
            guard abs(dx) > 1.5 else { continue }
            let dir = dx > 0 ? 1 : -1
            if last != 0, dir != last { turns += 1 }
            last = dir
        }
        guard turns >= 3, now.timeIntervalSince(lastRub) > 1.3 else { return }
        lastRub = now
        rubXs = []
        interject("rub", 1.4)
    }

    /// Whether something is drawn over the pet at this point, so the cursor there isn't really on it.
    private func covered(_ m: NSPoint) -> Bool {
        if occluders.contains(where: { $0.contains(m) }) { return true }
        if let c = hiding?.cover, c.contains(m) { return true }
        guard panel.level.rawValue < NSWindow.Level.normal.rawValue else { return false }
        // Only ordinary app windows: the Dock and screen recorders keep invisible full-screen windows
        // above everything, and those would hide it from the cursor for good.
        return world.contains { $0.isNormal && $0.pid != myPid && $0.rect.contains(m) }
    }

    // MARK: Watching the screen

    /// Re-reads the window list: fast while a window it's riding is moving, slow while it's home.
    private func scanWorld(_ now: Date) {
        let every: TimeInterval = now < fastWorldUntil ? 0 : atHome && plan.isEmpty ? 0.5 : 0.1
        guard now.timeIntervalSince(lastWorld) >= every else { return }
        lastWorld = now
        world = windows()
        ride(now)
        refreshOccluders()
        watchFolders(now)
    }

    /// Moves with the window under its feet, and drops off when that window goes away.
    private func ride(_ now: Date) {
        guard let s = standing, s.id != 0, !isCarried else { return }
        if s.isIcon {
            // The Dock hid, or a window now covers the desktop folder: hop off.
            if !surfaces().contains(where: { $0.id == s.id }) { dropOff() }
            return
        }
        guard let w = world.first(where: { $0.id == s.id && $0.isNormal }), canStand(on: w.rect) else { return dropOff() }
        let dx = w.rect.minX - standingRect.minX, dy = w.rect.maxY - standingRect.maxY
        standingRect = w.rect
        standing = Surface(id: w.id, minX: w.rect.minX, maxX: w.rect.maxX, y: w.rect.maxY)
        if dx != 0 || dy != 0 {
            place(NSPoint(x: pos.x + dx, y: pos.y + dy))
            strollTarget = strollTarget.map { $0 + dx }
            fastWorldUntil = now.addingTimeInterval(1)
        }
        if pos.x < w.rect.minX + 6 || pos.x > w.rect.maxX - 6 { dropOff() }
    }

    private func dropOff() {
        #if DEBUG
        history.append("dropOff at \(Int(pos.x)),\(Int(pos.y)) from \(standing?.id ?? -1)")
        #endif
        standing = nil
        if case .fall? = plan.first { return }
        if case let .react(name, _)? = plan.first, name.hasPrefix("land") { plan.removeFirst() }  // it lands again below
        plan.insert(.fall, at: 0)
        stepStart = nil
    }

    private var isMasked: Bool {
        switch layer {
        case .on, .onDesktop, .behind: return true
        default: return false
        }
    }

    private func setLayer(_ l: Layer) {
        layer = l
        switch l {
        case .top, .on, .onDesktop, .behind: panel.level = topLevel
        case .onDock: panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        case .underIcons: panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        case .underDock: panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        }
        refreshOccluders()
        updateMask()
        panel.orderFrontRegardless()
    }

    /// macOS won't let us slip between another app's windows, so the pet stays on top and cuts away
    /// whatever would be in front of it: the windows in front of the one it stands on (or hides behind).
    private func refreshOccluders() {
        let target: Int
        let including: Bool
        switch layer {
        case let .on(id): target = id; including = false
        case let .behind(id): target = id; including = true
        case .onDesktop:  // on the desktop itself, so under every window
            occluders = world.filter { $0.isNormal && $0.pid != myPid }.map(\.rect)
            return
        default: occluders = []; return
        }
        var cover: [CGRect] = []
        for w in world where w.isNormal && w.pid != myPid {
            if w.id == target {
                if including { cover.append(w.rect) }
                break
            }
            cover.append(w.rect)
        }
        occluders = cover
    }

    private func updateMask() {
        let frame = panel.frame
        let hits = occluders.filter { $0.intersects(frame) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if hits.isEmpty {
            root.layer?.mask = nil
        } else {
            var path = CGPath(rect: CGRect(origin: .zero, size: Self.size), transform: nil)
            for r in hits { path = path.subtracting(CGPath(rect: r.offsetBy(dx: -frame.minX, dy: -frame.minY), transform: nil)) }
            mask.path = path
            if root.layer?.mask !== mask { root.layer?.mask = mask }
        }
        CATransaction.commit()
    }

    private func windowStill(at rect: CGRect) -> Bool {
        guard case let .behind(id) = layer else { return true }
        guard let w = world.first(where: { $0.id == id }) else { return false }
        return abs(w.rect.minX - rect.minX) < 3 && abs(w.rect.minY - rect.minY) < 3 && abs(w.rect.width - rect.width) < 3 && abs(w.rect.height - rect.height) < 3
    }

    /// On-screen windows, front to back, in Cocoa screen coordinates.
    private func windows() -> [Win] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let flip = NSScreen.screens.first?.frame.height ?? 0
        return list.compactMap { w in
            guard let id = w[kCGWindowNumber as String] as? Int,
                  let dict = w[kCGWindowBounds as String], let b = CGRect(dictionaryRepresentation: dict as! CFDictionary) else { return nil }
            return Win(id: id, rect: CGRect(x: b.minX, y: flip - b.maxY, width: b.width, height: b.height),
                       layer: w[kCGWindowLayer as String] as? Int ?? 0, alpha: w[kCGWindowAlpha as String] as? Double ?? 1,
                       pid: w[kCGWindowOwnerPID as String] as? pid_t ?? 0)
        }
    }

    // MARK: Folders and apps

    private func isFinder(_ id: Int) -> Bool {
        guard let finder = currentFinderPid else { return false }
        return world.contains { $0.id == id && $0.pid == finder }
    }

    private var currentFinderPid: pid_t? {
        if Date().timeIntervalSince(finderPid.1) > 30 {
            finderPid = (NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier, Date())
        }
        return finderPid.0
    }

    /// A folder window that wasn't there a moment ago: go sit on it and read its name.
    private func watchFolders(_ now: Date) {
        guard let finder = currentFinderPid else { return }
        let ids = Set(world.filter { $0.pid == finder && $0.isNormal && $0.rect.width > 200 && $0.rect.height > 150 }.map(\.id))
        defer { finderIDs = ids }
        guard let known = finderIDs, let id = ids.subtracting(known).first else { return }
        readFolderNames()
        guard awake, focus == nil, roams, !quiet, hiding == nil, !isCarried, now.timeIntervalSince(lastNotice) > 15 else { return }
        lastNotice = now
        noticeFolder(id)
    }

    private func noticeFolder(_ id: Int) {
        guard let w = world.first(where: { $0.id == id }), canStand(on: w.rect), !openSpans(
            Surface(id: w.id, minX: w.rect.minX, maxX: w.rect.maxX, y: w.rect.maxY)).isEmpty else {
            return interject("notice", 0.8)  // nowhere to sit on it, so just look
        }
        leaveHome()
        endHiding()
        strollUntil = nil
        // The wait lets Finder's opening animation finish before it picks a spot.
        plan = [.react("notice", 0.8), .wait(0.5), .flyOnto(window: id, at: .random(in: 0.15...0.85)), .fall,
                .react("peek:\(id)", 2.2), .stroll(.random(in: 20...50)), .flyHome, .settle]
        stepStart = nil
    }

    /// Names of the open Finder windows, matched to the window list by position.
    /// By index: "repeat with w in Finder windows" hands back "item 1 of every Finder window", and to
    /// Finder an item is a file, so that would read the bounds of the files inside instead.
    fileprivate static let folderScript = """
        set out to ""
        tell application "Finder"
            repeat with i from 1 to (count of Finder windows)
                set w to Finder window i
                set b to bounds of w
                set out to out & (name of w) & tab & (item 1 of b) & tab & (item 2 of b) & tab & (item 3 of b) & linefeed
            end repeat
        end tell
        return out
        """

    private func readFolderNames() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let text = Self.osascript(Self.folderScript)
            DispatchQueue.main.async {
                guard let self, let finder = self.currentFinderPid else { return }
                let flip = NSScreen.screens.first?.frame.height ?? 0
                for line in text.split(separator: "\n") {
                    let f = line.split(separator: "\t", omittingEmptySubsequences: false)
                    guard f.count == 4, let l = Double(f[1]), let t = Double(f[2]), let r = Double(f[3]) else { continue }
                    // Finder's bounds are measured from the top of the screen and leave out the title bar.
                    if let w = self.world.first(where: { $0.pid == finder && abs($0.rect.minX - l) < 4 && abs($0.rect.maxX - r) < 4
                        && abs((flip - $0.rect.maxY) - t) < 60 }) {
                        self.folderNames[w.id] = String(f[0])
                    }
                }
            }
        }
    }

    @objc private func appActivated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        switchedTo(app?.bundleIdentifier ?? "")
    }

    /// Headphones and a little dance for music, glasses for code, and quiet at home during calls.
    private func switchedTo(_ bundle: String) {
        let kind = Self.kind(of: bundle)
        let wear = kind == .music ? "phones" : kind == .code ? "glasses" : ""
        if wear != gear {
            gear = wear
            js("P.gear('\(wear)')")
        }
        let wasQuiet = quiet
        quiet = kind == .call
        if quiet, !wasQuiet, !inBed, focus == nil {
            comeHome()
            plan.insert(.react("shh", 1.6), at: 0)
        }
        if kind == .music, !inBed, focus == nil, Date().timeIntervalSince(lastDance) > 90, hiding == nil, !isCarried {
            lastDance = Date()
            interject("dance", 2.6)
        }
    }

    private static func kind(of bundle: String) -> AppKind {
        switch bundle {
        case "com.spotify.client", "com.apple.Music", "com.apple.podcasts", "com.netease.163music", "com.tencent.QQMusicMac", "com.kugou.mac.Music":
            return .music
        case "us.zoom.xos", "com.apple.FaceTime", "com.microsoft.teams", "com.microsoft.teams2", "com.cisco.webexmeetingsapp", "com.tencent.meeting":
            return .call
        case "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable":
            return .code
        default:
            return bundle.hasPrefix("com.jetbrains.") ? .code : .other
        }
    }

    fileprivate static func osascript(_ source: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text
    }

    // MARK: Feeding it files

    /// A drag in another app that carries files (the drag pasteboard changes once a drag really starts).
    private func draggedElsewhere(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            // We hear about the button coming up before the drop arrives, so keep the mouth open for it.
            if fileDrag { dragEnded = Date(); feedLog("button up, gape \(gape)") }
            return
        }
        guard !fileDrag else { return }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != dragBase else { return }
        dragBase = pb.changeCount
        fileDrag = pb.types?.contains(.fileURL) == true
        dragEnded = nil
        if fileDrag { feedLog("file drag started") }
    }

    /// The closer the file, the wider the mouth; over it, the window takes the drop.
    private func feeding() {
        if let ended = dragEnded {
            guard Date().timeIntervalSince(ended) > 0.6 else { return }  // still waiting for the drop
            dragEnded = nil
            fileDrag = false
            feedLog("no drop arrived")
        }
        guard fileDrag, panel.isVisible, interactive, !isCarried else {
            setGape(0)
            hideCatcher()
            if case .feed? = plan.first { endFeeding("aw") }
            return
        }
        let m = mouse
        let d = hypot(m.x - pos.x, m.y - (pos.y + 8))
        let over = mouthBody(3).insetBy(dx: -16, dy: -16).contains(m)
        let level = over && gape >= 2 || d < 75 ? 3 : d < 140 ? 2 : d < 220 ? 1 : 0
        setGape(level)
        if level > 0, plan.first.map({ if case .feed = $0 { return false } else { return true } }) ?? true {
            endHiding()
            if isMasked { setLayer(.top) }  // pop out in front so the drop reaches it
            plan.insert(.feed, at: 0)
            stepStart = nil
        }
        // Wherever the mouth looks wide open, the drop is taken: the grown body and the whole zone around it.
        let zone = CGRect(x: pos.x - 85, y: pos.y + 8 - 85, width: 170, height: 170)
        if level >= 2 { showCatcher(over: mouthBody(level).insetBy(dx: -12, dy: -12).union(zone)) } else { hideCatcher() }
    }

    private func showCatcher(over r: CGRect) {
        if catcher.frame != r { catcher.setFrame(r, display: false) }
        catcher.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        if !catcher.isVisible {
            catcher.orderFrontRegardless()
            feedLog("mouth window up at \(NSStringFromRect(r))")
        }
    }

    private func hideCatcher() {
        if catcher.isVisible { catcher.orderOut(nil) }
    }

    /// ~/Library/Logs/ClaudeUsage/feed.log: one line per feeding event, newest last, kept short.
    private func feedLog(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClaudeUsage/feed.log")
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let lines = (old.split(separator: "\n").map(String.init) + ["\(stamp) \(line)"]).suffix(200)
        try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func setGape(_ level: Int) {
        guard level != gape else { return }
        gape = level
        js("P.gape(\(level))")
    }

    /// Its body at each mouth size; it grows from its feet. Matches the sprite scales in pet.html.
    private func mouthBody(_ level: Int) -> CGRect {
        let side = 17 * CGFloat([2, 2, 3, 5][max(0, min(3, level))])
        return CGRect(x: pos.x - side / 2, y: pos.y - Self.half, width: side, height: side)
    }

    /// Done feeding: react, then go back to whatever it was doing (dropping back onto its edge).
    private func endFeeding(_ reaction: String) {
        setGape(0)
        if case .feed? = plan.first { plan.removeFirst() }
        var after: [Step] = [.react(reaction, reaction.hasPrefix("chomp") ? 3.6 : 1.3)]
        after += atHome ? [.flyHome, .settle] : [.fall]
        plan.insert(contentsOf: after, at: 0)
        stepStart = nil
    }

    /// Files dropped in its mouth go to the Trash, never further.
    private func dropped(_ urls: [URL]) -> Bool {
        let food = urls.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) && !$0.path.contains("/.Trash/") }
        feedLog("drop: \(urls.count) item(s), \(food.count) edible, gape \(gape)")
        guard gape >= 2, !food.isEmpty else { return false }
        dragEnded = nil
        hideCatcher()
        let bytes = food.reduce(Int64(0)) { $0 + Self.bytes(of: $1) }
        let taste = food.count > 1 ? "many" : bytes < 50_000 ? "snack" : bytes < 50_000_000 ? "yum" : bytes < 500_000_000 ? "big" : "huge"
        fileDrag = false
        endFeeding("chomp:\(taste)")
        trash(food) { [weak self] ok in
            self?.feedLog(ok ? "moved to the Trash" : "couldn't move it to the Trash")
            guard let self, !ok else { return }
            self.plan.insert(.react("yuck", 1.6), at: 0)  // couldn't move it, so it's still where it was
            self.stepStart = nil
        }
        return true
    }

    /// Through Finder, so the Trash's Put Back works; NSWorkspace if Finder can't.
    private func trash(_ urls: [URL], done: @escaping (Bool) -> Void) {
        let quoted = urls.map { "(POSIX file \"" + $0.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\" as alias)" }
        let script = "tell application \"Finder\" to delete {" + quoted.joined(separator: ", ") + "}"
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.osascript(script)
            let left = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !left.isEmpty else { return DispatchQueue.main.async { done(true) } }
            NSWorkspace.shared.recycle(left) { _, error in DispatchQueue.main.async { done(error == nil) } }
        }
    }

    private static func bytes(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard v.isDirectory == true else { return Int64(v.fileSize ?? 0) }
        var total: Int64 = 0, seen = 0
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let f = files?.nextObject() as? URL, seen < 5000 {  // a rough size is plenty for "big bite"
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            seen += 1
        }
        return total
    }

    // MARK: Dock and desktop icons

    private var dockShowing: Bool {
        let dockPid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        let level = Int(CGWindowLevelForKey(.dockWindow))
        return homeArea.minY - screen(for: body(at: homeCenter)).frame.minY > 20 && world.contains { $0.pid == dockPid && $0.layer == level }
    }

    private var desktopShowing: Bool {
        let level = Int(CGWindowLevelForKey(.desktopIconWindow))
        return world.contains { $0.layer == level }
    }

    /// Exact tiles (and names) through Accessibility when it's allowed; otherwise a guess from the
    /// Dock's settings. Re-read every few seconds at most.
    private func currentDockIcons() -> [Icon] {
        guard Date().timeIntervalSince(dockIcons.1) > 5 else { return dockIcons.0 }
        let icons = AXIsProcessTrusted() ? readDock() : guessDock()
        dockIcons = (icons, Date())
        for i in icons { folderNames[i.id] = i.name }
        return icons
    }

    private func askForDockAccess() {
        guard !AXIsProcessTrusted(), !UserDefaults.standard.bool(forKey: "askedDockAccess") else { return }
        UserDefaults.standard.set(true, forKey: "askedDockAccess")
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    private func readDock() -> [Icon] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
        let flip = NSScreen.screens.first?.frame.height ?? 0
        func value(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success ? v : nil
        }
        var out: [Icon] = []
        let lists = value(AXUIElementCreateApplication(dock.processIdentifier), kAXChildrenAttribute) as? [AXUIElement] ?? []
        for list in lists {
            for item in value(list, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                guard (value(item, kAXSubroleAttribute) as? String) != "AXSeparatorDockItem",
                      let p = value(item, kAXPositionAttribute), let s = value(item, kAXSizeAttribute) else { continue }
                var origin = CGPoint.zero, size = CGSize.zero
                AXValueGetValue(p as! AXValue, .cgPoint, &origin)
                AXValueGetValue(s as! AXValue, .cgSize, &size)
                guard size.width > 10 else { continue }
                // The tile is a bit taller than the picture; stand on the picture.
                let side = min(size.width, size.height) * 0.86
                let rect = CGRect(x: origin.x + (size.width - side) / 2, y: flip - origin.y - size.height + (size.height - side) / 2, width: side, height: side)
                out.append(Icon(id: -1000 - out.count, rect: rect, name: value(item, kAXTitleAttribute) as? String ?? ""))
            }
        }
        return out.filter { $0.rect.maxY < homeArea.minY + 4 }.sorted { $0.rect.minX < $1.rect.minX }  // bottom Dock only
    }

    /// Without Accessibility: evenly spaced tiles for the apps it lists, centred on the screen.
    private func guessDock() -> [Icon] {
        let d = UserDefaults(suiteName: "com.apple.dock")
        let pinned = d?.array(forKey: "persistent-apps")?.count ?? 0
        let others = d?.array(forKey: "persistent-others")?.count ?? 0
        let recents = d?.object(forKey: "show-recents") as? Bool == false ? 0 : min(d?.array(forKey: "recent-apps")?.count ?? 0, 3)
        let n = pinned + 1 + recents + others + 1  // Finder and the Trash too
        let screen = screen(for: body(at: homeCenter)).frame
        let tile = min(CGFloat(d?.double(forKey: "tilesize") ?? 48), (screen.width - 40) / CGFloat(max(n, 1)))
        let side = tile * 0.86, top = homeArea.minY - 6
        let start = screen.midX - tile * CGFloat(n) / 2
        return (0..<n).map { i in
            Icon(id: -1000 - i, rect: CGRect(x: start + tile * CGFloat(i) + (tile - side) / 2, y: top - side, width: side, height: side), name: "")
        }
    }

    // MARK: The stats pill

    /// Above its head, or below when it's near the top of the screen.
    private func placeCompanion(_ c: NSWindow) {
        let area = homeArea, f = c.frame
        var y = pos.y + Self.half + 4
        if y + f.height > area.maxY { y = pos.y - Self.half - 6 - f.height }
        let x = min(max(pos.x - f.width / 2, area.minX + 4), area.maxX - f.width - 4)
        c.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    // MARK: Hiding spots

    private func findSpot(where keep: (Spot) -> Bool = { _ in true }) -> Spot? {
        let screen = screen(for: body(at: homeCenter))
        let area = screen.visibleFrame
        let normal = world.filter { $0.isNormal && $0.pid != myPid }
        let homeZone = body(at: homeCenter).insetBy(dx: -70, dy: -70)
        let fits = { (c: NSPoint) in area.contains(self.body(at: c)) && !homeZone.intersects(self.body(at: c)) }
        var spots: [Spot] = []

        // At a window's edge: only the windows in front of that one can get in the way. Folders count twice.
        for (i, w) in normal.enumerated() where w.rect.width > 220 && w.rect.height > 160 {
            let inFront = normal[..<i].map(\.rect)
            for side in [Side.left, .right, .top] {
                guard let (c, a) = edgeSpot(w.rect, side), fits(a), fits(c),
                      !inFront.contains(where: { $0.intersects(body(at: a)) }) else { continue }
                let spot = Spot(center: c, approach: a, side: side, layer: .behind(window: w.id), window: w.rect, cover: nil)
                spots += isFinder(w.id) ? [spot, spot] : [spot]
            }
        }

        // Behind a desktop icon, if the desktop is showing there.
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        if world.contains(where: { $0.layer == iconLevel }) {
            for icon in icons {
                let side: Side = Bool.random() ? .left : .right
                let dir: CGFloat = side == .right ? 1 : -1
                let c = NSPoint(x: icon.midX + 27 * dir, y: icon.midY - 4)
                let a = NSPoint(x: icon.midX + 61 * dir, y: icon.midY - 4)
                let zone = body(at: a).union(icon)
                guard fits(a), fits(c), !normal.contains(where: { $0.rect.intersects(zone) }) else { continue }
                spots.append(Spot(center: c, approach: a, side: side, layer: .underIcons, window: nil, cover: icon))
            }
        }

        // Behind the Dock, peeking over it, when the Dock is really showing (a full-screen app hides
        // it but keeps its space). It's always at least this wide around the middle.
        let dockHeight = area.minY - screen.frame.minY
        let dockPid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        if dockHeight > 20, world.contains(where: { $0.pid == dockPid && $0.layer == dockLevel }) {
            let x = CGFloat.random(in: (screen.frame.midX - 140)...(screen.frame.midX + 140))
            let dock = CGRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: dockHeight)
            spots.append(Spot(center: NSPoint(x: x, y: dock.maxY + 5), approach: NSPoint(x: x, y: dock.maxY + 29),
                              side: .top, layer: .underDock, window: nil, cover: dock))
        }
        return spots.filter(keep).randomElement()
    }

    /// Where to sit so ~40% of the body sticks out past a window edge (eyes included), and where to
    /// stand first, fully clear of it.
    private func edgeSpot(_ w: CGRect, _ side: Side) -> (NSPoint, NSPoint)? {
        switch side {
        case .left, .right:
            guard w.height > 130 else { return nil }
            let y = CGFloat.random(in: (w.minY + 40)...(w.maxY - 80))
            return side == .left ? (NSPoint(x: w.minX + 3, y: y), NSPoint(x: w.minX - 29, y: y))
                                 : (NSPoint(x: w.maxX - 3, y: y), NSPoint(x: w.maxX + 29, y: y))
        case .top:
            guard w.width > 100 else { return nil }
            let x = CGFloat.random(in: (w.minX + 40)...(w.maxX - 40))
            return (NSPoint(x: x, y: w.maxY + 5), NSPoint(x: x, y: w.maxY + 29))
        }
    }

    /// Desktop icon boxes, from Finder (asks once for permission), with which ones are folders.
    /// Refreshed every few minutes.
    private func readIcons() {
        guard Date().timeIntervalSince(iconsRead) > 300 else { return }
        iconsRead = Date()
        let script = """
            set out to ""
            tell application "Finder"
                repeat with i from 1 to (count of items of desktop)
                    set x to item i of desktop
                    set p to desktop position of x
                    set out to out & (item 1 of p) & tab & (item 2 of p) & tab & (class of x as text) & tab & (name of x) & linefeed
                end repeat
            end tell
            return out
            """
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let text = Self.osascript(script)
            let size = UserDefaults(suiteName: "com.apple.finder").flatMap { Self.iconSize(in: $0) } ?? 64
            DispatchQueue.main.async {
                guard let self else { return }
                let flip = NSScreen.screens.first?.frame.height ?? 0
                var all: [CGRect] = [], folders: [Icon] = []
                for line in text.split(separator: "\n") {
                    let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                    guard f.count == 4, let x = Double(f[0]), let y = Double(f[1]) else { continue }
                    // Finder gives each icon's centre, measured from the top of the main screen.
                    let rect = CGRect(x: x - size / 2, y: flip - y - size / 2, width: size, height: size)
                    all.append(rect)
                    if f[2] == "folder" || f[2] == "disk" {
                        let id = -2000 - folders.count
                        folders.append(Icon(id: id, rect: rect, name: String(f[3])))
                        self.folderNames[id] = String(f[3])
                    }
                }
                self.icons = all
                self.desktopFolders = folders
            }
        }
    }

    private static func iconSize(in finder: UserDefaults) -> Double? {
        let view = finder.dictionary(forKey: "DesktopViewSettings")?["IconViewSettings"] as? [String: Any]
        return (view?["iconSize"] as? NSNumber)?.doubleValue
    }
}

#if DEBUG
/// Test hooks for `./build.sh debug`: post a "pet.debug" distributed notification whose object is a
/// command: out, hide[:window|icon|dock], call, home, energy:0.1, react:<name>, mouse:x,y, tap, drag:on|off, eat:<path>, dockhop,
/// pickup, drop, click, app:<bundle id>, folder, dump. `dump` writes the pet's state to
/// ~/Library/Logs/ClaudeUsage/pet-debug.json.
extension Pet {
    func listenForDebugCommands() {
        DistributedNotificationCenter.default().addObserver(forName: .init("pet.debug"), object: nil, queue: .main) { [weak self] note in
            guard let self, let cmd = note.object as? String else { return }
            let arg = cmd.split(separator: ":").dropFirst().joined(separator: ":")
            switch cmd.split(separator: ":").first ?? "" {
            case "out":
                let p = self.outingPlan()
                guard !p.isEmpty else { return self.dump(note: "nowhere to go") }
                self.leaveHome(); self.plan = p; self.stepStart = nil
            case "hide":
                self.readIcons()
                let spot = self.findSpot { s in
                    switch (arg, s.layer) {
                    case ("", _), ("window", .behind), ("icon", .underIcons), ("dock", .underDock): return true
                    default: return false
                    }
                }
                guard let spot else { return self.dump(note: "no spot for \(arg)") }
                self.leaveHome(); self.plan = self.hidePlan(spot); self.stepStart = nil
            case "call": self.call()
            case "home": self.goHomeNow()
            case "energy": self.setEnergy(Double(arg) ?? 0.7)
            case "react": self.interject(arg, 4)
            case "mouse":  // "mouse:x,y" fakes the cursor position; "mouse:" gives the real one back
                let xy = arg.split(separator: ",").compactMap { Double($0) }
                self.fakeMouse = xy.count == 2 ? NSPoint(x: xy[0], y: xy[1]) : nil
            case "tap": self.tapped()
            case "pickup": self.carrying = true; self.pickUp()
            case "drop": self.carrying = false; self.drop()
            case "click":  // a click right next to it
                self.lastStartle = .distantPast
                if !self.atHome { self.interject("startle", 0.9) }
            case "app": self.switchedTo(arg)
            case "drag":  // "drag:on" pretends a file is being dragged (move it with mouse:x,y); "drag:off" ends it
                self.fileDrag = arg == "on"
            case "hold":  // "hold:x,y" parks it there (top-left screen coordinates) for two minutes
                let xy = arg.split(separator: ",").compactMap { Double($0) }
                guard xy.count == 2 else { return }
                self.leaveHome()
                self.endHiding()
                self.leaveSurface()
                self.place(NSPoint(x: xy[0], y: (NSScreen.screens.first?.frame.height ?? 0) - xy[1]))
                self.plan = [.wait(120), .flyHome, .settle]
                self.stepStart = nil
            case "droptypes":  // which views in the pet's window are registered for drops
                func walk(_ v: NSView, _ depth: Int) -> [String] {
                    ["\(String(repeating: "  ", count: depth))\(type(of: v)) \(v.registeredDraggedTypes.map(\.rawValue))"]
                        + v.subviews.flatMap { walk($0, depth + 1) }
                }
                self.dump(note: (walk(self.root, 0) + walk(self.mouth, 0)).joined(separator: "\n") + "\nignoresMouse=\(self.panel.ignoresMouseEvents)")
            case "bedclick": self.bedClicked()
            case "bedstate":  // what the bed page itself thinks
                self.bedWeb.evaluateJavaScript("JSON.stringify({occupied: bedOccupied, bedmode: BEDMODE})") { r, e in
                    self.dump(note: "bed page: \(r ?? e?.localizedDescription ?? "nothing")")
                }
            case "focusfor":  // "focusfor:20" runs a focus session that short, in seconds; "focusfor:20@x,y" puts the desk there
                let parts = arg.split(separator: "@")
                self.startFocus(minutes: 25)  // says 25 min, but really lasts this long
                self.focus = (Date(), Date().addingTimeInterval(Double(parts.first ?? "") ?? 20))
                let xy = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Double($0) } : []
                if xy.count == 2, self.plan.count > 2 {
                    self.plan[2] = .fly(to: NSPoint(x: xy[0], y: (NSScreen.screens.first?.frame.height ?? 0) - xy[1] + 40))
                }
            case "homeat":  // "homeat:x,y" moves the bed's corner (top-left screen points); "homeat:" puts it back
                let xy = arg.split(separator: ",").compactMap { Double($0) }
                self.homeOverride = xy.count == 2 ? NSPoint(x: xy[0], y: (NSScreen.screens.first?.frame.height ?? 0) - xy[1]) : nil
                self.placeBed()
                if self.inBed { self.place(self.homeCenter) }
            case "focusend": self.endFocus()
            case "focuskey": self.focusKey()
            case "awake":  // "awake:20" leaves it that many seconds before bedtime
                self.awakeUntil = Date().addingTimeInterval(Double(arg) ?? 0)
            case "curious":  // "curious:150" pretends it woke up that many seconds ago
                self.awakeSince = Date().addingTimeInterval(-(Double(arg) ?? 0))
            case "trash":  // what's in the Trash, by name, as Finder sees it
                DispatchQueue.global().async {
                    let names = Self.osascript("tell application \"Finder\" to get name of every item of trash")
                    DispatchQueue.main.async { self.dump(note: "trash: " + names) }
                }
            case "eat":  // "eat:/path" feeds it that file, as a drop would
                self.setGape(3)
                self.dump(note: "ate: \(self.dropped([URL(fileURLWithPath: arg)]))")
            case "dockhop":
                guard let i = self.currentDockIcons().randomElement() else { return self.dump(note: "no dock icons") }
                self.leaveHome()
                self.plan = [.fly(to: NSPoint(x: i.rect.midX, y: i.rect.maxY + Self.half + 50)), .fall, .stroll(40), .flyHome, .settle]
                self.stepStart = nil
            case "folder":  // "folder:any" treats the front standable window as a just-opened folder
                let finder = self.currentFinderPid
                guard let w = self.world.first(where: {
                    $0.isNormal && $0.pid != self.myPid && (arg == "any" ? self.canStand(on: $0.rect) : $0.pid == finder)
                }) else { return self.dump(note: "no folder window") }
                let s = Surface(id: w.id, minX: w.rect.minX, maxX: w.rect.maxX, y: w.rect.maxY)
                let ahead = self.world.prefix { $0.id != w.id }.filter { $0.isNormal }.map { "\($0.id)@\(NSStringFromRect($0.rect))" }
                self.readFolderNames(); self.noticeFolder(w.id)
                self.dump(note: "folder \(w.id) \(NSStringFromRect(w.rect)) canStand=\(self.canStand(on: w.rect)) spans=\(self.openSpans(s)) area=\(NSStringFromRect(self.homeArea)) in front: \(ahead)")
            case "names":  // what Finder says about its windows, raw, errors included
                DispatchQueue.global().async {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    p.arguments = ["-e", Self.folderScript]
                    let out = Pipe()
                    p.standardOutput = out
                    p.standardError = out
                    try? p.run()
                    let raw = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    p.waitUntilExit()
                    DispatchQueue.main.async { self.dump(note: "finder (exit \(p.terminationStatus)): " + raw) }
                }
            case "idle":  // "idle:900" acts as if your last input was that long ago; "idle:" goes back to the real one
                if let s = Double(arg) {
                    let last = Date().addingTimeInterval(-s)
                    self.fakeLastInput = last
                    self.lastActive = min(self.lastActive, last)
                } else {
                    self.fakeLastInput = nil
                }
            case "input": self.fakeLastInput = Date()  // you just touched something
            case "hour": self.fakeHour = Int(arg)       // "hour:23" pretends it's 11pm; "hour:" is the real time
            case "newday": self.seenDay = ""            // the next hello counts as the first of the day
            case "nudge": self.lastNudge = .distantPast
            case "stir": self.bedJS("B.stir()")
            case "dump": self.dump(note: "")
            default: break
            }
        }
    }

    private func dump(note: String) {
        let step = plan.first.map { String(describing: $0).components(separatedBy: "(").first ?? "" } ?? "none"
        let info: [String: Any] = [
            "note": note, "pos": [pos.x, pos.y], "frame": NSStringFromRect(panel.frame), "level": panel.level.rawValue,
            "layer": String(describing: layer), "step": step, "steps": plan.count, "atHome": atHome, "mode": sentMode,
            "hiding": hiding.map { ["center": [$0.center.x, $0.center.y], "side": $0.side.rawValue, "cover": $0.cover.map(NSStringFromRect) ?? ""] } ?? NSNull(),
            "standing": standing.map { ["id": $0.id, "y": $0.y, "span": [$0.minX, $0.maxX]] } ?? NSNull(),
            "occluders": occluders.map(NSStringFromRect), "masked": root.layer?.mask != nil, "icons": icons.count,
            "folders": folderNames.map { "\($0.key)=\($0.value)" }, "gear": gear, "quiet": quiet, "history": history,
            "clickThrough": panel.ignoresMouseEvents, "energy": energy, "visible": panel.isVisible, "gape": gape,
            "inBed": inBed, "awakeFor": max(0, awakeUntil.timeIntervalSinceNow), "curiosity": curiosity, "bedReady": bedReady,
            "bedURL": bedWeb.url?.absoluteString ?? "none", "bedLoading": bedWeb.isLoading,
            "focusLeft": focus.map { $0.end.timeIntervalSinceNow } ?? NSNull(),
            "focusToday": UserDefaults.standard.integer(forKey: "focusCount"),
            "mouse": [mouse.x, mouse.y], "over": body(at: pos).insetBy(dx: -3, dy: -3).contains(mouse), "covered": covered(mouse),
            "idle": idleSeconds, "lastActiveAgo": Date().timeIntervalSince(lastActive), "hour": hour, "sky": sky,
            "seenDay": seenDay, "nudgeAgo": min(Date().timeIntervalSince(lastNudge), 1e9),
            "bed": NSStringFromRect(bed.frame), "bedVisible": bed.isVisible, "petVisible": panel.isVisible,
            "dock": dockIcons.0.map { "\($0.name)@\(Int($0.rect.midX)),\(Int($0.rect.maxY))" }, "ax": AXIsProcessTrusted(),
            "desktopFolders": desktopFolders.map { "\($0.name)@\(Int($0.rect.midX)),\(Int($0.rect.maxY))" },
        ]
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClaudeUsage/pet-debug.json")
        try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}
#endif

/// Takes file drops, but only while the pet's mouth is open.
final class PetDropView: NSView {
    var canEat: () -> Bool = { false }
    var eat: ([URL]) -> Bool = { _ in false }
    var log: (String) -> Void = { _ in }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        log("file over the mouth (mouth open: \(canEat()))")
        return operation(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }

    /// Never "move" or "delete": those tell the source app it may remove the file itself.
    private func operation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canEat() else { return [] }
        let offered = sender.draggingSourceOperationMask
        return offered.contains(.generic) ? .generic : offered.contains(.copy) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return eat(urls)
    }
}

/// Never takes keyboard focus away from whatever you're typing in.
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    /// Its transparent top may tuck under the menu bar; don't let AppKit push it down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - Global shortcut

/// A system-wide shortcut. Carbon's hot keys need no Accessibility permission.
final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private var ref: EventHotKeyRef?

    init(key: Int, modifiers: Int, action: @escaping () -> Void) {
        let id = UInt32(Self.actions.count + 1)
        if Self.actions.isEmpty {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                HotKey.actions[hk.id]?()
                return noErr
            }, 1, &spec, nil, nil)
        }
        Self.actions[id] = action
        RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: OSType(0x5045_5421), id: id),
                            GetApplicationEventTarget(), 0, &ref)
    }
}
