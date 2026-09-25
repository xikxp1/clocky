import Foundation

/// Experimental decoding of publicly reverse-engineered Apple advertisements,
/// not an Apple-supported API. Manufacturer data includes the two company bytes.
/// These packets are unauthenticated: identification is a discovery hint only.
public enum BLEAdvertisementParser {
    /// Only the standard 29-byte, paired-mode 0x07 frame is supported. Battery
    /// nibbles are approximate ten-percent steps; 0xF is unavailable and 0xB...0xE
    /// are invalid. The encrypted tail and closed-case 0x12 are never decoded.
    public static func airPods(from manufacturerData: Data) -> AirPodsBattery? {
        guard let packet = proximityPacket(manufacturerData) else { return nil }
        let levels = packet.bytes[8]

        // Max has one headset level in the low nibble, independent of orientation.
        // Never invent left/right cup levels or a battery for its passive case.
        if maxProductIDs.contains(packet.productID) {
            guard let main = percentage(levels & 0x0F) else { return nil }
            return AirPodsBattery(main: main, isApproximate: true)
        }

        // Status bit 5 (0x20), NOT bit 6: when set, low nibble = left;
        // when clear, high nibble = left. See the source notes below.
        let leftIsLowNibble = packet.bytes[7] & 0x20 != 0
        let low = percentage(levels & 0x0F)
        let high = percentage(levels >> 4)
        let caseLevel = percentage(packet.bytes[9] & 0x0F)
        guard low != nil || high != nil || caseLevel != nil else { return nil }
        return AirPodsBattery(
            left: leftIsLowNibble ? low : high,
            right: leftIsLowNibble ? high : low,
            caseLevel: caseLevel,
            isApproximate: true
        )
    }

    /// Identity validation is independent of battery availability, so an explicitly
    /// selectable AirPods candidate can advertise all unknown/invalid levels.
    public static func isAirPods(_ manufacturerData: Data) -> Bool {
        proximityPacket(manufacturerData) != nil
    }

    /// A weak discovery hint, not proof of an iPhone or a source of its battery.
    /// Before accepting a GATT reading, callers must require explicit UUID selection
    /// and verify Apple Inc. manufacturer plus an iPhone model through GATT.
    public static func isPhoneCandidate(_ manufacturerData: Data) -> Bool {
        let bytes = [UInt8](manufacturerData)
        guard bytes.count >= 4, bytes[0] == 0x4C, bytes[1] == 0x00 else { return false }
        var offset = 2
        var foundCandidate = false
        while offset < bytes.count {
            guard bytes.count - offset >= 2 else { return false }
            let type = bytes[offset]
            let length = Int(bytes[offset + 1])
            offset += 2
            guard length <= bytes.count - offset else { return false }
            switch type {
            case 0x10:
                // Nearby Info has two status bytes, with optional authentication
                // and extension bytes. It is also broadcast by non-phone devices.
                guard length >= 2 else { return false }
                foundCandidate = true
            case 0x0C:
                // 0x0C is Handoff (14 bytes), NOT Instant Hotspot (0x0E).
                // Retained as a discovery hint only; no encrypted data is read.
                guard length == 14 else { return false }
                foundCandidate = true
            default:
                break
            }
            offset += length
        }
        // Validate the entire TLV stream, including messages after a valid hint.
        return foundCandidate
    }

    // Protocol facts (independent implementation; no AGPL code copied):
    // https://github.com/furiousMAC/continuity/blob/master/messages/proximity_pairing.md
    // https://github.com/furiousMAC/continuity/blob/master/messages/nearby_info.md
    // https://github.com/furiousMAC/continuity/blob/master/messages/handoff.md
    // Bit-5 orientation and Max low-nibble corroboration (MIT project):
    // https://github.com/t4t5/podpower/blob/58202c955851f4517dda13c3c19bf29c21b2b828/src/main.rs
    // https://github.com/fischejo/airpods-notify/blob/master/doc/proximity_protocol.md
    // instead labels bit 6 as "flipped"; we follow the bit-5 implementation above,
    // without its +5% midpoint estimate.
    // All these layouts remain reverse-engineered and may change with firmware.
    private static func proximityPacket(_ data: Data) -> (bytes: [UInt8], productID: UInt16)? {
        guard data.count == 29 else { return nil }
        // Copy to zero-based storage: Data slices need not start at index zero.
        let bytes = [UInt8](data)
        guard bytes[0] == 0x4C, bytes[1] == 0x00,
            bytes[2] == 0x07, bytes[3] == 0x19, bytes[4] == 0x01
        else { return nil }
        let productID = UInt16(bytes[5]) | (UInt16(bytes[6]) << 8)
        guard airPodsProductIDs.contains(productID) else { return nil }
        return (bytes, productID)
    }

    // Keep in sync with BatteryDataParser's confirmed Bluetooth PIDs.
    // https://theapplewiki.com/wiki/Bluetooth_PIDs
    // Beats and unknown future models are intentionally excluded.
    private static let airPodsProductIDs: Set<UInt16> = [
        0x2002, 0x200F, 0x2013, 0x2019, 0x201B,
        0x200E, 0x2014, 0x2024, 0x2027, 0x200A, 0x201F,
    ]
    private static let maxProductIDs: Set<UInt16> = [0x200A, 0x201F]

    private static func percentage(_ nibble: UInt8) -> Int? {
        guard nibble <= 10 else { return nil }
        return Int(nibble) * 10
    }
}
