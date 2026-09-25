public struct BatterySnapshot: Equatable, Sendable {
    public let mac: Int?
    public let iPhone: Int?
    public let airPods: AirPodsBattery?
    public let iPhoneUsesBLE: Bool

    public init(
        mac: Int? = nil, iPhone: Int? = nil, airPods: AirPodsBattery? = nil,
        iPhoneUsesBLE: Bool = false
    ) {
        let phoneLevel = validPercentage(iPhone)
        self.mac = validPercentage(mac)
        self.iPhone = phoneLevel
        self.airPods = airPods
        self.iPhoneUsesBLE = iPhoneUsesBLE && phoneLevel != nil
    }

    public var text: String {
        "Mac \(percentageText(mac)) · iPhone \(percentageText(iPhone))\(iPhoneUsesBLE ? " (BLE)" : "") · AirPods \(airPods?.text ?? "N/A")"
    }

    public var accessibilityText: String {
        "Mac \(spokenPercentage(mac)), iPhone \(spokenPercentage(iPhone))\(iPhoneUsesBLE ? " via Bluetooth" : ""), AirPods \(airPods?.accessibilityText ?? "unavailable")"
    }
}

public struct AirPodsBattery: Equatable, Sendable {
    public let left: Int?
    public let right: Int?
    public let caseLevel: Int?
    /// A single headset battery, as reported by AirPods Max.
    public let main: Int?
    /// Cleartext BLE advertisements encode only coarse, ten-percent levels.
    public let isApproximate: Bool

    public init(
        left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil, main: Int? = nil,
        isApproximate: Bool = false
    ) {
        self.left = validPercentage(left)
        self.right = validPercentage(right)
        self.caseLevel = validPercentage(caseLevel)
        self.main = validPercentage(main)
        self.isApproximate = isApproximate
    }

    /// A conservative single headset reading. Case charge is separate and must
    /// never stand in for unavailable earbuds. AirPods Max reports `main`.
    public var headsetPercentage: Int? {
        [left, right].compactMap { $0 }.min() ?? main
    }

    fileprivate var text: String {
        if left != nil || right != nil || caseLevel != nil {
            return
                "L \(percentageText(left, approximate: isApproximate)) R \(percentageText(right, approximate: isApproximate)) C \(percentageText(caseLevel, approximate: isApproximate))"
        }
        return percentageText(main, approximate: isApproximate)
    }

    fileprivate var accessibilityText: String {
        if left != nil || right != nil || caseLevel != nil {
            return
                "left \(spokenPercentage(left, approximate: isApproximate)), right \(spokenPercentage(right, approximate: isApproximate)), case \(spokenPercentage(caseLevel, approximate: isApproximate))"
        }
        return spokenPercentage(main, approximate: isApproximate)
    }
}

private func validPercentage(_ value: Int?) -> Int? {
    guard let value, (0...100).contains(value) else { return nil }
    return value
}

private func percentageText(_ value: Int?, approximate: Bool = false) -> String {
    value.map { "\(approximate ? "~" : "")\($0)%" } ?? "N/A"
}

private func spokenPercentage(_ value: Int?, approximate: Bool = false) -> String {
    value.map { "\(approximate ? "approximately " : "")\($0) percent" } ?? "unavailable"
}
