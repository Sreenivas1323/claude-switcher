import AppKit
import SwiftUI

struct MenuPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if model.accounts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.accounts) { account in
                            AccountRow(account: account)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 460)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let banner = model.banner {
                Divider()
                HStack(alignment: .top) {
                    Text(banner).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.banner = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }

            Divider()
            footer
        }
        .frame(width: 360)
        .task { await model.refreshUsage() }
    }

    private var header: some View {
        HStack {
            Text("Claude accounts").font(.headline)
            Spacer()
            if let best = model.bestAlternative,
               let active = model.activeID, let u = model.usage[active],
               AppModel.effective(u) >= 50 {
                Button("Use freshest") { Task { await model.switchTo(best.id) } }
                    .controlSize(.small)
                    .help("Switch to \(best.title), the account with the most headroom")
            }
            Button {
                Task { await model.syncLive(); await model.refreshUsage() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(model.isRefreshing ? 360 : 0))
                    .animation(model.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                               value: model.isRefreshing)
            }
            .buttonStyle(.borderless)
            .help("Refresh usage")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No accounts yet").font(.subheadline.weight(.semibold))
            Text("Log in to Claude Code once with each account (`/login` or the button below). Every login is saved here automatically.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Auto-switch at", isOn: $model.autoSwitch)
                    .toggleStyle(.checkbox)
                Picker("", selection: $model.threshold) {
                    ForEach([75.0, 85, 90, 95, 98], id: \.self) { Text("\(Int($0))%").tag($0) }
                }
                .labelsHidden()
                .frame(width: 70)
                .disabled(!model.autoSwitch)
                Spacer()
            }
            .help("When the active account's session or weekly limit reaches this level, switch to the account with the most headroom.")

            HStack {
                Button("Add account…") { model.addAccount() }
                Spacer()
                Toggle("Open at login", isOn: $model.launchAtLogin).toggleStyle(.checkbox)
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(12)
    }
}

struct AccountRow: View {
    @EnvironmentObject var model: AppModel
    let account: SavedAccount
    @State private var hovering = false

    private var isActive: Bool { model.activeID == account.id }
    private var usage: Usage? { model.usage[account.id] }
    private var error: String? { model.errors[account.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActive ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                if let plan = account.plan {
                    Text(plan).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                actionButton
            }

            if let usage {
                LimitBar(label: "Session", window: usage.session)
                LimitBar(label: "Weekly", window: usage.weekly)
                if let opus = usage.weeklyOpus, opus.percent > 0 { LimitBar(label: "Opus wk", window: opus) }
            } else if error == nil {
                Text("Checking usage…").font(.caption).foregroundStyle(.secondary)
            }

            if model.awaitingLogin == account.id {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Waiting for you to finish signing in…")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reopen") { model.relogin(account.id) }
                        .controlSize(.small)
                }
            } else if model.needsLogin.contains(account.id) {
                HStack(spacing: 6) {
                    Label("Session expired", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Log in again") { model.relogin(account.id) }
                        .controlSize(.small)
                        .help("Opens Terminal with claude auth login for \(account.email)")
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.08) : Color.primary.opacity(hovering ? 0.05 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06))
        )
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename…") { promptRename() }
            Button("Copy email") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(account.email, forType: .string)
            }
            Divider()
            Button("Remove", role: .destructive) { model.remove(account.id) }
                .disabled(isActive)
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if account.nickname != nil { parts.append(account.email) }
        if let org = account.organizationName, !org.contains(account.email) { parts.append(org) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private var actionButton: some View {
        if isActive {
            Text("Active").font(.caption.weight(.medium)).foregroundStyle(.green)
        } else if model.needsLogin.contains(account.id) || model.awaitingLogin == account.id {
            EmptyView()
        } else if model.switchingTo == account.id {
            ProgressView().controlSize(.small)
        } else {
            Button("Switch") { Task { await model.switchTo(account.id) } }
                .controlSize(.small)
                .disabled(model.switchingTo != nil)
        }
    }

    private func promptRename() {
        let alert = NSAlert()
        alert.messageText = "Rename account"
        alert.informativeText = account.email
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = account.nickname ?? ""
        field.placeholderString = "e.g. Work, Personal, Max #2"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            model.rename(account.id, to: field.stringValue)
        }
    }
}

struct LimitBar: View {
    let label: String
    let window: UsageWindow?

    private var percent: Double {
        guard let window else { return 0 }
        if let reset = window.resetsAt, reset < Date() { return 0 }
        return min(max(window.percent, 0), 100)
    }

    private var color: Color {
        switch percent {
        case ..<60: return .green
        case ..<85: return .yellow
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(percent.rounded()))%").font(.caption.monospacedDigit().weight(.medium))
                if let reset = window?.resetsAt, reset > Date() {
                    Text("· resets \(Self.format(reset))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color.gradient)
                        .frame(width: max(geo.size.width * percent / 100, percent > 0 ? 4 : 0))
                }
            }
            .frame(height: 5)
        }
    }

    /// "in 2h 13m" within a day, otherwise e.g. "Thu 13:00" / "Thu 1:00 PM" per locale.
    static func format(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds < 24 * 3600 {
            let h = Int(seconds) / 3600, m = (Int(seconds) % 3600) / 60
            return h > 0 ? "in \(h)h \(m)m" : "in \(m)m"
        }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE jmm")
        return f.string(from: date)
    }
}
