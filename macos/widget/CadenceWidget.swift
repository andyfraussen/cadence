import AppKit
import SwiftUI
import WidgetKit

@main
struct CadenceWidgets: WidgetBundle {
    var body: some Widget {
        ServiceWidget(kind: "cadence.cursor", name: "Cursor", service: "cursor")
        ServiceWidget(kind: "cadence.codex", name: "Codex", service: "codex")
        ServiceWidget(kind: "cadence.claude", name: "Claude", service: "claude")
        ServiceWidget(kind: "cadence.grok", name: "Grok", service: "grok")
    }
}

struct ServiceWidget: Widget {
    let kind: String
    let name: String
    let service: String

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ServiceProvider(service: service)) { entry in
            ServiceWidgetView(serviceID: service, entry: entry)
        }
        .configurationDisplayName(name)
        .description("\(name) usage from Cadence.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ServiceEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct ServiceProvider: TimelineProvider {
    let service: String

    func placeholder(in context: Context) -> ServiceEntry {
        ServiceEntry(date: Date(), snapshot: WidgetSamples.snapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (ServiceEntry) -> Void) {
        completion(ServiceEntry(date: Date(), snapshot: WidgetStore.read() ?? WidgetSamples.snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ServiceEntry>) -> Void) {
        let snapshot = WidgetStore.read() ?? WidgetSamples.snapshot
        let entry = ServiceEntry(date: Date(), snapshot: snapshot)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct ServiceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let serviceID: String
    let entry: ServiceEntry

    private var service: WidgetService? { entry.snapshot.service(serviceID) }

    var body: some View {
        Group {
            if let service, service.enabled, let pool = WidgetSnapshot.featured(service.pools) {
                if family == .systemMedium {
                    MediumWidget(service: service, lead: pool, date: entry.date)
                } else {
                    SmallWidget(service: service, pool: pool, date: entry.date)
                }
            } else {
                EmptyWidget(name: serviceName, message: service?.message ?? "Open Cadence")
            }
        }
        .widgetURL(URL(string: "cadence://open"))
        .modifier(WidgetBackground(serviceID: serviceID))
    }

    private var serviceName: String {
        switch serviceID {
        case "codex": return "Codex"
        case "claude": return "Claude"
        case "grok": return "Grok"
        default: return "Cursor"
        }
    }
}

struct SmallWidget: View {
    let service: WidgetService
    let pool: WidgetPool
    let date: Date

    var body: some View {
        VStack(spacing: 2) {
            Text("\(service.name) · \(pool.name)")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            ZStack {
                UsageRing(fraction: pool.remaining / 100, mood: pool.mood, serviceID: service.id)
                    .frame(width: 78, height: 78)
                Mascot(serviceID: service.id, date: date)
                    .frame(width: 62, height: 62)
            }
            Text(String(format: "%.1f%%", pool.remaining))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(WidgetPalette.color(service: service.id, mood: pool.mood))
            Text(todayLine(pool))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(pool.resetText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MediumWidget: View {
    let service: WidgetService
    let lead: WidgetPool
    let date: Date

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                UsageRing(fraction: lead.remaining / 100, mood: lead.mood, serviceID: service.id)
                Mascot(serviceID: service.id, date: date)
                    .frame(width: 72, height: 72)
            }
            .frame(width: 108, height: 108)
            VStack(alignment: .leading, spacing: 8) {
                Text(service.name).font(.system(size: 13, weight: .semibold))
                ForEach(Array(service.pools.prefix(2))) { pool in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(pool.name).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(String(format: "%.1f%%", pool.remaining))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(WidgetPalette.color(service: service.id, mood: pool.mood))
                        }
                        UsageMeter(fraction: todayFraction(pool), mood: pool.mood, serviceID: service.id)
                        Text(todayLine(pool))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct EmptyWidget: View {
    let name: String
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.system(size: 13, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct UsageRing: View {
    let fraction: Double
    let mood: WidgetMood
    let serviceID: String
    var body: some View {
        let color = WidgetPalette.color(service: serviceID, mood: mood)
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct UsageMeter: View {
    let fraction: Double
    let mood: WidgetMood
    let serviceID: String
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(WidgetPalette.color(service: serviceID, mood: mood))
                    .frame(width: max(0, geo.size.width * max(0, min(1, fraction))))
            }
        }
        .frame(height: 6)
    }
}

struct WidgetBackground: ViewModifier {
    let serviceID: String
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.containerBackground(for: .widget) { WidgetChrome(serviceID: serviceID) }
        } else {
            content.background(WidgetChrome(serviceID: serviceID))
        }
    }
}

struct WidgetChrome: View {
    let serviceID: String
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [WidgetPalette.wash(serviceID), .clear], center: .center, startRadius: 4, endRadius: 140)
        }
    }
}

enum WidgetPalette {
    static let codex = Color(red: 0.48, green: 0.34, blue: 0.82)
    static let claude = Color(red: 0.80, green: 0.42, blue: 0.30)

    static func color(service: String, mood: WidgetMood) -> Color {
        switch mood {
        case .over: return .red
        case .warning, .stale: return .orange
        case .calm:
            switch service {
            case "codex": return codex
            case "claude": return claude
            default: return .primary
            }
        }
    }

    static func wash(_ service: String) -> Color {
        switch service {
        case "codex": return codex.opacity(0.22)
        case "claude": return claude.opacity(0.22)
        default: return Color.primary.opacity(0.05)
        }
    }
}

struct Mascot: View {
    let serviceID: String
    let date: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.14)) { context in
            switch serviceID {
            case "codex": CodeyMark(date: context.date)
            case "claude": ClawdMark(date: context.date)
            case "grok": GrokMark(date: context.date)
            default: CursorCube()
            }
        }
    }
}

struct CursorCube: View {
    var body: some View {
        CubeShape().fill(Color.primary, style: FillStyle(eoFill: true)).padding(8)
    }
}

struct CubeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + (x - 12) * scale, y: rect.midY + (y - 12) * scale)
        }
        var path = Path()
        path.move(to: point(11.503, 0.131))
        path.addLine(to: point(1.891, 5.678))
        path.addLine(to: point(1.471, 6.404))
        path.addLine(to: point(1.471, 17.592))
        path.addLine(to: point(1.891, 18.316))
        path.addLine(to: point(11.5, 23.866))
        path.addLine(to: point(12.498, 23.866))
        path.addLine(to: point(22.108, 18.316))
        path.addLine(to: point(22.528, 17.592))
        path.addLine(to: point(22.528, 6.404))
        path.addLine(to: point(22.108, 5.678))
        path.addLine(to: point(12.497, 0.131))
        path.closeSubpath()
        path.move(to: point(2.657, 6.338))
        path.addLine(to: point(21.207, 6.338))
        path.addLine(to: point(21.504, 6.853))
        path.addLine(to: point(12.23, 22.918))
        path.addLine(to: point(12.001, 22.858))
        path.addLine(to: point(12.001, 12.335))
        path.addLine(to: point(11.706, 11.825))
        path.addLine(to: point(2.596, 6.568))
        path.closeSubpath()
        return path
    }
}

struct GrokMark: View {
    let date: Date
    var body: some View {
        let drift = sin(date.timeIntervalSinceReferenceDate / 1.6) * 1.2
        ZStack {
            Circle().fill(Color(white: 0.07))
            eye.offset(x: -10 + drift, y: -4)
            eye.offset(x: 12 + drift, y: -14)
        }
        .padding(6)
    }

    private var eye: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.white)
            .frame(width: 9, height: 16)
            .rotationEffect(.degrees(-28))
    }
}

struct CodeyMark: View {
    let date: Date
    var body: some View {
        if let frames = CodeyStrip.frames, !frames.isEmpty {
            let index = Int(date.timeIntervalSinceReferenceDate / 0.14) % frames.count
            Image(nsImage: frames[index]).resizable().interpolation(.none).scaledToFit()
        }
    }
}

enum CodeyStrip {
    static let frames: [NSImage]? = load()

    private static func load() -> [NSImage]? {
        guard let image = NSImage(contentsOf: WidgetStore.codeyURL), image.size.width > 0, image.size.height > 0 else { return nil }
        let count = 6
        let frame = NSSize(width: image.size.width / CGFloat(count), height: image.size.height)
        return (0..<count).map { index in
            let piece = NSImage(size: frame)
            piece.lockFocus()
            image.draw(in: NSRect(x: -frame.width * CGFloat(index), y: 0, width: image.size.width, height: image.size.height))
            piece.unlockFocus()
            return piece
        }
    }
}

struct ClawdMark: View {
    let date: Date
    var body: some View {
        Canvas { context, _ in
            let tick = Int(date.timeIntervalSinceReferenceDate / 0.14)
            let pose = ClawdArt.pose(at: tick)
            ClawdArt.draw(pose, in: &context)
        }
        .frame(width: 108, height: 88)
    }
}

enum ClawdArt {
    static let body = [" ▐▛███▜▌", "▝▜█████▛▘", " ▘▘  ▝▝"]
    static let script: [String] = Array(repeating: "default", count: 12) + Array(repeating: "right", count: 6)
        + Array(repeating: "default", count: 4) + Array(repeating: "left", count: 6)
        + Array(repeating: "default", count: 4) + Array(repeating: "hop", count: 5)

    static func pose(at tick: Int) -> String { script[tick % script.count] }

    static func draw(_ pose: String, in context: inout GraphicsContext) {
        let cw = 12.0, ch = 24.0
        let hop = pose == "hop" ? 0.0 : 10.0
        let color = Color(red: 0.80, green: 0.42, blue: 0.30)
        for (y, row) in body.enumerated() {
            for (x, glyph) in row.enumerated() {
                if glyph == "▛" || glyph == "▜" {
                    fill(context, CGRect(x: Double(x) * cw, y: hop + Double(y) * ch, width: cw, height: ch), color)
                } else {
                    for rect in parts(glyph) {
                        fill(context, CGRect(
                            x: Double(x) * cw + rect.origin.x * cw / 2,
                            y: hop + Double(y) * ch + rect.origin.y * ch / 2,
                            width: rect.width * cw / 2,
                            height: rect.height * ch / 2
                        ), color)
                    }
                }
            }
        }
        let left = pose == "left" ? 0.0 : cw / 2
        let right = pose == "right" ? cw / 2 : 0.0
        fill(context, CGRect(x: 2 * cw + left, y: hop + ch / 2, width: cw / 2, height: ch / 2), .white)
        fill(context, CGRect(x: 6 * cw + right, y: hop + ch / 2, width: cw / 2, height: ch / 2), .white)
    }

    private static func fill(_ context: GraphicsContext, _ rect: CGRect, _ color: Color) {
        context.fill(Path(rect), with: .color(color))
    }

    private static func parts(_ glyph: Character) -> [CGRect] {
        switch glyph {
        case "█": return [CGRect(x: 0, y: 0, width: 2, height: 2)]
        case "▌": return [CGRect(x: 0, y: 0, width: 1, height: 2)]
        case "▐": return [CGRect(x: 1, y: 0, width: 1, height: 2)]
        case "▘": return [CGRect(x: 0, y: 0, width: 1, height: 1)]
        case "▝": return [CGRect(x: 1, y: 0, width: 1, height: 1)]
        case "▖": return [CGRect(x: 0, y: 1, width: 1, height: 1)]
        case "▗": return [CGRect(x: 1, y: 1, width: 1, height: 1)]
        case "▛": return [CGRect(x: 0, y: 0, width: 2, height: 1), CGRect(x: 0, y: 1, width: 1, height: 1)]
        case "▜": return [CGRect(x: 0, y: 0, width: 2, height: 1), CGRect(x: 1, y: 1, width: 1, height: 1)]
        default: return []
        }
    }
}

enum WidgetSamples {
    static let snapshot: WidgetSnapshot = {
        let now = Date()
        func pool(_ id: String, _ name: String, remaining: Double, hours: Double, used: Double, budget: Double) -> WidgetPool {
            WidgetPool(
                id: id, name: name, remaining: remaining,
                reset: now.addingTimeInterval(hours * 3600),
                resetText: hours < 24 ? "Resets in \(Int(hours)) hr" : "Resets in \(Int(hours / 24)) days",
                stale: false, usedToday: used, budget: budget,
                mood: WidgetSnapshot.mood(stale: false, remaining: remaining, usedToday: used, budget: budget)
            )
        }
        return WidgetSnapshot(updatedAt: now, services: [
            WidgetService(id: "cursor", name: "Cursor", enabled: true, message: nil, pools: [
                pool("C", "Models", remaining: 87.7, hours: 24 * 24, used: 1.2, budget: 3.5),
                pool("O", "Other Models", remaining: 86, hours: 24 * 24, used: 0.6, budget: 3.4)
            ]),
            WidgetService(id: "codex", name: "Codex", enabled: true, message: nil, pools: [
                pool("codex-primary", "5 hours", remaining: 78, hours: 3, used: 2.4, budget: 6),
                pool("codex-secondary", "Weekly", remaining: 67, hours: 24 * 4, used: 1.8, budget: 4.2)
            ]),
            WidgetService(id: "claude", name: "Claude", enabled: true, message: nil, pools: [
                pool("claude-five_hour", "5 hours", remaining: 74.5, hours: 2, used: 5.2, budget: 16),
                pool("claude-seven_day", "Weekly", remaining: 90, hours: 24 * 5, used: 0.8, budget: 2.6)
            ]),
            WidgetService(id: "grok", name: "Grok", enabled: true, message: nil, pools: [
                pool("G", "Weekly", remaining: 97.7, hours: 24 * 6, used: 1.8, budget: 14)
            ])
        ])
    }()
}

func todayLine(_ pool: WidgetPool) -> String {
    guard let used = pool.usedToday, let budget = pool.budget else { return pool.resetText }
    return String(format: "%.1f of %.1f today", used, budget)
}

func todayFraction(_ pool: WidgetPool) -> Double {
    guard let used = pool.usedToday, let budget = pool.budget, budget > 0 else { return 0 }
    return used / budget
}
