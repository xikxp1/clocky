import ClockyCore
import Foundation
import IOKit.ps

protocol BatteryProviding: Sendable {
    func readMac() async -> Int?
    func readAirPods() async -> AirPodsBattery?
    func readIPhone() async -> Int?
}

/// Each source has its own in-flight read and polling deadline.
enum BatterySource: CaseIterable, Sendable {
    case mac, iPhone, airPods
}

enum BatteryReading: Sendable {
    case mac(Int?)
    case iPhone(Int?)
    case iPhoneBLE(Int?)
    case airPods(AirPodsBattery?)

    func updating(_ snapshot: BatterySnapshot) -> BatterySnapshot {
        switch self {
        case .mac(let level):
            return BatterySnapshot(
                mac: level, iPhone: snapshot.iPhone, airPods: snapshot.airPods,
                iPhoneUsesBLE: snapshot.iPhoneUsesBLE
            )
        case .iPhone(let level):
            return BatterySnapshot(mac: snapshot.mac, iPhone: level, airPods: snapshot.airPods)
        case .iPhoneBLE(let level):
            return BatterySnapshot(
                mac: snapshot.mac, iPhone: level, airPods: snapshot.airPods, iPhoneUsesBLE: true
            )
        case .airPods(let battery):
            return BatterySnapshot(
                mac: snapshot.mac, iPhone: snapshot.iPhone, airPods: battery,
                iPhoneUsesBLE: snapshot.iPhoneUsesBLE
            )
        }
    }
}

extension BatteryProviding {
    func read(_ source: BatterySource) async -> BatteryReading {
        switch source {
        case .mac: return await .mac(readMac())
        case .iPhone: return await .iPhone(readIPhone())
        case .airPods: return await .airPods(readAirPods())
        }
    }
}

/// Fresh, best-effort readings only. Optional libimobiledevice tools are never
/// installed or invoked through a shell. Authentication requires an existing
/// pairing record and successful validation; no pair/unpair commands are issued.
struct SystemBatteryProvider: BatteryProviding {
    private let runner: any BatteryCommandRunning
    private let toolLocator: @Sendable (String) -> String?
    private let macReader: @Sendable () -> Int?
    private let helperTimeout: TimeInterval
    private let iPhoneSampleTimeout: TimeInterval
    private let maximumDeviceCandidates: Int

    init(
        runner: any BatteryCommandRunning = BatteryCommandRunner(),
        toolLocator: @escaping @Sendable (String) -> String? = { Self.findTool($0) },
        macReader: @escaping @Sendable () -> Int? = { Self.readMacBattery() },
        helperTimeout: TimeInterval = 2,
        iPhoneSampleTimeout: TimeInterval = 8,
        maximumDeviceCandidates: Int = 4
    ) {
        self.runner = runner
        self.toolLocator = toolLocator
        self.macReader = macReader
        self.helperTimeout = helperTimeout.isFinite ? max(0, helperTimeout) : 2
        self.iPhoneSampleTimeout = iPhoneSampleTimeout.isFinite ? max(0, iPhoneSampleTimeout) : 8
        self.maximumDeviceCandidates = max(0, maximumDeviceCandidates)
    }

    func read() async -> BatterySnapshot {
        guard !Task.isCancelled else { return BatterySnapshot() }
        // These nonisolated async operations do not run on the caller's MainActor.
        async let mac = readMac()
        async let airPods = readAirPods()
        async let iPhone = readIPhone()
        return await BatterySnapshot(mac: mac, iPhone: iPhone, airPods: airPods)
    }

    func readMac() async -> Int? {
        guard !Task.isCancelled, let level = macReader(), (0...100).contains(level) else {
            return nil
        }
        return level
    }

    func readAirPods() async -> AirPodsBattery? {
        guard !Task.isCancelled else { return nil }
        do {
            let data = try await runner.run(
                executable: "/usr/sbin/system_profiler",
                arguments: ["SPBluetoothDataType", "-json", "-timeout", "5"], timeout: 6
            )
            try Task.checkCancellation()
            return BatteryDataParser.airPods(from: data)
        } catch {
            return nil
        }
    }

    func readIPhone() async -> Int? {
        guard !Task.isCancelled, maximumDeviceCandidates > 0,
            let deviceIDTool = toolLocator("idevice_id"), deviceIDTool.hasPrefix("/"),
            let deviceInfoTool = toolLocator("ideviceinfo"), deviceInfoTool.hasPrefix("/"),
            let pairingTool = toolLocator("idevicepair"), pairingTool.hasPrefix("/")
        else {
            return nil
        }
        let deadline = ProcessInfo.processInfo.systemUptime + iPhoneSampleTimeout
        var candidatesRead = 0
        do {
            // USB is preferred. Network mode only uses already configured pairing;
            // the same UDID may be retried on Wi-Fi after an unreadable USB result.
            for network in [false, true] {
                guard candidatesRead < maximumDeviceCandidates else { return nil }
                guard
                    let list = try await helperCommand(
                        deviceIDTool, [network ? "-n" : "-l"], deadline: deadline
                    ), let identifiers = Self.deviceIdentifiers(from: list)
                else { continue }
                for identifier in identifiers.sorted() {
                    try Task.checkCancellation()
                    guard candidatesRead < maximumDeviceCandidates,
                        ProcessInfo.processInfo.systemUptime < deadline
                    else { return nil }
                    candidatesRead += 1
                    let selection = ["-u", identifier] + (network ? ["-n"] : [])
                    // `validate` can attempt pairing if no record exists. Check
                    // the saved HostID first, without starting a trusted session.
                    // Unlike `idevicepair list`, this also finds macOS records
                    // accessible through usbmuxd but not enumerable on disk.
                    guard
                        let hostData = try await helperCommand(
                            pairingTool, selection + ["hostid"], deadline: deadline
                        ),
                        let hostID = String(data: hostData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                        UUID(uuidString: hostID) != nil
                    else { continue }
                    // Identification works without authentication; avoid opening
                    // trusted sessions to devices that are not iPhones.
                    guard
                        let productData = try await helperCommand(
                            deviceInfoTool, ["-s"] + selection + ["-k", "ProductType"],
                            deadline: deadline
                        ),
                        let product = String(data: productData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                        product.hasPrefix("iPhone")
                    else { continue }
                    guard
                        try await helperCommand(
                            pairingTool, selection + ["validate"], deadline: deadline
                        ) != nil
                    else { continue }
                    // Do not use -s here: iOS can return an empty battery domain
                    // without an authenticated session, even on a trusted device.
                    guard
                        let batteryData = try await helperCommand(
                            deviceInfoTool, selection + ["-x", "-q", "com.apple.mobile.battery"],
                            deadline: deadline
                        ), let level = BatteryDataParser.iPhone(from: batteryData)
                    else { continue }
                    return level
                }
            }
        } catch {
            // Cancellation exits the entire search, rather than trying another UDID.
            return nil
        }
        return nil
    }

    private static func deviceIdentifiers(from data: Data) -> Set<String>? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return Set(
            text.split(whereSeparator: \.isNewline).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { identifier in
                !identifier.isEmpty && identifier.utf8.count <= 128
                    && identifier.unicodeScalars.allSatisfy {
                        CharacterSet.alphanumerics.contains($0) || $0 == "-"
                    }
            })
    }

    private func helperCommand(
        _ executable: String, _ arguments: [String], deadline: TimeInterval
    ) async throws -> Data? {
        try Task.checkCancellation()
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0, helperTimeout > 0 else { return nil }
        do {
            let data = try await runner.run(
                executable: executable, arguments: arguments,
                timeout: min(helperTimeout, remaining)
            )
            try Task.checkCancellation()
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    /// Finder-launched apps often lack Homebrew's bin directory in PATH.
    static func findTool(
        _ name: String,
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        isExecutable: (String) -> Bool = { candidate in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory)
                && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: candidate)
        }
    ) -> String? {
        guard ["idevice_id", "ideviceinfo", "idevicepair"].contains(name) else { return nil }
        let directories =
            ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
            + (path ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        var visited = Set<String>()
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name).path
            guard visited.insert(candidate).inserted else { continue }
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    static func readMacBattery() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return nil
        }
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any]
            else { continue }
            if let level = macPercentage(from: description) { return level }
        }
        return nil
    }

    /// An attached UPS must not become the Mac's battery. Capacity units are
    /// relative to Max Capacity, which is not guaranteed to be 100.
    static func macPercentage(from description: [String: Any]) -> Int? {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
            description[kIOPSIsPresentKey] as? Bool != false,
            let current = capacity(description[kIOPSCurrentCapacityKey]),
            let maximum = capacity(description[kIOPSMaxCapacityKey]),
            current >= 0, maximum > 0, current <= maximum
        else { return nil }
        return Int((current / maximum * 100).rounded())
    }

    private static func capacity(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite
        else { return nil }
        return number.doubleValue
    }
}
