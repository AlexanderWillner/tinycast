import Foundation

enum DictationDestination: String, CaseIterable, Identifiable, Sendable {
    case paste
    case copy
    case both
    case askAI

    var id: Self { self }
    var title: String {
        switch self {
        case .paste: "Paste in active app"
        case .copy: "Copy to clipboard"
        case .both: "Paste and copy"
        case .askAI: "Ask AI"
        }
    }

    var pastes: Bool { self == .paste || self == .both }
    var copies: Bool { self == .copy || self == .both }
}
