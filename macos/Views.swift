import AppKit
import ServiceManagement
import SwiftUI

enum CadenceBrand {
    static let appIcon: NSImage? = Bundle.main.url(forResource: "AppIcon", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    // Monochrome companion to the app icon: a clean flat-cut C with a ±36° opening.
    static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let ring = NSBezierPath()
            ring.lineWidth = 3.4; ring.lineCapStyle = .butt
            ring.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 6.2, startAngle: 36, endAngle: 324)
            ring.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

struct AppLogo: View {
    var size: CGFloat = 40
    var body: some View {
        Group {
            if let image = CadenceBrand.appIcon {
                Image(nsImage: image).resizable().interpolation(.high)
            } else { Image(nsImage: CadenceBrand.menuBarIcon).resizable().scaledToFit() }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    let settings: () -> Void
    let quit: () -> Void
    let height: CGFloat

    private var statusLine: (String, Color) {
        if model.refreshing { return ("Refreshing…", .secondary) }
        if model.hasProblem { return ("Needs attention", .orange) }
        return ("On pace", .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AppLogo(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cadence").font(.system(size: 15, weight: .semibold))
                    Text(statusLine.0).font(.system(size: 12)).foregroundStyle(statusLine.1)
                }
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh Cadence").accessibilityLabel("Refresh Cadence")
            }
            ScrollView(.vertical) {
              VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 12) {
                 if model.monthly.isEmpty { unavailable("Cursor & Other Models", model.monthlyError) }
                 else {
                     ForEach(model.monthly) { quota in
                         QuotaCard(quota: quota, failure: model.monthlyError, workdaysOnly: model.workdaysOnly, anchor: model.dailyAnchors[quota.id])
                     }
                 }
                 if model.showGrok {
                     if let grok = model.grok { QuotaCard(quota: grok, failure: model.grokError, workdaysOnly: model.workdaysOnly, anchor: model.dailyAnchors[grok.id]) }
                     else { unavailable("Grok Bot · weekly", model.grokError) }
                 }
             }
             DisclosureGroup {
                 Text("Each morning your remaining quota is divided across the \(model.workdaysOnly ? "weekdays" : "days") until reset to set today’s fixed budget. Today’s usage is measured against that budget—both as shares of your total quota. The budget stays steady all day; savings or overspend redistribute into tomorrow’s budget. It’s a visual pacing guide, not a block.")
                     .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
             } label: {
                 Label("What does “today’s budget” mean?", systemImage: "info.circle")
                     .font(.system(size: 12)).fontWeight(.medium)
             }
              }.padding(.trailing, 4)
            }.frame(maxHeight: .infinity)
            Divider()
            HStack {
                Button("Settings…", action: settings)
                Button("Cursor dashboard") { NSWorkspace.shared.open(URL(string: "https://cursor.com/dashboard")!) }
                Spacer()
                if model.refreshing { ProgressView().controlSize(.small).accessibilityLabel("Refreshing") }
                Button("Quit", action: quit)
            }.controlSize(.small)
        }.padding(20).frame(width: 390, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private func unavailable(_ name: String, _ error: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name).font(.headline)
            Text(error ?? "Fetching your usage…").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

struct MeterBar: View {
    let fraction: Double
    let solid: Color
    let label: String
    let value: String

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule().fill(solid)
                    .frame(width: max(0, geo.size.width * max(0, min(1, fraction))))
            }
        }
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

struct QuotaCard: View {
    let quota: Quota
    let failure: String?
    let workdaysOnly: Bool
    /// Morning baseline for the fixed daily budget. Nil before the first
    /// snapshot (falls back to a live estimate with zero spend today).
    let anchor: DailyAnchor?
    private func isStale(now: Date) -> Bool { failure != nil || quota.isStale(at: now) }
    /// Cursor-monochrome severity: healthy pools render in primary black/white,
    /// warnings stay orange/red so color always means something is wrong.
    private func accent(now: Date) -> Color {
        if isStale(now: now) { return .orange }
        return quota.remaining < 10 ? .red : .primary
    }
    /// Daily pacing severity: steady black while on pace, amber near the
    /// budget (≥80%), red once over. Only the daily bar uses this so color
    /// always signals today's pace.
    private func dailyColor(_ daily: DailyBudgetInfo?) -> Color {
        guard let daily, daily.budget != nil else { return .primary }
        if daily.isOver { return .red }
        if daily.isWarning { return .orange }
        return .primary
    }

    var body: some View {
        // Single timestamp per render so stale/budget/days-left cannot disagree
        // when a render straddles midnight or the 180s stale boundary.
        let now = Date()
        let stale = isStale(now: now)
        let accent = accent(now: now)
        let daily: DailyBudgetInfo? = stale ? nil : quota.dailyInfo(at: now, anchor: anchor, workdaysOnly: workdaysOnly)
        let dailyAccent = dailyColor(daily)
        let remaining = quota.resetRemainingText(at: now, workdaysOnly: workdaysOnly)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(accent).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(quota.name).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(quota.id == "G" ? "WEEKLY" : "MONTHLY")
                    .font(.system(size: 9.5, weight: .bold)).tracking(0.7)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .foregroundStyle(.secondary)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.1f", quota.remaining))
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("% left").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                if stale { Label("Stale", systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange) }
            }
            MeterBar(fraction: quota.remaining / 100, solid: accent,
                     label: "\(quota.name) remaining", value: String(format: "%.1f percent", quota.remaining))
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Today")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    if let daily, let budget = daily.budget {
                        Text(String(format: "%.1f%% used / %.1f%% budget", daily.usedToday, budget))
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(dailyAccent == .primary ? .primary : dailyAccent)
                    } else { Text("—").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                if let daily, let budget = daily.budget {
                    MeterBar(fraction: min(1, max(0, daily.fraction ?? 0)), solid: dailyAccent,
                             label: "\(quota.name) today versus budget",
                             value: String(format: "%.1f of %.1f percent", daily.usedToday, budget))
                    if let over = daily.overBy {
                        Text(String(format: "%.1f%% over today’s budget", over))
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(.red)
                    } else if let available = daily.available {
                        Text(String(format: "%.1f%% available today", available))
                            .font(.system(size: 12)).monospacedDigit()
                            .foregroundStyle(daily.isWarning ? .orange : .secondary)
                    }
                } else if !stale && workdaysOnly {
                    Text("No weekdays remain before reset.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            Text("Resets \(quota.reset.formatted(date: .abbreviated, time: .shortened)) · \(remaining)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let failure {
                Text(failure).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if stale {
                Text("Last success \(quota.updated.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if quota.reset <= now {
                Text("Cycle ended. Waiting for a fresh balance.").font(.system(size: 12)).foregroundStyle(.orange)
            } else if workdaysOnly && daily?.budget == nil {
                Text("No weekdays remain before reset.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginApproval = SMAppService.mainApp.status == .requiresApproval
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 14) {
                AppLogo(size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Cadence").font(.title3).fontWeight(.bold)
                        Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Text("Menu bar pacing & preferences")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            // Settings content
            Form {
                Section {
                    Picker("Appearance", selection: $model.displayMode) {
                        Text("Logo + limits").tag(AppModel.DisplayMode.both)
                        Text("Limits only").tag(AppModel.DisplayMode.limits)
                        Text("Logo only").tag(AppModel.DisplayMode.logo)
                    }
                    .pickerStyle(.segmented)

                    Toggle(isOn: $model.showGrok) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Grok Bot")
                            Text("Include weekly Grok quota in menu bar and popover")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Label("Menu Bar", systemImage: "menubar.dock.rectangle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle(isOn: $model.workdaysOnly) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Weekday pacing only")
                            Text("Calculate safe daily allowance across Monday–Friday only")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Label("Daily Pacing", systemImage: "calendar.badge.clock")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Launch at Login", isOn: Binding(get: { loginEnabled }, set: setLogin))
                    if loginApproval {
                        Button("Approve in System Settings…") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        .font(.system(size: 12))
                    }
                    if let message, isError {
                        Text(message).font(.system(size: 11)).foregroundStyle(.red)
                    }
                } header: {
                    Label("System", systemImage: "gearshape")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let status = model.syncStatus(at: context.date)
                HStack(spacing: 8) {
                    Circle()
                        .fill(status == .connected ? Color.primary : status == .fetching || status == .idle || status == .demo ? Color.secondary : Color.orange)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.rawValue)
                        if let lastSuccess = model.lastSuccess {
                            Text("Last success \(lastSuccess.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(model.monthlyError ?? (model.showGrok ? model.grokError : nil) ?? status.rawValue)
                    Spacer()
                    Button("Retry") { model.refresh() }
                    Button("Done") { NSApp.keyWindow?.close() }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.02))
        }
        .frame(width: 440, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginApproval = SMAppService.mainApp.status == .requiresApproval
        }
    }

    private func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginApproval = SMAppService.mainApp.status == .requiresApproval
            message = nil; isError = false
        } catch { show(error) }
    }

    private func show(_ error: Error) {
        message = error.localizedDescription
        isError = true
    }
}
