import Foundation

enum WidgetMood: String, Codable, Equatable {
    case calm, warning, over, stale
}

struct WidgetPool: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var remaining: Double
    var reset: Date
    var resetText: String
    var stale: Bool
    var usedToday: Double?
    var budget: Double?
    var mood: WidgetMood
}

struct WidgetService: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var enabled: Bool
    var message: String?
    var pools: [WidgetPool]
}

struct WidgetSnapshot: Codable, Equatable {
    var updatedAt: Date
    var services: [WidgetService]

    func service(_ id: String) -> WidgetService? {
        services.first { $0.id == id }
    }

    /// The pool a small widget should show: a stale or over-budget window
    /// first, otherwise the one that resets soonest.
    static func featured(_ pools: [WidgetPool]) -> WidgetPool? {
        if let urgent = pools.first(where: { $0.stale || $0.mood == .over }) { return urgent }
        return pools.min { $0.reset < $1.reset }
    }

    static func mood(stale: Bool, remaining: Double, usedToday: Double?, budget: Double?) -> WidgetMood {
        if stale { return .stale }
        if let usedToday, let budget, usedToday > budget { return .over }
        if remaining < 10 { return .over }
        if let usedToday, let budget, budget > 0, usedToday / budget + 1e-9 >= DailyBudgetInfo.warningThreshold {
            return .warning
        }
        return .calm
    }
}

enum WidgetCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
