import CoreBluetooth
import Foundation

struct BLEAdvertisement: Equatable, Sendable {
    let identifier: UUID
    let name: String?
    let manufacturerData: Data
}

@MainActor
protocol BLEBatteryAccessing: AnyObject {
    var status: String { get }
    func scan(timeout: TimeInterval) async -> [BLEAdvertisement]
    func readIPhone(identifier: UUID, timeout: TimeInterval) async -> Int?
    func stop()
}

// This value-only boundary lets tests exercise the entire request/GATT state machine
// without constructing a central manager. Callbacks and transport methods use MainActor.
enum BLEBatteryCentralState: Sendable {
    case unknown, resetting, poweredOn, poweredOff, denied, unsupported
}

struct BLEBatteryCharacteristic: Equatable, Sendable {
    let uuid: String
    let readable: Bool
}

enum BLEBatteryTransportEvent: Sendable {
    case state(BLEBatteryCentralState)
    case advertisement(scan: UUID, observation: BLEAdvertisement, observedAt: UInt64)
    case connected(request: UUID)
    case connectionFailed(request: UUID)
    case disconnected(request: UUID)
    case services(request: UUID, uuids: [String]?)
    case characteristics(request: UUID, service: String, values: [BLEBatteryCharacteristic]?)
    case value(request: UUID, service: String, characteristic: String, data: Data?)
}

@MainActor
protocol BLEBatteryTransport: AnyObject {
    var onEvent: (@MainActor (BLEBatteryTransportEvent) -> Void)? { get set }
    func activate()
    func startScan(id: UUID)
    func stopScan()
    func retrieve(identifier: UUID) -> Bool
    func connect(identifier: UUID, request: UUID) -> Bool
    func discoverServices(request: UUID, uuids: [String])
    func discoverCharacteristics(request: UUID, service: String, uuids: [String])
    func read(request: UUID, service: String, characteristic: String)
    func cancelConnection(request: UUID)
    func shutdown()
}

/// Bluetooth SIG UUIDs may arrive in 16-, 32-, or full 128-bit form.
enum BLEBatteryUUID {
    static func canonical(_ uuid: String) -> String {
        let value = uuid.uppercased()
        if value.count == 36, value.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            return canonical(String(value.prefix(8)))
        }
        if value.count == 8, value.hasPrefix("0000") { return String(value.suffix(4)) }
        return value
    }
}

private enum BLEBatteryLimits {
    static let observations = 128
    static let nameBytes = 128
    static let manufacturerBytes = 512
    static let metadataBytes = 128

    static func name(_ name: String?) -> String? {
        guard let name else { return nil }
        var bytes = Data(name.utf8.prefix(nameBytes))
        // Never split a UTF-8 code point or retain an unbounded grapheme cluster.
        while !bytes.isEmpty {
            if let value = String(data: bytes, encoding: .utf8) { return value }
            bytes.removeLast()
        }
        return nil
    }

    static func advertisement(_ value: BLEAdvertisement) -> BLEAdvertisement {
        BLEAdvertisement(
            identifier: value.identifier, name: name(value.name),
            manufacturerData: Data(value.manufacturerData.prefix(manufacturerBytes)))
    }
}

/// Demand is the opt-in boundary: construction (including the native transport's
/// construction) does not create CBCentralManager. The caller must enforce saved
/// selections/opt-in and prefer its primary providers before invoking this fallback.
/// Advertisement names, UUIDs, and even GATT metadata are not authenticated identity.
/// The caller must throttle/suppress monitor-triggered fallback reads: this app's
/// own GATT connect/disconnect can also produce BluetoothChangeMonitor events.
@MainActor
final class CoreBluetoothBatteryAccess: BLEBatteryAccessing {
    private final class ScanRequest {
        let continuation: CheckedContinuation<[BLEAdvertisement], Never>
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var observations: [UUID: (advertisement: BLEAdvertisement, observedAt: UInt64)] = [:]
        var order: [UUID] = []
        var deadline: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<[BLEAdvertisement], Never>) {
            self.continuation = continuation
        }
    }

    private enum PhonePhase {
        case waitingForPower, locating, connecting, services, characteristics
    }

    private final class PhoneRequest {
        let id: UUID
        let identifier: UUID
        let continuation: CheckedContinuation<Int?, Never>
        var phase = PhonePhase.waitingForPower
        var connectionRequested = false
        var servicesPending: Set<String> = []
        var readsPending: Set<String> = []
        var values: [String: Data] = [:]
        var deadline: Task<Void, Never>?

        init(id: UUID, identifier: UUID, continuation: CheckedContinuation<Int?, Never>) {
            self.id = id
            self.identifier = identifier
            self.continuation = continuation
        }
    }

    private static let fields = ["180F": ["2A19"], "180A": ["2A29", "2A24"]]
    private let makeTransport: @MainActor () -> any BLEBatteryTransport
    private let disconnectTimeout: TimeInterval
    private var transport: (any BLEBatteryTransport)?
    private var transportID: UUID?
    private var centralState = BLEBatteryCentralState.unknown
    private var radioScanID: UUID?
    private var scans: [UUID: ScanRequest] = [:]
    private var phone: PhoneRequest?
    private var disconnecting: UUID?
    private var disconnectDeadline: Task<Void, Never>?
    private(set) var status = "Bluetooth idle"

    convenience init() {
        self.init(makeTransport: { NativeBLEBatteryTransport() })
    }

    init(
        makeTransport: @escaping @MainActor () -> any BLEBatteryTransport,
        disconnectTimeout: TimeInterval = 2
    ) {
        self.makeTransport = makeTransport
        self.disconnectTimeout = Self.boundedTimeout(disconnectTimeout).map { min($0, 2) } ?? 2
    }

    func scan(timeout: TimeInterval) async -> [BLEAdvertisement] {
        guard !Task.isCancelled else { return [] }
        guard let timeout = Self.boundedTimeout(timeout) else {
            status = "Bluetooth scan timed out"
            return []
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: [])
                    return
                }
                let request = ScanRequest(continuation)
                scans[id] = request
                request.deadline = deadline(after: timeout) { [weak self] in
                    self?.finishScan(id, includeObservations: true)
                }
                ensureTransport()
                drive()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishScan(id, includeObservations: false) }
        }
    }

    func readIPhone(identifier: UUID, timeout: TimeInterval) async -> Int? {
        guard !Task.isCancelled else { return nil }
        guard timeout.isFinite, let timeout = Self.boundedTimeout(min(timeout, 10)) else {
            status = "iPhone Bluetooth read timed out"
            return nil
        }
        // One pending read at a time. A replacement can wait inside its deadline
        // for prior teardown, but must never reconnect before cleanup completes.
        guard phone == nil else {
            status = "iPhone Bluetooth connection unavailable (busy)"
            return nil
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                let request = PhoneRequest(
                    id: id, identifier: identifier, continuation: continuation)
                phone = request
                if disconnecting != nil {
                    status = "Waiting for previous iPhone connection cleanup"
                }
                request.deadline = deadline(after: timeout) { [weak self] in
                    self?.finishPhone(id, result: nil, message: "iPhone Bluetooth read timed out")
                }
                ensureTransport()
                drive()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishPhone(id, result: nil, message: "iPhone Bluetooth read cancelled")
            }
        }
    }

    func stop() {
        for id in Array(scans.keys) { finishScan(id, includeObservations: false) }
        if let phone { finishPhone(phone.id, result: nil, message: "Bluetooth stopped") }
        synchronizeScanning()
        status = "Bluetooth stopped"
    }

    private static func boundedTimeout(_ timeout: TimeInterval) -> TimeInterval? {
        guard timeout.isFinite, timeout > 0 else { return nil }
        return min(timeout, 60)
    }

    private func deadline(
        after seconds: TimeInterval, action: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        // Task deadlines continue in menu tracking mode (unlike default-mode timers).
        let expiresAt = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        return Task { @MainActor in
            let now = DispatchTime.now().uptimeNanoseconds
            do { try await Task.sleep(nanoseconds: expiresAt > now ? expiresAt - now : 0) } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private func ensureTransport() {
        guard transport == nil else { return }
        let id = UUID()
        let transport = makeTransport()
        self.transport = transport
        transportID = id
        centralState = .unknown
        transport.onEvent = { [weak self] event in
            guard let self, self.transportID == id else { return }
            self.receive(event)
        }
        status = "Waiting for Bluetooth authorization or power"
        transport.activate()
    }

    private func drive() {
        guard centralState == .poweredOn else { return }
        if disconnecting == nil, let phone, phone.phase == .waitingForPower {
            if transport?.retrieve(identifier: phone.identifier) == true {
                connect(phone)
            } else {
                phone.phase = .locating
                status = "Looking for selected iPhone"
            }
        }
        synchronizeScanning()
    }

    private func synchronizeScanning() {
        let needed = !scans.isEmpty || phone?.phase == .locating
        if needed, centralState == .poweredOn, radioScanID == nil {
            let id = UUID()
            radioScanID = id
            transport?.startScan(id: id)
            if phone == nil { status = "Scanning for Bluetooth devices" }
        } else if !needed || centralState != .poweredOn {
            if radioScanID != nil {
                radioScanID = nil
                transport?.stopScan()
            }
        }
        if scans.isEmpty, phone == nil, disconnecting == nil { releaseTransport() }
    }

    private func connect(_ request: PhoneRequest) {
        guard phone?.id == request.id, disconnecting == nil else { return }
        request.phase = .connecting
        request.connectionRequested = true
        status = "Connecting to selected iPhone"
        if transport?.connect(identifier: request.identifier, request: request.id) != true {
            request.connectionRequested = false
            finishPhone(request.id, result: nil, message: "Selected iPhone unavailable")
        }
    }

    private func receive(_ event: BLEBatteryTransportEvent) {
        switch event {
        case .state(let state):
            centralState = state
            switch state {
            case .poweredOn: drive()
            case .unknown, .resetting:
                // CoreBluetooth invalidates retrieved peripherals on reset. Fail the
                // active read and retire its delegate generation, rather than letting
                // queued service/value callbacks use invalid native references.
                if let phone, phone.connectionRequested {
                    finishPhone(
                        phone.id, result: nil, message: "Bluetooth connection reset",
                        disconnected: true)
                } else {
                    synchronizeScanning()
                    status = "Waiting for Bluetooth authorization or power"
                }
            case .poweredOff, .denied, .unsupported:
                let message: String
                switch state {
                case .poweredOff: message = "Bluetooth is off"
                case .denied: message = "Bluetooth access denied"
                default: message = "Bluetooth is unsupported"
                }
                for id in Array(scans.keys) { finishScan(id, includeObservations: false) }
                if let phone { finishPhone(phone.id, result: nil, message: message) }
                status = message
            }
        case .advertisement(let scan, let observation, let observedAt):
            guard radioScanID == scan, centralState == .poweredOn else { return }
            let bounded = BLEBatteryLimits.advertisement(observation)
            for request in scans.values where observedAt >= request.startedAt {
                if let previous = request.observations[bounded.identifier],
                    previous.observedAt > observedAt
                {
                    continue
                }
                if request.observations[bounded.identifier] == nil {
                    guard request.order.count < BLEBatteryLimits.observations else { continue }
                    request.order.append(bounded.identifier)
                }
                request.observations[bounded.identifier] = (bounded, observedAt)
            }
            if let phone, phone.phase == .locating, phone.identifier == observation.identifier {
                // No name-based guessing and no connection to any other discovered UUID.
                connect(phone)
                synchronizeScanning()
            }
        case .connected(let id):
            guard let phone, phone.id == id, phone.phase == .connecting else { return }
            phone.phase = .services
            transport?.discoverServices(request: id, uuids: ["180F", "180A"])
        case .connectionFailed(let id), .disconnected(let id):
            if disconnecting == id {
                finishDisconnect(id)
                return
            }
            finishPhone(id, result: nil, message: "Selected iPhone unavailable", disconnected: true)
        case .services(let id, let uuids):
            guard let phone, phone.id == id, phone.phase == .services else { return }
            guard let uuids,
                Set(Self.fields.keys).isSubset(of: Set(uuids.map(BLEBatteryUUID.canonical)))
            else {
                finishPhone(
                    id, result: nil, message: "Required iPhone battery services unavailable")
                return
            }
            phone.phase = .characteristics
            phone.servicesPending = Set(Self.fields.keys)
            for service in ["180F", "180A"] {
                transport?.discoverCharacteristics(
                    request: id, service: service, uuids: Self.fields[service]!)
            }
        case .characteristics(let id, let rawService, let values):
            let service = BLEBatteryUUID.canonical(rawService)
            guard let phone, phone.id == id, phone.phase == .characteristics,
                phone.servicesPending.remove(service) != nil,
                let required = Self.fields[service]
            else { return }
            guard let values,
                required.allSatisfy({ uuid in
                    values.contains { BLEBatteryUUID.canonical($0.uuid) == uuid && $0.readable }
                })
            else {
                finishPhone(id, result: nil, message: "Required iPhone battery fields unavailable")
                return
            }
            for uuid in required { phone.readsPending.insert(uuid) }
            for uuid in required {
                transport?.read(request: id, service: service, characteristic: uuid)
            }
        case .value(let id, let rawService, let rawCharacteristic, let data):
            let service = BLEBatteryUUID.canonical(rawService)
            let characteristic = BLEBatteryUUID.canonical(rawCharacteristic)
            guard let phone, phone.id == id, phone.phase == .characteristics,
                Self.fields[service]?.contains(characteristic) == true,
                phone.readsPending.remove(characteristic) != nil
            else { return }
            guard let data, !data.isEmpty, data.count <= BLEBatteryLimits.metadataBytes else {
                finishPhone(id, result: nil, message: "iPhone battery fields unavailable")
                return
            }
            if characteristic == "2A19", data.count != 1 || (data.first ?? 255) > 100 {
                finishPhone(id, result: nil, message: "iPhone battery level unavailable")
                return
            }
            if characteristic == "2A29", String(data: data, encoding: .utf8) != "Apple Inc." {
                finishPhone(id, result: nil, message: "Selected Bluetooth device is not an iPhone")
                return
            }
            if characteristic == "2A24",
                String(data: data, encoding: .utf8)?.hasPrefix("iPhone") != true
            {
                finishPhone(id, result: nil, message: "Selected Bluetooth device is not an iPhone")
                return
            }
            phone.values[characteristic] = data
            if phone.servicesPending.isEmpty, phone.readsPending.isEmpty,
                phone.values.count == 3, let battery = phone.values["2A19"]?.first
            {
                finishPhone(
                    id, result: Int(battery), message: "iPhone Bluetooth battery read complete")
            }
        }
    }

    private func finishScan(_ id: UUID, includeObservations: Bool) {
        guard let request = scans.removeValue(forKey: id) else { return }
        request.deadline?.cancel()
        let observations =
            includeObservations
            ? request.order.compactMap { request.observations[$0]?.advertisement } : []
        status =
            includeObservations
            ? (observations.isEmpty ? "Bluetooth scan timed out" : "Bluetooth scan complete")
            : "Bluetooth scan cancelled"
        synchronizeScanning()
        request.continuation.resume(returning: observations)
    }

    private func finishPhone(_ id: UUID, result: Int?, message: String, disconnected: Bool = false)
    {
        guard let request = phone, request.id == id else { return }
        phone = nil
        request.deadline?.cancel()
        status = message
        if request.connectionRequested {
            if disconnected {
                // A new manager/delegate generation also prevents delayed peripheral
                // callbacks (which have no native operation ID) entering the next read.
                recycleTransport()
            } else {
                disconnecting = id
                disconnectDeadline = deadline(after: disconnectTimeout) { [weak self] in
                    self?.finishDisconnect(id)
                }
                transport?.cancelConnection(request: id)
            }
        }
        synchronizeScanning()
        request.continuation.resume(returning: result)
    }

    private func finishDisconnect(_ id: UUID) {
        guard disconnecting == id else { return }
        disconnecting = nil
        disconnectDeadline?.cancel()
        disconnectDeadline = nil
        // cancelPeripheralConnection is nonblocking and a pending connect may not
        // send didDisconnect. Retire this manager after a bounded grace period;
        // never reuse its peripherals/delegates, or retry during that grace period.
        recycleTransport()
    }

    private func releaseTransport() {
        let previous = transport
        transport = nil
        transportID = nil
        radioScanID = nil
        centralState = .unknown
        previous?.onEvent = nil
        previous?.shutdown()
    }

    private func recycleTransport() {
        releaseTransport()
        if !scans.isEmpty || phone != nil {
            ensureTransport()
            drive()
        }
    }
}

// CoreBluetooth references only cross the callback -> MainActor hop inside this
// private wrapper. They are never queried/called off the central's main queue.
private struct NativeBLECallback: @unchecked Sendable {
    enum Kind {
        case state(BLEBatteryCentralState)
        case advertisement(CBPeripheral, [String: Any], UInt64)
        case connected(CBPeripheral)
        case failed(CBPeripheral)
        case disconnected(CBPeripheral)
        case services(CBPeripheral, Bool)
        case characteristics(CBPeripheral, CBService, Bool)
        case value(CBPeripheral, CBCharacteristic, Data?, Bool)
    }
    let kind: Kind
}

/// These delegates touch no mutable actor state. The immutable callbacks capture
/// their generation, so even already-enqueued callbacks cannot cross a restart.
private final class NativeBLECentralDelegate: NSObject, CBCentralManagerDelegate {
    let callback: @Sendable (NativeBLECallback) -> Void
    init(callback: @escaping @Sendable (NativeBLECallback) -> Void) {
        self.callback = callback
        super.init()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Snapshot on the native callback queue. Reading central.state after an
        // actor hop can miss a rapid poweredOff/resetting -> poweredOn transition.
        let state: BLEBatteryCentralState
        if CBCentralManager.authorization == .denied
            || CBCentralManager.authorization == .restricted
        {
            state = .denied
        } else {
            switch central.state {
            case .poweredOn: state = .poweredOn
            case .poweredOff: state = .poweredOff
            case .unauthorized: state = .denied
            case .unsupported: state = .unsupported
            case .resetting: state = .resetting
            default: state = .unknown
            }
        }
        callback(.init(kind: .state(state)))
    }
    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        callback(
            .init(
                kind: .advertisement(
                    peripheral, advertisementData, DispatchTime.now().uptimeNanoseconds)))
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        callback(.init(kind: .connected(peripheral)))
    }
    func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        callback(.init(kind: .failed(peripheral)))
    }
    func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        callback(.init(kind: .disconnected(peripheral)))
    }
}

private final class NativeBLEPeripheralDelegate: NSObject, CBPeripheralDelegate {
    let callback: @Sendable (NativeBLECallback) -> Void
    init(callback: @escaping @Sendable (NativeBLECallback) -> Void) {
        self.callback = callback
        super.init()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        callback(.init(kind: .services(peripheral, error != nil)))
    }
    func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        callback(.init(kind: .characteristics(peripheral, service, error != nil)))
    }
    func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // Snapshot the value on CoreBluetooth's main callback queue, before another
        // callback could overwrite it. No cached characteristic.value is read elsewhere.
        callback(
            .init(kind: .value(peripheral, characteristic, characteristic.value, error != nil)))
    }
}

@MainActor
private final class NativeBLEBatteryTransport: BLEBatteryTransport {
    var onEvent: (@MainActor (BLEBatteryTransportEvent) -> Void)?
    private var central: CBCentralManager?
    private var centralDelegate: NativeBLECentralDelegate?
    private var peripheralDelegate: NativeBLEPeripheralDelegate?
    private var generation: UUID?
    private var scanID: UUID?
    private var selectedIdentifier: UUID?
    private var peripheral: CBPeripheral?
    private var requestID: UUID?
    private var cancellationIssued = false
    private var services: [String: CBService] = [:]
    private var characteristics: [String: CBCharacteristic] = [:]

    // Deliberately no CBCentralManager in init, static storage, or property initializers.
    func activate() {
        guard central == nil else { return }
        let generation = UUID()
        self.generation = generation
        let observer = NativeBLECentralDelegate { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.receive(event)
            }
        }
        centralDelegate = observer
        central = CBCentralManager(
            delegate: observer, queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func startScan(id: UUID) {
        guard let central, central.state == .poweredOn else { return }
        scanID = id
        // Apple manufacturer frames need an unfiltered scan; duplicates let each
        // consumer keep the most recently observed payload for a UUID.
        central.scanForPeripherals(
            withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() {
        scanID = nil
        if central?.isScanning == true { central?.stopScan() }
    }

    func retrieve(identifier: UUID) -> Bool {
        selectedIdentifier = identifier
        guard let central, central.state == .poweredOn else { return false }
        peripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first
        return peripheral != nil
    }

    func connect(identifier: UUID, request: UUID) -> Bool {
        guard requestID == nil, let central, central.state == .poweredOn,
            let peripheral, peripheral.identifier == identifier, selectedIdentifier == identifier,
            let generation
        else { return false }
        requestID = request
        cancellationIssued = false
        let observer = NativeBLEPeripheralDelegate { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation, self.requestID == request else {
                    return
                }
                self.receive(event)
            }
        }
        peripheralDelegate = observer
        peripheral.delegate = observer
        // Always register this central's own connection interest, even if another
        // app already has a physical link. Cancel only this interest, never pair/unpair.
        central.connect(peripheral, options: nil)
        return true
    }

    func discoverServices(request: UUID, uuids: [String]) {
        guard requestID == request, !cancellationIssued else { return }
        peripheral?.discoverServices(uuids.map { CBUUID(string: $0) })
    }

    func discoverCharacteristics(request: UUID, service: String, uuids: [String]) {
        guard requestID == request, !cancellationIssued, let service = services[service] else {
            return
        }
        peripheral?.discoverCharacteristics(uuids.map { CBUUID(string: $0) }, for: service)
    }

    func read(request: UUID, service: String, characteristic: String) {
        guard requestID == request, !cancellationIssued,
            let value = characteristics[service + ":" + characteristic],
            value.properties.contains(.read)
        else { return }
        peripheral?.readValue(for: value)
    }

    func cancelConnection(request: UUID) {
        guard requestID == request, !cancellationIssued, let peripheral else { return }
        cancellationIssued = true
        if central?.state == .poweredOn { central?.cancelPeripheralConnection(peripheral) }
    }

    func shutdown() {
        generation = nil
        onEvent = nil
        stopScan()
        if let requestID { cancelConnection(request: requestID) }
        peripheral?.delegate = nil
        central?.delegate = nil
        peripheral = nil
        central = nil
        centralDelegate = nil
        peripheralDelegate = nil
        requestID = nil
        selectedIdentifier = nil
        services.removeAll()
        characteristics.removeAll()
    }

    private func receive(_ event: NativeBLECallback) {
        switch event.kind {
        case .state(let state):
            if state == .unknown || state == .resetting {
                // Reset invalidates the native peripheral. Do not issue cancellation
                // on that stale reference even if power recovered before this hop.
                requestID = nil
            }
            onEvent?(.state(state))
        case .advertisement(let discovered, let data, let observedAt):
            guard let scanID else { return }
            if discovered.identifier == selectedIdentifier, requestID == nil {
                peripheral = discovered
            }
            let observation = BLEAdvertisement(
                identifier: discovered.identifier,
                name: BLEBatteryLimits.name(
                    data[CBAdvertisementDataLocalNameKey] as? String ?? discovered.name),
                manufacturerData: Data(
                    (data[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data())
                        .prefix(BLEBatteryLimits.manufacturerBytes)))
            onEvent?(.advertisement(scan: scanID, observation: observation, observedAt: observedAt))
        case .connected(let device):
            guard device === peripheral, let requestID, !cancellationIssued else { return }
            onEvent?(.connected(request: requestID))
        case .failed(let device), .disconnected(let device):
            guard device === peripheral, let requestID else { return }
            // The transport is retired after this callback. Clear ownership first
            // so shutdown cannot issue cancellation on an already ended request.
            self.requestID = nil
            onEvent?(.disconnected(request: requestID))
        case .services(let device, let failed):
            guard device === peripheral, let requestID, !cancellationIssued else { return }
            services.removeAll()
            for service in device.services ?? [] {
                let id = BLEBatteryUUID.canonical(service.uuid.uuidString)
                if ["180A", "180F"].contains(id) { services[id] = service }
            }
            onEvent?(.services(request: requestID, uuids: failed ? nil : Array(services.keys)))
        case .characteristics(let device, let service, let failed):
            let serviceID = BLEBatteryUUID.canonical(service.uuid.uuidString)
            guard device === peripheral, let requestID, !cancellationIssued,
                services[serviceID] === service
            else { return }
            let required = serviceID == "180F" ? ["2A19"] : ["2A29", "2A24"]
            var values: [BLEBatteryCharacteristic] = []
            for value in service.characteristics ?? [] {
                let id = BLEBatteryUUID.canonical(value.uuid.uuidString)
                guard required.contains(id) else { continue }
                characteristics[serviceID + ":" + id] = value
                values.append(.init(uuid: id, readable: value.properties.contains(.read)))
            }
            onEvent?(
                .characteristics(
                    request: requestID, service: serviceID, values: failed ? nil : values))
        case .value(let device, let characteristic, let data, let failed):
            // Optional promotion works with SDKs importing this weak back-pointer
            // as either CBService or CBService?. Never force-unwrap native pointers.
            let owningService: CBService? = characteristic.service
            let characteristicID = BLEBatteryUUID.canonical(characteristic.uuid.uuidString)
            guard device === peripheral, let requestID, !cancellationIssued,
                let service = owningService.map({ BLEBatteryUUID.canonical($0.uuid.uuidString) }),
                characteristics[service + ":" + characteristicID] === characteristic
            else { return }
            // Oversized/failed fields are rejected, not truncated into a valid identity.
            let value = !failed && (data?.count ?? 0) <= BLEBatteryLimits.metadataBytes ? data : nil
            onEvent?(
                .value(
                    request: requestID, service: service,
                    characteristic: characteristicID, data: value))
        }
    }

    deinit {
        // A released owner can be off actor. Transfer private native references to
        // the main queue for cleanup rather than making CoreBluetooth calls here.
        let hasRequest = requestID != nil
        let didCancel = cancellationIssued
        let cleanup = NativeBLECleanup(
            central: central, peripheral: peripheral,
            cancel: hasRequest && !didCancel)
        Task { @MainActor in cleanup.run() }
    }
}

private struct NativeBLECleanup: @unchecked Sendable {
    let central: CBCentralManager?
    let peripheral: CBPeripheral?
    let cancel: Bool

    @MainActor func run() {
        central?.delegate = nil
        peripheral?.delegate = nil
        if central?.isScanning == true { central?.stopScan() }
        if cancel, let peripheral, central?.state == .poweredOn {
            central?.cancelPeripheralConnection(peripheral)
        }
    }
}
