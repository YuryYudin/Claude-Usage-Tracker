//
//  Provider.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-07-15.
//

import Foundation

/// Stable identity for a usage provider. The raw value is persisted in
/// `profiles_v3` — never rename a case's raw value.
///
/// Adding a provider: see docs/ADDING_A_PROVIDER.md.
enum Provider: Codable, Hashable, CaseIterable {
    case anthropic
    case codex
    case zai
    case unsupported(String)

    static let allCases: [Provider] = [.anthropic, .codex, .zai]

    init?(rawValue: String) {
        switch rawValue {
        case "anthropic", "claude": self = .anthropic
        case "codex": self = .codex
        case "zai": self = .zai
        default: self = .unsupported(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .anthropic: return "anthropic"
        case .codex: return "codex"
        case .zai: return "zai"
        case .unsupported(let value): return value
        }
    }

    init(from decoder: Decoder) throws {
        self = Provider(rawValue: try decoder.singleValueContainer().decode(String.self))!
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var descriptor: ProviderDescriptor {
        ProviderRegistry.descriptor(for: self)
    }
}
