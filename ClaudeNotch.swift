// ClaudeNotch: hover the MacBook notch to see Claude usage for every claude-swap account.
// Data sources:
//   usage    `claude-swap list --json` (uses claude-swap's own usage cache and polling)
//   activity Claude Code's own `sessions/<pid>.json` files, which carry `status: busy | idle | waiting`,
//            read from ~/.claude/sessions and every ~/.claude-swap-backup/sessions/<N-email>/sessions.
import AppKit
import IOKit.pwr_mgt
import SwiftUI

let claudeOrange = Color(red: 0.851, green: 0.467, blue: 0.341)  // #D97757
let askBlue = Color(red: 0.353, green: 0.659, blue: 1.0)  // #5AA8FF: a session waits for your answer
let lemburPurple = Color(red: 0.722, green: 0.592, blue: 1.0)  // #B897FF: mode lembur holds the Mac awake

// MARK: - Data

struct Session: Identifiable, Equatable {
    let pid: Int32
    let name: String
    let cwd: String
    let status: String
    let waitingFor: String?
    let account: Int?  // nil: a plain `claude` on ~/.claude, which runs as claude-swap's default account
    var id: Int32 { pid }
    // `waiting` with "dialog open" is a dialog you opened yourself (a slash command), not Claude asking.
    var needsYou: Bool { status == "waiting" && waitingFor != "dialog open" }
    var working: Bool { status != "idle" && status != "waiting" }
    // Claude Code's own grouping: "input needed" is a question, every other wait is a permission.
    var ask: String { waitingFor == "input needed" ? "question" : "permission" }
    var folder: String { (cwd as NSString).lastPathComponent }
}

private struct SessionFile: Decodable {
    let pid: Int32
    let name: String?
    let cwd: String?
    let status: String?
    let waitingFor: String?
}

struct Limit: Decodable {
    let pct: Double
    let countdown: String?
}

struct Usage: Decodable {
    let fiveHour: Limit?
    let sevenDay: Limit?
}

struct Account: Decodable, Identifiable {
    let number: Int
    let email: String
    let alias: String?
    let active: Bool
    let usageStatus: String?
    let usage: Usage?
    var id: Int { number }
    var label: String { alias ?? String(email.split(separator: "@").first ?? Substring(email)) }
}

struct Payload: Decodable {
    let accounts: [Account]
}

// What a session file's status cannot see: a background subagent writes its own transcript while
// the session reads `idle`, and a background Bash task is a shell the session still owns.
struct Activity {
    var lastWrite: Date?  // newest write to any transcript, subagents included
    var shells = 0  // Bash tool shells still running under a live session
}

final class Model: ObservableObject {
    static let cli = NSHomeDirectory() + "/.local/bin/claude-swap"

    @Published var accounts: [Account] = []
    @Published var error: String?
    @Published var updatedAt: Date?
    @Published var expanded = false
    @Published var contentSize: CGSize = .zero
    @Published var sessions: [Session] = []
    @Published var notice: String?

    // Mode lembur: one-shot. It holds the Mac awake until every agent on this Mac stops, then sleeps it.
    @Published var lembur = false
    @Published var sleepAt: Date?  // when the current quiet streak ends in sleep; nil while anything runs

    private var loading = false
    private var cycle: [Int: Int] = [:]
    private var noticeWork: DispatchWorkItem?
    private var assertion = IOPMAssertionID(0)
    private var activity = Activity()
    private var scannedAt = Date.distantPast
    private var scanning = false
    private var quietSince: Date?

    static let quietFor: TimeInterval = 120  // every session idle this long before the sleep
    static let transcriptQuiet: TimeInterval = 180  // no transcript write for this long
    static let scanEvery: TimeInterval = 10

    var active: Account? { accounts.first(where: \.active) }
    var working: [Session] { sessions.filter(\.working) }
    var needsYou: [Session] { sessions.filter(\.needsYou) }

    func workingCount(account: Int) -> Int { working.filter { accountOf($0) == account }.count }
    func needsYouCount(account: Int) -> Int { needsYou.filter { accountOf($0) == account }.count }

    // claude-swap's `active` is the account holding ~/.claude: the one a plain `claude` uses,
    // while `claude-swap run N` tabs carry their own config dir.
    func accountOf(_ s: Session) -> Int? { s.account ?? active?.number }

    // Sessions waiting for you first, then working ones, so the first click lands where you are needed.
    func sessions(account: Int) -> [Session] {
        func rank(_ s: Session) -> Int { s.needsYou ? 0 : s.working ? 1 : 2 }
        return sessions.filter { accountOf($0) == account }.sorted { (rank($0), $0.name) < (rank($1), $1.name) }
    }

    // Each click on the same account steps to its next open session.
    func open(account: Int) {
        let list = sessions(account: account)
        guard !list.isEmpty else { return }
        let i = cycle[account, default: 0] % list.count
        cycle[account] = i + 1
        open(list[i])
    }

    func open(_ s: Session) {
        guard let problem = TerminalFocus.focus(pid: s.pid) else { return }
        show(problem)
    }

    private func show(_ problem: String) {
        noticeWork?.cancel()
        notice = problem
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func refreshSessions() {
        DispatchQueue.global(qos: .utility).async {
            let found = Self.scanSessions()
            DispatchQueue.main.async {
                if found != self.sessions { self.sessions = found }
                self.checkLembur()
            }
        }
    }

    func toggleLembur() {
        if lembur { endLembur(); return }
        let made = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "ClaudeNotch mode lembur: agents are still running" as CFString, &assertion)
        guard made == kIOReturnSuccess else { show("Could not hold the Mac awake (IOKit \(made))"); return }
        lembur = true
        quietSince = nil
        scannedAt = .distantPast
        checkLembur()
    }

    private func endLembur() {
        if lembur { IOPMAssertionRelease(assertion) }
        lembur = false
        sleepAt = nil
        quietSince = nil
    }

    // Runs every second. The Mac sleeps only when no session works, no Bash shell runs, no transcript
    // was written for `transcriptQuiet`, all of that held for `quietFor`, and a scan made after the
    // deadline still agrees. Any activity restarts the streak.
    private func checkLembur() {
        guard lembur else { return }
        let now = Date()
        let due = sleepAt.map { now >= $0 } ?? false
        if !scanning, now.timeIntervalSince(scannedAt) >= Self.scanEvery || (due && scannedAt < sleepAt!) {
            scanning = true
            let pids = Set(sessions.map(\.pid))
            DispatchQueue.global(qos: .utility).async {
                let found = Self.scanActivity(sessionPids: pids)
                DispatchQueue.main.async {
                    self.activity = found
                    self.scannedAt = Date()
                    self.scanning = false
                    self.checkLembur()
                }
            }
        }
        guard scannedAt != .distantPast else { return }
        let wrote = activity.lastWrite.map { now.timeIntervalSince($0) < Self.transcriptQuiet } ?? false
        if !working.isEmpty || activity.shells > 0 || wrote {
            quietSince = nil
            if sleepAt != nil { sleepAt = nil }
            return
        }
        let since = quietSince ?? now
        quietSince = since
        let at = since + Self.quietFor
        if sleepAt != at { sleepAt = at }
        if now >= at, scannedAt >= at { sleepNow() }
    }

    private func sleepNow() {
        endLembur()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["sleepnow"]
        do { try proc.run() } catch { show("pmset sleepnow failed: \(error.localizedDescription)") }
    }

    private static func scanActivity(sessionPids: Set<Int32>) -> Activity {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var roots = [home + "/.claude/projects"]
        let swap = home + "/.claude-swap-backup/sessions"
        for d in (try? fm.contentsOfDirectory(atPath: swap)) ?? [] { roots.append(swap + "/" + d + "/projects") }
        var newest: Date?
        for root in roots {
            guard let walk = fm.enumerator(at: URL(fileURLWithPath: root),
                                           includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let url as URL in walk where url.pathExtension == "jsonl" {
                guard let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                else { continue }
                if d > newest ?? .distantPast { newest = d }
            }
        }
        return Activity(lastWrite: newest, shells: shellCount(under: sessionPids))
    }

    // The Bash tool runs each command as a child `/bin/zsh -c source …/shell-snapshots/…` of its
    // session. MCP servers and Claude Code's own `caffeinate` are children too, so they do not count.
    private static func shellCount(under pids: Set<Int32>) -> Int {
        guard !pids.isEmpty else { return 0 }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "ppid=,command="]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return 0 }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let ppid = Int32(parts[0]) else { return false }
            return pids.contains(ppid) && parts[1].contains("/shell-snapshots/")
        }.count
    }

    private static func scanSessions() -> [Session] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var dirs: [(path: String, account: Int?)] = [(home + "/.claude/sessions", nil)]
        let swap = home + "/.claude-swap-backup/sessions"
        for d in (try? fm.contentsOfDirectory(atPath: swap)) ?? [] {
            dirs.append((swap + "/" + d + "/sessions", Int(d.prefix(while: \.isNumber))))
        }
        var seen = Set<Int32>()
        var out: [Session] = []
        for dir in dirs {
            for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".json") {
                guard let data = fm.contents(atPath: dir.path + "/" + f),
                      let s = try? JSONDecoder().decode(SessionFile.self, from: data),
                      isAlive(s.pid), seen.insert(s.pid).inserted else { continue }
                out.append(Session(pid: s.pid, name: s.name ?? "pid \(s.pid)", cwd: s.cwd ?? "",
                                   status: s.status ?? "idle", waitingFor: s.waitingFor, account: dir.account))
            }
        }
        return out.sorted { ($0.account ?? 0, $0.name) < ($1.account ?? 0, $1.name) }
    }

    // A crashed session leaves its file behind with a stale status, so only live pids count.
    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let result = Self.fetch()
            DispatchQueue.main.async {
                self.loading = false
                switch result {
                case .success(let accounts):
                    self.accounts = accounts
                    self.error = nil
                    self.updatedAt = Date()
                case .failure(let err):
                    self.error = err.localizedDescription
                }
            }
        }
    }

    private static func fetch() -> Result<[Account], Error> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cli)
        proc.arguments = ["list", "--json"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return .success(try JSONDecoder().decode(Payload.self, from: data).accounts)
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Terminal focus

// Finds the terminal app that owns a session's pid and brings that window to the front.
// iTerm2 and Terminal.app expose their tabs to AppleScript, so the tab with the session's tty is
// selected. Other terminals (Warp, Ghostty) have no tab API, so the app itself comes forward.
enum TerminalFocus {
    private static func info(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    static func tty(_ pid: Int32) -> String? {
        guard let dev = info(pid)?.kp_eproc.e_tdev, dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    // The first ancestor that is a regular app: iTerm2 above its iTermServer, Warp above its shell.
    static func app(_ pid: Int32) -> NSRunningApplication? {
        var p = pid
        for _ in 0..<16 {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular { return app }
            guard let parent = info(p)?.kp_eproc.e_ppid, parent > 1 else { return nil }
            p = parent
        }
        return nil
    }

    // nil when the terminal came forward; otherwise a short message for the footer.
    static func focus(pid: Int32) -> String? {
        guard let app = app(pid) else { return "Could not find the terminal for this session" }
        let name = app.localizedName ?? "the terminal"
        if let tty = tty(pid), let script = script(bundle: app.bundleIdentifier, tty: tty) {
            var err: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
            if result?.booleanValue == true { return nil }
            if (err?[NSAppleScript.errorNumber] as? Int) == -1743 {
                bringForward(app)
                return "Allow ClaudeNotch to control \(name): System Settings › Privacy › Automation"
            }
        }
        bringForward(app)
        return nil
    }

    // A background app cannot activate another one directly since macOS 14; a launch request can.
    private static func bringForward(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    private static func script(bundle: String?, tty: String) -> String? {
        switch bundle {
        case "com.googlecode.iterm2":
            return """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
        case "com.apple.Terminal":
            return """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        default:
            return nil
        }
    }
}

// MARK: - Views

func color(for pct: Double) -> Color {
    pct >= 80 ? .red : pct >= 50 ? .yellow : .green
}

struct NotchShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// The Claude starburst: rounded rays of uneven length around one centre.
// `wobble` 0 is the resting mark; 1 lets every ray breathe on its own beat of `phase`.
struct ClaudeMark: Shape {
    var phase: Double = 0
    var wobble: Double = 0
    static let rays: [Double] = [1.0, 0.74, 0.93, 0.68, 0.97, 0.79, 0.9, 0.7, 1.0, 0.77, 0.88, 0.72]

    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let radius = min(r.width, r.height) / 2
        let w = radius * 0.26
        var p = Path()
        for (i, length) in Self.rays.enumerated() {
            let angle = Double(i) / Double(Self.rays.count) * 2 * .pi - .pi / 2
            let beat = 0.5 + 0.5 * sin(phase * 4 + Double(i) * 1.7)
            let len = radius * length * (1 - wobble * 0.32 * beat) - w / 2
            let ray = Path(roundedRect: CGRect(x: -w / 2, y: -w / 2, width: len + w, height: w), cornerRadius: w / 2)
            p.addPath(ray, transform: CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle))
        }
        return p
    }
}

// Static mark when idle; while a session works it turns slowly and its rays breathe.
// Reduced motion keeps the static mark and lets the glow alone say "working".
// The motion is Core Animation on a CAShapeLayer, so it runs in the render server: a SwiftUI
// TimelineView or repeatForever re-rendered the hosting view every frame (6-18% CPU).
struct ClaudeLogo: View {
    let working: Bool
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MarkLayer(animating: working && !reduceMotion, glow: working)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(working ? "Claude is working" : "Claude is idle")
    }
}

private struct MarkLayer: NSViewRepresentable {
    let animating: Bool
    let glow: Bool

    func makeNSView(context: Context) -> MarkView { MarkView() }
    func updateNSView(_ view: MarkView, context: Context) { view.set(animating: animating, glow: glow) }
}

final class MarkView: NSView {
    private let shape = CAShapeLayer()
    private var animating = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shape.fillColor = NSColor(claudeOrange).cgColor
        shape.shadowColor = NSColor(claudeOrange).cgColor
        shape.shadowOffset = .zero
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        shape.frame = bounds
        shape.shadowRadius = bounds.width * 0.3
        shape.path = ClaudeMark().path(in: bounds).cgPath
        restart()
    }

    func set(animating: Bool, glow: Bool) {
        shape.shadowOpacity = glow ? 0.75 : 0
        guard animating != self.animating else { return }
        self.animating = animating
        restart()
    }

    private func restart() {
        shape.removeAllAnimations()
        guard animating, bounds.width > 0 else { return }
        // One beat of every ray is phase 0 to pi/2 (rays run at 4x phase), so the loop is seamless.
        let breathe = CAKeyframeAnimation(keyPath: "path")
        breathe.values = (0...24).map { ClaudeMark(phase: Double($0) / 24 * .pi / 2, wobble: 1).path(in: bounds).cgPath }
        breathe.duration = 1.4
        breathe.repeatCount = .infinity
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi  // clockwise on screen
        spin.duration = 8
        spin.repeatCount = .infinity
        for anim in [breathe, spin] as [CAAnimation] {
            anim.isRemovedOnCompletion = false
            shape.add(anim, forKey: (anim as? CAPropertyAnimation)?.keyPath)
        }
    }
}

// A dot that pulses while a session waits for you. Reduced motion keeps it lit and still.
struct PulseDot: NSViewRepresentable {
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> PulseView { PulseView() }
    func updateNSView(_ view: PulseView, context: Context) { view.set(animating: !reduceMotion) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PulseView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

final class PulseView: NSView {
    private let dot = CALayer()
    private var animating = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dot.backgroundColor = NSColor(askBlue).cgColor
        dot.shadowColor = NSColor(askBlue).cgColor
        dot.shadowOffset = .zero
        dot.shadowOpacity = 0.9
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        dot.frame = bounds
        dot.cornerRadius = bounds.width / 2
        dot.shadowRadius = bounds.width * 0.5
        restart()
    }

    func set(animating: Bool) {
        guard animating != self.animating else { return }
        self.animating = animating
        restart()
    }

    private func restart() {
        dot.removeAllAnimations()
        guard animating, bounds.width > 0 else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.3
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.isRemovedOnCompletion = false
        dot.add(pulse, forKey: "pulse")
    }
}

struct Meter: View {
    let title: String
    let limit: Limit?  // nil: the API sent no data for this window

    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 22, alignment: .leading).foregroundStyle(.white.opacity(0.5))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    if let limit {
                        let c = color(for: limit.pct)
                        Capsule()
                            .fill(LinearGradient(colors: [c.opacity(0.55), c], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, g.size.width * min(limit.pct, 100) / 100))
                            .shadow(color: c.opacity(0.5), radius: 3)
                    }
                }
            }
            .frame(height: 6)
            Text(limit.map { "\(Int($0.pct.rounded()))%" } ?? "–").frame(width: 34, alignment: .trailing)
            Text(limit?.countdown ?? "").frame(width: 50, alignment: .trailing).foregroundStyle(.white.opacity(0.45))
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        .foregroundStyle(.white)
    }
}

// Presses sink a touch; reduced motion keeps the colour change and drops the scale.
struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct Chip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(0.15)))
    }
}

// "iTerm2 ↗" on hover: where a click goes.
struct OpenHint: View {
    let app: String
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "terminal")
            Text(app)
            Image(systemName: "arrow.up.right")
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.16)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
    }
}

// Header toggle for mode lembur. Off: "Lembur". On: lit, and a countdown once everything is quiet.
struct LemburToggle: View {
    let on: Bool
    let sleepAt: Date?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: on ? "moon.zzz.fill" : "moon.zzz")
                if on, let sleepAt {
                    let now = Date()
                    Text("Sleep")
                    Text(timerInterval: now...max(sleepAt, now), countsDown: true).monospacedDigit()
                } else {
                    Text("Lembur")
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(on ? .black : .white.opacity(hovering ? 0.9 : 0.6))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(on ? lemburPurple : .white.opacity(hovering ? 0.14 : 0.08)))
            .shadow(color: on ? lemburPurple.opacity(0.5) : .clear, radius: 6)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .help(on ? "Mode lembur is on. Click to cancel. The Mac stays awake, then sleeps once every agent stops."
                 : "Keep the Mac awake until every Claude agent on this Mac stops, then sleep it.")
        .accessibilityLabel(on ? "Mode lembur on" : "Mode lembur off")
        .accessibilityHint(on ? "Cancels mode lembur" : "Keeps the Mac awake until every agent stops, then sleeps it")
    }
}

struct AccountRow: View {
    let account: Account
    let working: Int
    let waiting: Int
    let targets: [Session]  // open sessions of this account, working first
    let onOpen: () -> Void
    @State private var hovering = false
    @State private var app: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clickable: Bool { !targets.isEmpty }
    private var accent: Color { waiting > 0 ? askBlue : working > 0 ? claudeOrange : .white }
    private var lit: Bool { hovering && clickable }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("\(account.number)")
                        .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(lit ? .black : .white.opacity(0.75))
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5).fill(lit ? accent : .white.opacity(0.1)))
                    Text(account.label).font(.system(size: 12, weight: .semibold))
                    if account.active {
                        Chip(text: "default", tint: .green)
                            .help("Account in ~/.claude: what a plain `claude` runs as. `claude-swap run N` tabs use their own.")
                    }
                    if waiting > 0 { Chip(text: "\(waiting) waiting", tint: askBlue) }
                    if working > 0 { Chip(text: "\(working) working", tint: claudeOrange) }
                    Spacer(minLength: 4)
                    if let status = account.usageStatus, status != "ok" {
                        Text(status).font(.system(size: 10)).foregroundStyle(.orange)
                    }
                    if lit, let app {
                        OpenHint(app: targets.count > 1 ? "\(app) · \(targets.count)" : app, tint: accent)
                            .transition(.opacity.combined(with: .offset(x: reduceMotion ? 0 : 6)))
                    } else if hovering && !clickable {
                        Text("no open session")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                            .transition(.opacity)
                    }
                }
                .frame(height: 18)
                .foregroundStyle(.white)
                Meter(title: "5h", limit: account.usage?.fiveHour)
                // Team-plan seats report no 7d window, so the row only shows when the API sends one.
                if let w = account.usage?.sevenDay { Meter(title: "7d", limit: w) }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(background)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(lit ? accent.opacity(0.45) : .clear, lineWidth: 1))
            .shadow(color: lit ? accent.opacity(0.22) : .clear, radius: 10)
            .scaleEffect(lit && !reduceMotion ? 1.012 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PressStyle())
        .disabled(!clickable)
        .onHover { inside in
            if inside, let first = targets.first { app = TerminalFocus.app(first.pid)?.localizedName ?? "Terminal" }
            hovering = inside
        }
        .pointerStyle(clickable ? .link : nil)
        .animation(.easeOut(duration: 0.16), value: hovering)
        .help(targets.count > 1 ? "Click to open its terminal. Click again for the next of \(targets.count) sessions." : "")
        .accessibilityLabel("Account \(account.number), \(account.label)")
        .accessibilityHint(clickable ? "Opens its terminal" : "No open session")
    }

    private var background: Double {
        let base = account.active ? 0.07 : 0.03
        return hovering ? base + (clickable ? 0.06 : 0.02) : base
    }
}

struct SessionRow: View {
    let session: Session
    let account: Int?
    let onOpen: () -> Void
    @State private var hovering = false

    private var tint: Color { session.needsYou ? askBlue : claudeOrange }
    // A waiting session names what it waits for; a working one only names an unusual status.
    private var label: String? {
        session.needsYou ? session.ask : session.status != "busy" ? session.status : nil
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 7) {
                Circle().fill(tint).frame(width: 5, height: 5)
                    .shadow(color: tint.opacity(hovering ? 0.9 : 0), radius: 3)
                Text(session.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                Text(session.folder).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                Spacer()
                if let label {
                    Text(label).font(.system(size: 9.5)).foregroundStyle(tint.opacity(0.85))
                }
                if let n = account {
                    Text("#\(n)").font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(hovering ? 0.14 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .accessibilityHint("Opens its terminal")
    }
}

struct RootView: View {
    @ObservedObject var model: Model
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    static let wing: CGFloat = 84
    static let maxSessions = 5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .background(NotchShape(radius: model.expanded ? 22 : 9).fill(.black))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { model.contentSize = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82), value: model.working)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82), value: model.needsYou)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82), value: model.lembur)
    }

    @ViewBuilder private var content: some View {
        if model.expanded {
            VStack(alignment: .leading, spacing: 10) {
                header
                if !model.needsYou.isEmpty { sessionList(model.needsYou, tint: askBlue) }
                if !model.working.isEmpty { sessionList(model.working, tint: claudeOrange) }
                ForEach(model.accounts) { a in
                    AccountRow(account: a, working: model.workingCount(account: a.number),
                               waiting: model.needsYouCount(account: a.number),
                               targets: model.sessions(account: a.number)) { model.open(account: a.number) }
                }
                HStack {
                    if let notice = model.notice {
                        Text(notice).foregroundStyle(.orange).lineLimit(2)
                    } else if let err = model.error {
                        Text(err).foregroundStyle(.orange).lineLimit(2)
                    } else if model.lembur {
                        Text(model.sleepAt == nil ? "Lembur: waiting for every agent to stop"
                                                  : "Lembur: all quiet. Any activity restarts the countdown")
                            .foregroundStyle(lemburPurple.opacity(0.8))
                    } else if let t = model.updatedAt {
                        Text("updated \(t.formatted(date: .omitted, time: .shortened))")
                    }
                    Spacer()
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.top, notchHeight + 8)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .frame(width: 380)
            .transition(.opacity)
        } else {
            HStack(spacing: 0) {
                statusWing
                Color.clear.frame(width: notchWidth)
                usageWing
            }
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(height: notchHeight)
            .transition(.opacity)
        }
    }

    private var header: some View {
        let n = model.working.count
        let w = model.needsYou.count
        return HStack(spacing: 10) {
            ClaudeLogo(working: n > 0, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                HStack(spacing: 6) {
                    if w > 0 {
                        Text("Waiting for you · \(w)").foregroundStyle(askBlue)
                    }
                    if n > 0 {
                        Text("Working · \(n) session\(n == 1 ? "" : "s")").foregroundStyle(claudeOrange)
                    }
                    if w == 0 && n == 0 {
                        Text("Idle").foregroundStyle(.white.opacity(0.45))
                    }
                }
                .font(.system(size: 10.5, weight: .medium))
                .contentTransition(.opacity)
            }
            Spacer()
            LemburToggle(on: model.lembur, sleepAt: model.sleepAt) { model.toggleLembur() }
        }
        .padding(.bottom, 2)
    }

    private func sessionList(_ list: [Session], tint: Color) -> some View {
        let shown = list.prefix(Self.maxSessions)
        let rest = list.count - shown.count
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(shown) { s in SessionRow(session: s, account: model.accountOf(s)) { model.open(s) } }
            if rest > 0 {
                Text("+\(rest) more").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).padding(.leading, 6)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.22), lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // Left of the notch: the Claude mark, how many sessions are working, and a pulsing blue dot
    // with a count when a session waits for your answer.
    private var statusWing: some View {
        let n = model.working.count
        let w = model.needsYou.count
        return HStack(spacing: 5) {
            ClaudeLogo(working: n > 0, size: 16)
            if n > 0 {
                Text("\(n)").foregroundStyle(claudeOrange).transition(.opacity.combined(with: .scale))
            }
            if w > 0 {
                HStack(spacing: 3) {
                    PulseDot(size: 6)
                    Text("\(w)").foregroundStyle(askBlue)
                }
                .transition(.opacity.combined(with: .scale))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(w) session\(w == 1 ? "" : "s") waiting for you")
            }
            if model.lembur {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(lemburPurple)
                    .transition(.opacity.combined(with: .scale))
                    .accessibilityLabel("Mode lembur on")
            }
        }
        .frame(width: Self.wing)
    }

    // Right of the notch: one 5h gauge per account (the active one lit), plus the active account's %.
    private var usageWing: some View {
        let pct = model.active?.usage?.fiveHour?.pct
        return HStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(model.accounts) { a in
                    let p = a.usage?.fiveHour?.pct ?? 0
                    ZStack(alignment: .bottom) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(color(for: p)).frame(height: max(2, 13 * min(p, 100) / 100))
                    }
                    .frame(width: 4, height: 13)
                    .opacity(a.active ? 1 : 0.45)
                }
            }
            Text(pct.map { "\(Int($0.rounded()))%" } ?? "–")
                .foregroundStyle(pct.map(color(for:)) ?? .white.opacity(0.5))
        }
        .frame(width: Self.wing)
    }
}

// MARK: - Window

// Once the panel takes mouse events the global monitor goes quiet over it, so the view reports
// moves itself. First mouse: a click on a row works while another app is frontmost.
final class HostingView: NSHostingView<RootView> {
    var onMouseMove: (() -> Void)?
    private var tracker: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracker { removeTrackingArea(tracker) }
        let t = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracker = t
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMove?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseMove?()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    var panel: NSPanel!
    var collapseWork: DispatchWorkItem?
    static let panelSize = CGSize(width: 420, height: 640)

    func applicationDidFinishLaunching(_ note: Notification) {
        buildPanel()
        model.refresh()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.model.refresh() }
        // Session files are a handful of tiny JSON reads, so a 1s poll keeps the logo honest.
        model.refreshSessions()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.model.refreshSessions() }
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in self?.trackMouse() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.buildPanel() }
    }

    var screen: NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    var notchSize: CGSize {
        let s = screen
        guard s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else {
            return CGSize(width: 180, height: NSStatusBar.system.thickness)
        }
        return CGSize(width: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top)
    }

    func buildPanel() {
        panel?.orderOut(nil)
        let size = Self.panelSize
        let f = screen.frame
        panel = NSPanel(contentRect: NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        let n = notchSize
        let host = HostingView(rootView: RootView(model: model, notchWidth: n.width, notchHeight: n.height))
        host.onMouseMove = { [weak self] in self?.trackMouse() }
        panel.contentView = host
        panel.orderFrontRegardless()
    }

    // Visible black shape in screen coordinates, anchored to the top center of the panel.
    var hotRect: NSRect {
        let size = model.contentSize
        let f = panel.frame
        return NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
    }

    func trackMouse() {
        let inside = hotRect.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        if inside {
            collapseWork?.cancel()
            collapseWork = nil
            if !model.expanded {
                setExpanded(true)
                model.refresh()
            }
        } else if model.expanded, collapseWork == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.collapseWork = nil
                self?.setExpanded(false)
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        // Clicks land only on the open shape; everywhere else they fall through to the app below.
        panel.ignoresMouseEvents = !(inside && model.expanded)
    }

    func setExpanded(_ value: Bool) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            model.expanded = value
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { model.expanded = value }
        }
    }
}

@main
struct ClaudeNotchApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
