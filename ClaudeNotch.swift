// ClaudeNotch: hover the MacBook notch to see Claude usage for every claude-swap account.
// Data sources:
//   usage    `claude-swap list --json` (uses claude-swap's own usage cache and polling)
//   activity Claude Code's own `sessions/<pid>.json` files, which carry `status: busy | idle`,
//            read from ~/.claude/sessions and every ~/.claude-swap-backup/sessions/<N-email>/sessions.
import AppKit
import SwiftUI

let claudeOrange = Color(red: 0.851, green: 0.467, blue: 0.341)  // #D97757

// MARK: - Data

struct Session: Identifiable, Equatable {
    let pid: Int32
    let name: String
    let cwd: String
    let status: String
    let account: Int?  // nil: a plain `claude` on ~/.claude, which runs as claude-swap's default account
    var id: Int32 { pid }
    var working: Bool { status != "idle" }
    var folder: String { (cwd as NSString).lastPathComponent }
}

private struct SessionFile: Decodable {
    let pid: Int32
    let name: String?
    let cwd: String?
    let status: String?
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

final class Model: ObservableObject {
    static let cli = NSHomeDirectory() + "/.local/bin/claude-swap"

    @Published var accounts: [Account] = []
    @Published var error: String?
    @Published var updatedAt: Date?
    @Published var expanded = false
    @Published var contentSize: CGSize = .zero
    @Published var sessions: [Session] = []
    @Published var notice: String?

    private var loading = false
    private var cycle: [Int: Int] = [:]
    private var noticeWork: DispatchWorkItem?

    var active: Account? { accounts.first(where: \.active) }
    var working: [Session] { sessions.filter(\.working) }

    func workingCount(account: Int) -> Int { working.filter { accountOf($0) == account }.count }

    // claude-swap's `active` is the account holding ~/.claude: the one a plain `claude` uses,
    // while `claude-swap run N` tabs carry their own config dir.
    func accountOf(_ s: Session) -> Int? { s.account ?? active?.number }

    // Working sessions first, so the first click lands where Claude is busy.
    func sessions(account: Int) -> [Session] {
        sessions.filter { accountOf($0) == account }.sorted { ($0.working ? 0 : 1, $0.name) < ($1.working ? 0 : 1, $1.name) }
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
            }
        }
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
                                   status: s.status ?? "idle", account: dir.account))
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

struct AccountRow: View {
    let account: Account
    let working: Int
    let targets: [Session]  // open sessions of this account, working first
    let onOpen: () -> Void
    @State private var hovering = false
    @State private var app: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clickable: Bool { !targets.isEmpty }
    private var accent: Color { working > 0 ? claudeOrange : .white }
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

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 7) {
                Circle().fill(claudeOrange).frame(width: 5, height: 5)
                    .shadow(color: claudeOrange.opacity(hovering ? 0.9 : 0), radius: 3)
                Text(session.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                Text(session.folder).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                Spacer()
                if session.status != "busy" {
                    Text(session.status).font(.system(size: 9.5)).foregroundStyle(claudeOrange.opacity(0.85))
                }
                if let n = account {
                    Text("#\(n)").font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(claudeOrange)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(claudeOrange.opacity(hovering ? 0.14 : 0)))
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
    }

    @ViewBuilder private var content: some View {
        if model.expanded {
            VStack(alignment: .leading, spacing: 10) {
                header
                if !model.working.isEmpty { sessions }
                ForEach(model.accounts) { a in
                    AccountRow(account: a, working: model.workingCount(account: a.number),
                               targets: model.sessions(account: a.number)) { model.open(account: a.number) }
                }
                HStack {
                    if let notice = model.notice {
                        Text(notice).foregroundStyle(.orange).lineLimit(2)
                    } else if let err = model.error {
                        Text(err).foregroundStyle(.orange).lineLimit(2)
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
        return HStack(spacing: 10) {
            ClaudeLogo(working: n > 0, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(n > 0 ? "Working · \(n) session\(n == 1 ? "" : "s")" : "Idle")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(n > 0 ? claudeOrange : .white.opacity(0.45))
                    .contentTransition(.opacity)
            }
            Spacer()
        }
        .padding(.bottom, 2)
    }

    private var sessions: some View {
        let shown = model.working.prefix(Self.maxSessions)
        let rest = model.working.count - shown.count
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(shown) { s in SessionRow(session: s, account: model.accountOf(s)) { model.open(s) } }
            if rest > 0 {
                Text("+\(rest) more").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).padding(.leading, 6)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10).fill(claudeOrange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(claudeOrange.opacity(0.22), lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // Left of the notch: the Claude mark, and how many sessions are working right now.
    private var statusWing: some View {
        let n = model.working.count
        return HStack(spacing: 5) {
            ClaudeLogo(working: n > 0, size: 16)
            if n > 0 {
                Text("\(n)").foregroundStyle(claudeOrange).transition(.opacity.combined(with: .scale))
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
