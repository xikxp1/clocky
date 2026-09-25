import CoreFoundation
import Foundation

public enum BatteryDataParser {
    /// Accepts integral numeric values or integer strings with an optional percent
    /// sign. Rejects booleans, fractions, overflow, and values outside 0...100.
    public static func percentage(_ value: Any?) -> Int? {
        if let string = value as? String {
            var digits = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if digits.hasSuffix("%") {
                digits.removeLast()
                digits = digits.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !digits.isEmpty,
                  digits.utf8.allSatisfy({ (48...57).contains($0) }),
                  let result = Int(digits), (0...100).contains(result) else { return nil }
            return result
        }

        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, (0...100).contains(value), value.rounded(.towardZero) == value else { return nil }
        let result = Int(value)
        // Preserve strictness for NSDecimalNumber fractions that round to a whole Double.
        guard number.decimalValue == Decimal(result) else { return nil }
        return result
    }

    /// Parses the battery-domain plist from `ideviceinfo -x -q com.apple.mobile.battery`.
    public static func iPhone(from data: Data) -> Int? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let battery = root as? [String: Any] else { return nil }
        return percentage(battery["BatteryCurrentCapacity"])
    }

    /// Only connected entries in `system_profiler -json SPBluetoothDataType` are
    /// eligible. Selects one device; never combines readings across devices or
    /// falls back to cached, disconnected entries.
    public static func airPods(from data: Data) -> AirPodsBattery? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [Any] else { return nil }
        var candidates: [Candidate] = []
        for controller in controllers {
            guard let controller = controller as? [String: Any],
                  let connected = controller["device_connected"] as? [Any] else { continue }
            for entry in connected {
                guard let devices = entry as? [String: Any] else { continue }
                for (name, value) in devices {
                    guard let details = value as? [String: Any], isAirPods(name: name, details: details) else { continue }
                    let battery = AirPodsBattery(
                        left: percentage(details["device_batteryLevelLeft"]),
                        right: percentage(details["device_batteryLevelRight"]),
                        caseLevel: percentage(details["device_batteryLevelCase"]),
                        main: percentage(details["device_batteryLevelMain"]) ?? percentage(details["device_batteryLevel"])
                    )
                    let candidate = Candidate(name: name, address: details["device_address"] as? String ?? "", battery: battery)
                    if candidate.readingCount > 0 { candidates.append(candidate) }
                }
            }
        }
        return candidates.sorted { $0.precedes($1) }.first?.battery
    }

    // Confirmed Bluetooth PIDs, not Apple's USB product IDs or Beats identifiers.
    // https://theapplewiki.com/wiki/Bluetooth_PIDs
    private static let airPodsProductIDs: Set<Int> = [
        0x2002, // AirPods (1st generation)
        0x200F, // AirPods (2nd generation)
        0x2013, // AirPods (3rd generation)
        0x2019, // AirPods 4
        0x201B, // AirPods 4 (ANC)
        0x200E, // AirPods Pro
        0x2014, // AirPods Pro (2nd generation, Lightning)
        0x2024, // AirPods Pro (2nd generation, USB-C)
        0x2027, // AirPods Pro (3rd generation)
        0x200A, // AirPods Max (Lightning)
        0x201F  // AirPods Max (USB-C)
    ]

    private static func isAirPods(name: String, details: [String: Any]) -> Bool {
        let majorType = (details["device_majorType"] as? String)?.lowercased() ?? ""
        let minorType = (details["device_minorType"] as? String)?.lowercased() ?? ""
        guard !["computer", "phone", "peripheral", "imaging"].contains(majorType),
              !["mouse", "keyboard", "tablet", "smartphone"].contains(minorType) else { return false }
        // Identity metadata takes precedence over names and split battery fields:
        // Beats and other vendors' earbuds can report left/right levels too.
        if let vendor = details["device_vendorID"], identifier(vendor) != 0x004C { return false }
        if let product = details["device_productID"] {
            guard let productID = identifier(product) else { return false }
            return airPodsProductIDs.contains(productID)
        }
        if name.range(of: "beats", options: .caseInsensitive) != nil { return false }
        if name.range(of: "airpods", options: .caseInsensitive) != nil { return true }
        // Abbreviated entries can omit identity metadata for renamed earbuds.
        return details["device_batteryLevelLeft"] != nil || details["device_batteryLevelRight"] != nil
    }

    private static func identifier(_ value: Any?) -> Int? {
        let text: String
        if let string = value as? String {
            text = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            text = number.stringValue
        } else {
            return nil
        }
        if text.hasPrefix("0x") { return UInt16(text.dropFirst(2), radix: 16).map { Int($0) } }
        return UInt16(text).map { Int($0) }
    }

    private struct Candidate {
        let name: String
        let address: String
        let battery: AirPodsBattery

        var levels: [Int?] { [battery.left, battery.right, battery.caseLevel, battery.main] }
        var readingCount: Int { levels.compactMap { $0 }.count }
        var headsetReadingCount: Int { [battery.left, battery.right, battery.main].compactMap { $0 }.count }

        func precedes(_ other: Candidate) -> Bool {
            if readingCount != other.readingCount { return readingCount > other.readingCount }
            if headsetReadingCount != other.headsetReadingCount { return headsetReadingCount > other.headsetReadingCount }
            // Stable tie breakers make selection independent of JSON/dictionary order.
            if name != other.name { return name < other.name }
            if address != other.address { return address < other.address }
            return levels.map { $0 ?? -1 }.lexicographicallyPrecedes(other.levels.map { $0 ?? -1 })
        }
    }
}
