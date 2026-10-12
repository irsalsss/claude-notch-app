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

    private var loading = false

    var active: Account? { accounts.first(where: \.active) }
    var working: [Session] { sessions.filter(\.working) }

    func workingCount(account: Int) -> Int { working.filter { accountOf($0) == account }.count }

    // claude-swap's `active` is the account holding ~/.claude: the one a plain `claude` uses,
    // while `claude-swap run N` tabs carry their own config dir.
    func accountOf(_ s: Session) -> Int? { s.account ?? active?.number }

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

struct AccountRow: View {
    let account: Account
    let working: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("\(account.number) · \(account.label)").font(.system(size: 12, weight: .semibold))
                if account.active {
                    Text("default")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.green.opacity(0.14)))
                        .help("Account in ~/.claude: what a plain `claude` runs as. `claude-swap run N` tabs use their own.")
                }
                if working > 0 {
                    Text("\(working) working")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(claudeOrange)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(claudeOrange.opacity(0.16)))
                }
                Spacer()
                if let status = account.usageStatus, status != "ok" {
                    Text(status).font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            .foregroundStyle(.white)
            Meter(title: "5h", limit: account.usage?.fiveHour)
            // Team-plan seats report no 7d window, so the row only shows when the API sends one.
            if let w = account.usage?.sevenDay { Meter(title: "7d", limit: w) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(account.active ? 0.07 : 0.03)))
    }
}

struct SessionRow: View {
    let session: Session
    let account: Int?

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(claudeOrange).frame(width: 5, height: 5)
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
        }
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
                ForEach(model.accounts) { AccountRow(account: $0, working: model.workingCount(account: $0.number)) }
                HStack {
                    if let err = model.error {
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
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(shown) { SessionRow(session: $0, account: model.accountOf($0)) }
            if rest > 0 {
                Text("+\(rest) more").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(10)
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
        panel.contentView = NSHostingView(rootView: RootView(model: model, notchWidth: n.width, notchHeight: n.height))
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
