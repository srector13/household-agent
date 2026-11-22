import SecondBrainKit
import SwiftUI
import UserNotifications

// MARK: - More

struct MoreView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        List {
            Section {
                link(.activity(status: nil), "Activity", "list.bullet.rectangle", .cyan)
                link(.today, "Plan my days", "sun.max.fill", .yellow)
                link(.weekly, "Weekly reset", "sparkles", .green)
            }
            Section {
                link(.status, "Status", "server.rack", .gray)
                link(.settings, "Settings", "gearshape.fill", .gray)
                link(.server, "Server & notifications", "antenna.radiowaves.left.and.right", .blue)
            }
            Section {
                Picker(selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                } label: {
                    Label { Text("Appearance") } icon: { IconTile(symbol: "circle.lefthalf.filled", color: .slate, size: 29) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("appearance")
            } footer: {
                Text("The app icon follows your Home Screen: long-press it → Edit → Customize → Dark or Tinted.")
            }
            if let i = app.info {
                Section {
                    LabeledContent("Brain", value: i.version)
                    LabeledContent("App", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                    if let u = i.publicUrl, let url = URL(string: u) {
                        Link(destination: url) { Label("Open the web dashboard", systemImage: "safari") }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("More")
    }

    private func link(_ r: Route, _ title: String, _ symbol: String, _ color: Color) -> some View {
        NavigationLink(value: r) {
            Label { Text(title) } icon: { IconTile(symbol: symbol, color: color, size: 29) }
        }
    }
}

// MARK: - Status

struct StatusView: View {
    var body: some View {
        Loader({ try await $0.system() }) { s in StatusList(s: s) }
            .navigationTitle("Status")
    }
}

private struct StatusList: View {
    @Environment(AppModel.self) private var app
    let s: SystemStatus

    var body: some View {
        let h = s.health
        List {
            Section("Pipeline") {
                row("Mac agent", ok: h.agentOnline,
                    detail: h.agentOnline ? "online" + (h.agentVersion.map { " · v\($0)" } ?? "")
                        : (h.agent["last_seen_s_ago"]?.int.map { "last seen \(ago($0))" } ?? "not connected yet"))
                if h.agentVersion != nil {
                    row("Messages access", ok: h.agentFlag("fda_ok") ?? false, detail: (h.agentFlag("fda_ok") ?? false) ? "Full Disk Access" : "missing Full Disk Access")
                    row("Reminders", ok: h.agentFlag("reminders_ok") ?? false, detail: (h.agentFlag("reminders_ok") ?? false) ? "allowed" : "not allowed")
                    row("Calendar", ok: h.agentFlag("calendar_ok") ?? false, detail: (h.agentFlag("calendar_ok") ?? false) ? "allowed" : "not allowed")
                    if let c = h.agentFlag("contacts_ok") {
                        row("Contacts (photos)", ok: c, detail: c ? "allowed" : "not allowed — initials instead")
                    }
                    if let rk = h.agentFlag("reminderkit_ok") {
                        row("Sections & tags", ok: rk, detail: rk ? "available" : "names go in the title instead")
                    }
                }
                row("Model", ok: h.llm.reachable,
                    detail: "\(h.llm.model)" + (h.llm.latencyMs.map { " · \($0) ms" } ?? "") + (h.llm.lastError.map { " · \($0)" } ?? ""))
                if let mail = h.mail, mail["enabled"]?.bool == true {
                    row("Mail", ok: mail["state"]?.string == "ok" || mail["state"]?.string == "idle", detail: mail["state"]?.string ?? "")
                }
                LabeledContent("Queue", value: "\(h.queueDepth) waiting for the Mac")
                LabeledContent("Brain up", value: ago(h.brainUptimeS).replacingOccurrences(of: " ago", with: ""))
            }

            Section("Today") {
                LabeledContent("Messages", value: "\(s.today["messages"] ?? 0)")
                LabeledContent("Added", value: "\(s.today["created"] ?? 0)")
                LabeledContent("Waiting for review", value: "\(s.review)")
                LabeledContent("Failed (24 h)", value: "\(s.failed24h)")
                if let p50 = s.latency.p50 { LabeledContent("Model speed (median)", value: "\(p50) ms") }
            }

            Section("Last 24 hours") {
                FunnelView(funnel: s.funnel)
            }

            Section("14 days") {
                DailyChart(days: s.daily).frame(height: 120)
            }

            if !s.commands.isEmpty {
                Section("Waiting for the Mac") {
                    ForEach(s.commands) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title ?? c.op.replacingOccurrences(of: "_", with: " ")).font(.subheadline.weight(.medium))
                            Text("\(c.status) · \(c.sender ?? "") · \(BrainDate.ago(c.createdAt))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !s.alerts.isEmpty {
                Section("Alerts") {
                    ForEach(s.alerts) { a in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.message).font(.subheadline)
                            Text("\(a.kind) · \(BrainDate.ago(a.createdAt))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button { Task { await app.run("Backup saved") { _ = try await $0.post("/api/system/backup") } } } label: {
                    Label("Back up the database now", systemImage: "externaldrive")
                }
                Button { Task { await app.run("Test alert sent") { _ = try await $0.post("/api/system/test-alert") } } } label: {
                    Label("Send a test Discord alert", systemImage: "bell")
                }
                if let size = s.db.sizeBytes {
                    LabeledContent("Database", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }
            } footer: {
                Text("Brain \(s.version) · settings v\(s.settingsVersion)")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func ago(_ s: Int) -> String {
        s < 90 ? "\(s) s ago" : s < 5400 ? "\(s / 60) min ago" : s < 172_800 ? "\(s / 3600) h ago" : "\(s / 86400) days ago"
    }
}

private struct FunnelView: View {
    let funnel: [String: Int]
    private let steps: [(String, String, Color)] = [
        ("received", "Received", .blue), ("to_llm", "Read by the model", .cyan), ("actionable", "Actionable", .teal),
        ("created", "Added", .green), ("review", "Review", .orange), ("failed", "Failed", .red),
    ]

    var body: some View {
        let top = max(funnel["received"] ?? 0, 1)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(steps, id: \.0) { step in
                let n = funnel[step.0] ?? 0
                HStack {
                    Text(step.1).font(.caption).frame(width: 120, alignment: .leading)
                    GeometryReader { g in
                        Capsule().fill(step.2.gradient).frame(width: max(4, g.size.width * Double(n) / Double(top)))
                    }
                    .frame(height: 10)
                    Text("\(n)").font(.caption.monospacedDigit()).frame(width: 30, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DailyChart: View {
    let days: [SystemStatus.Day]

    var body: some View {
        let top = max(days.map(\.messages).max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(days) { d in
                VStack(spacing: 2) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.blue.opacity(0.25))
                            .frame(height: 90 * Double(d.messages) / Double(top))
                        RoundedRectangle(cornerRadius: 3).fill(Color.green)
                            .frame(height: 90 * Double(d.created) / Double(top))
                    }
                    .frame(height: 90, alignment: .bottom)
                    Text(String(d.date.suffix(2))).font(.system(size: 8)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityLabel("Messages and items added per day")
    }
}

// MARK: - Connect / Server

struct ConnectView: View {
    @Environment(AppModel.self) private var app
    @State private var address = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "brain")
                            .font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 84, height: 84)
                            .background(LinearGradient(colors: [.blue, .teal], startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: .rect(cornerRadius: 20))
                        Text("Connect to your brain").font(.title2.bold())
                        Text("The server that reads your messages and keeps your lists. Use its Tailscale address — the same one you open the web dashboard with.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("100.101.102.103:8080 or https://brain.tailnet.ts.net", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("server-address")
                    SecureField("Dashboard password (if you set one)", text: $password)
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack { Spacer(); if busy { ProgressView() } else { Text("Connect").bold() }; Spacer() }
                    }
                    .disabled(address.isEmpty || busy)
                    .accessibilityIdentifier("connect")
                }
            }
            .navigationTitle("Second Brain")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func connect() async {
        busy = true
        defer { busy = false }
        error = await app.connect(address: address, password: password)
        if error == nil { _ = await Notifier.shared.requestPermission() }
    }
}

struct ServerView: View {
    @Environment(AppModel.self) private var app
    @State private var permission: UNAuthorizationStatus = .notDetermined
    @State private var confirmDisconnect = false
    @State private var polling = false

    var body: some View {
        List {
            Section("Server") {
                LabeledContent("Address", value: app.config?.baseURL.absoluteString ?? "—")
                LabeledContent("Password", value: app.config?.password == nil ? "none" : "saved")
                if let e = app.connectionError {
                    Label(e, systemImage: "wifi.exclamationmark").foregroundStyle(.red).font(.caption)
                } else if let i = app.info {
                    Label("Connected · brain \(i.version)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button("Disconnect…", role: .destructive) { confirmDisconnect = true }
            }
            Section {
                switch permission {
                case .authorized, .provisional, .ephemeral:
                    Label("Notifications are on", systemImage: "bell.badge.fill").foregroundStyle(.green)
                    Button("Send a test notification") { Notifier.shared.test() }
                    Button {
                        polling = true
                        Task {
                            let n = await Notifier.shared.poll()
                            polling = false
                            app.show(n == 0 ? "Nothing new" : "\(n) new")
                        }
                    } label: { Text(polling ? "Checking…" : "Check for new notifications now") }
                case .denied:
                    Label("Notifications are off for Second Brain", systemImage: "bell.slash").foregroundStyle(.orange)
                    Button("Open iOS Settings") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }
                default:
                    Button("Turn on notifications") {
                        Task { _ = await Notifier.shared.requestPermission(); await refreshPermission() }
                    }
                }
                NavigationLink("What to be notified about", value: Route.settings)
            } header: {
                Text("Notifications")
            } footer: {
                Text("The app checks the brain whenever you open it and when iOS gives it background time (Settings → General → Background App Refresh must be on). Focus timers are set on the phone, so they're always on time. For instant alerts while the app is closed, keep the web app's notifications or Discord on too.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Server & notifications")
        .task { await refreshPermission() }
        .confirmationDialog("Disconnect from this brain?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { app.disconnect() }
        }
    }

    private func refreshPermission() async { permission = await Notifier.shared.status() }
}
