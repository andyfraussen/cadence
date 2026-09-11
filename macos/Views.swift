import AppKit
import ServiceManagement
import SwiftUI

enum CadenceBrand {
    static let appIcon: NSImage? = Bundle.main.url(forResource: "AppIcon", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    // Monochrome companion to the app icon, with a small rhythm notch at the top.
    static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let ring = NSBezierPath()
            ring.lineWidth = 3.2; ring.lineCapStyle = .round
            ring.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 6.2, startAngle: 30, endAngle: 330)
            ring.stroke()
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.setBlendMode(.clear)
                context.setLineWidth(1.6); context.setLineCap(.round)
                context.move(to: CGPoint(x: 9, y: 17))
                context.addLine(to: CGPoint(x: 9, y: 15.2))
                context.strokePath()
                context.restoreGState()
            }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                AppLogo()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cadence").font(.headline)
                    Text("A little room to keep building.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh Cadence").accessibilityLabel("Refresh Cadence")
            }
            ScrollView(.vertical) {
              VStack(alignment: .leading, spacing: 16) {
               VStack(spacing: 10) {
                if model.monthly.isEmpty { unavailable("Cursor & Other Models", model.monthlyError) }
                else {
                    ForEach(model.monthly) { quota in
                        QuotaCard(quota: quota, failure: model.monthlyError, workdaysOnly: model.workdaysOnly)
                    }
                }
                if model.showGrok {
                    if let grok = model.grok { QuotaCard(quota: grok, failure: model.grokError, workdaysOnly: model.workdaysOnly) }
                    else { unavailable("Grok Bot · weekly", model.grokError) }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Label("What does “safe per day” mean?", systemImage: "info.circle").font(.system(size: 12)).fontWeight(.medium)
                Text("Your remaining quota divided across the \(model.workdaysOnly ? "weekdays" : "days") until reset. It’s an average you can still use per day, measured as a percentage of the full quota—not a separate daily limit or a record of today’s spending.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
              }.padding(.trailing, 4)
            }.frame(maxHeight: .infinity)
            Divider()
            HStack {
                Button("Settings…", action: settings)
                Button("Dashboard") { NSWorkspace.shared.open(URL(string: "https://cursor.com/dashboard")!) }
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
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct QuotaCard: View {
    let quota: Quota
    let failure: String?
    let workdaysOnly: Bool
    private var stale: Bool { failure != nil || quota.isStale() }
    private var tint: Color { stale ? .orange : quota.remaining < 10 ? .red : .teal }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(quota.name).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(quota.id == "G" ? "WEEKLY" : "MONTHLY")
                    .font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.1f%%", quota.remaining)).font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("left until reset").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if stale { Label("Stale", systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange) }
            }
            ProgressView(value: min(100, quota.remaining), total: 100).tint(tint)
                .accessibilityLabel("\(quota.name) remaining").accessibilityValue(String(format: "%.1f percent", quota.remaining))
            HStack(alignment: .firstTextBaseline) {
                Text(workdaysOnly ? "Safe to use / weekday" : "Safe to use / day").font(.system(size: 12))
                Spacer()
                if !stale, let safe = quota.safePerDay(workdaysOnly: workdaysOnly) {
                    Text(String(format: "%.2f%% of full quota", safe)).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                } else { Text("—").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Text("Resets \(quota.reset.formatted(date: .abbreviated, time: .shortened)) · \(quota.daysLeft()) days left")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let failure {
                Text(failure).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if quota.reset <= Date() {
                Text("Cycle ended. Waiting for a fresh balance.").font(.system(size: 12)).foregroundStyle(.orange)
            } else if workdaysOnly && quota.safePerDay(workdaysOnly: true) == nil {
                Text("No weekdays remain before reset.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text("\(stale ? "Last success" : "Updated") \(quota.updated.formatted(date: .omitted, time: .standard))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
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
                        Text("Logo + limits").tag("both")
                        Text("Limits only").tag("limits")
                        Text("Logo only").tag("logo")
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
                        .fill(status == .connected ? Color.teal : status == .fetching || status == .idle || status == .demo ? Color.secondary : Color.orange)
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
