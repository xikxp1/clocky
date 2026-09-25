import Foundation

/// An explicitly selected local peripheral. Its UUID, never its display name,
/// identifies the device; equal names do not establish equal devices.
public struct BLEDeviceSelection: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            name: try values.decode(String.self, forKey: .name)
        )
    }
}

/// Opt-in, experimental Bluetooth fallbacks. Disabling them retains selections
/// locally without enabling scanning or choosing another device automatically.
public struct BLEPreferences: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var airPods: BLEDeviceSelection?
    public var iPhone: BLEDeviceSelection?

    public init(
        enabled: Bool = false, airPods: BLEDeviceSelection? = nil, iPhone: BLEDeviceSelection? = nil
    ) {
        self.enabled = enabled
        self.airPods = airPods
        self.iPhone = iPhone
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, airPods, iPhone
    }

    /// Invalid fields are isolated: a damaged UUID must not discard the other
    /// selection, and malformed opt-in values must never enable Bluetooth.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? values.decode(Bool.self, forKey: .enabled)) ?? false
        airPods = try? values.decode(BLEDeviceSelection.self, forKey: .airPods)
        iPhone = try? values.decode(BLEDeviceSelection.self, forKey: .iPhone)
    }
}
