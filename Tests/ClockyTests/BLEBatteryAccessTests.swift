import Foundation
import XCTest

@testable import Clocky

@MainActor
final class BLEBatteryAccessTests: XCTestCase {
    /// Value-only transport: no test constructs CBCentralManager/CBPeripheral or
    /// requires authorization, paired devices, a radio, or any Bluetooth hardware.
    @MainActor
    private final class Transport: BLEBatteryTransport {
        var onEvent: (@MainActor (BLEBatteryTransportEvent) -> Void)?
        var retainedCallback: (@MainActor (BLEBatteryTransportEvent) -> Void)?
        var initialState = BLEBatteryCentralState.poweredOn
        var known: Set<UUID> = []
        var connectionAvailable = true
        var scanID: UUID?
        var activations = 0
        var scanStarts = 0
        var scanStops = 0
        var shutdowns = 0
        var retrievals: [UUID] = []
        var connections: [(identifier: UUID, request: UUID)] = []
        var cancellations: [UUID] = []
        var serviceRequests: [(request: UUID, uuids: [String])] = []
        var characteristicRequests: [(request: UUID, service: String, uuids: [String])] = []
        var reads: [(request: UUID, service: String, characteristic: String)] = []

        func activate() {
            activations += 1
            retainedCallback = onEvent
            emit(.state(initialState))
        }
        // Intentionally retain/deliver old callbacks even after shutdown.
        func emit(_ event: BLEBatteryTransportEvent) { retainedCallback?(event) }
        func startScan(id: UUID) {
            scanID = id
            scanStarts += 1
        }
        func stopScan() {
            scanID = nil
            scanStops += 1
        }
        func retrieve(identifier: UUID) -> Bool {
            retrievals.append(identifier)
            return known.contains(identifier)
        }
        func connect(identifier: UUID, request: UUID) -> Bool {
            guard connectionAvailable, known.contains(identifier) else { return false }
            connections.append((identifier, request))
            return true
        }
        func discoverServices(request: UUID, uuids: [String]) {
            serviceRequests.append((request, uuids))
        }
        func discoverCharacteristics(request: UUID, service: String, uuids: [String]) {
            characteristicRequests.append((request, service, uuids))
        }
        func read(request: UUID, service: String, characteristic: String) {
            reads.append((request, service, characteristic))
        }
        func cancelConnection(request: UUID) { cancellations.append(request) }
        func shutdown() {
            shutdowns += 1
            if scanID != nil { stopScan() }
            onEvent = nil
        }
        func advertise(
            _ identifier: UUID, name: String? = "Candidate", data: Data = Data(),
            observedAt: UInt64 = DispatchTime.now().uptimeNanoseconds
        ) {
            guard let scanID else { return }
            known.insert(identifier)
            emit(
                .advertisement(
                    scan: scanID,
                    observation: BLEAdvertisement(
                        identifier: identifier, name: name, manufacturerData: data),
                    observedAt: observedAt))
        }
        func value(_ request: UUID, _ field: String, _ data: Data?, service: String? = nil) {
            emit(
                .value(
                    request: request, service: service ?? (field == "2A19" ? "180F" : "180A"),
                    characteristic: field, data: data))
        }
        func acknowledge(_ request: UUID) { emit(.disconnected(request: request)) }
    }

    @MainActor
    private final class Pool {
        var state = BLEBatteryCentralState.poweredOn
        var known: Set<UUID> = []
        var transports: [Transport] = []
        func make() -> Transport {
            let transport = Transport()
            transport.initialState = state
            transport.known = known
            transports.append(transport)
            return transport
        }
    }

    private struct Fixture {
        let pool: Pool
        let access: CoreBluetoothBatteryAccess
    }

    private func fixture(
        state: BLEBatteryCentralState = .poweredOn, known: Set<UUID> = [],
        disconnectTimeout: TimeInterval = 1
    ) -> Fixture {
        let pool = Pool()
        pool.state = state
        pool.known = known
        let access = CoreBluetoothBatteryAccess(
            makeTransport: { pool.make() }, disconnectTimeout: disconnectTimeout)
        addTeardownBlock { @MainActor in access.stop() }
        return Fixture(pool: pool, access: access)
    }

    private func eventually(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Condition not met within two seconds", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func beginPhone(
        _ fixture: Fixture, identifier: UUID, timeout: TimeInterval = 1
    ) async throws -> (Task<Int?, Never>, Transport, UUID) {
        let previousConnections = fixture.pool.transports.reduce(0) { $0 + $1.connections.count }
        let task = Task {
            await fixture.access.readIPhone(identifier: identifier, timeout: timeout)
        }
        await eventually {
            fixture.pool.transports.reduce(0) { $0 + $1.connections.count } > previousConnections
        }
        let transport = try XCTUnwrap(fixture.pool.transports.last)
        let request = try XCTUnwrap(transport.connections.first?.request)
        return (task, transport, request)
    }

    private func discover(_ transport: Transport, _ request: UUID, metadataFirst: Bool = false) {
        transport.emit(.connected(request: request))
        transport.emit(.services(request: request, uuids: ["180A", "180F", "1234"]))
        let battery = BLEBatteryTransportEvent.characteristics(
            request: request, service: "180F", values: [.init(uuid: "2A19", readable: true)])
        let metadata = BLEBatteryTransportEvent.characteristics(
            request: request, service: "180A",
            values: [.init(uuid: "2A29", readable: true), .init(uuid: "2A24", readable: true)])
        transport.emit(metadataFirst ? metadata : battery)
        transport.emit(metadataFirst ? battery : metadata)
    }

    private func validValues(_ transport: Transport, _ request: UUID, battery: UInt8 = 64) {
        transport.value(request, "2A19", Data([battery]))
        transport.value(request, "2A29", Data("Apple Inc.".utf8))
        transport.value(request, "2A24", Data("iPhone16,1".utf8))
    }

    func testConstructionStopInvalidTimeoutAndPreCancelledDemandAreLazy() async {
        let f = fixture()
        f.access.stop()
        f.access.stop()
        XCTAssertTrue(f.pool.transports.isEmpty)
        for timeout in [0, -1, .infinity, .nan] as [TimeInterval] {
            let scan = await f.access.scan(timeout: timeout)
            let phone = await f.access.readIPhone(identifier: UUID(), timeout: timeout)
            XCTAssertTrue(scan.isEmpty)
            XCTAssertNil(phone)
        }
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            let scan = await f.access.scan(timeout: 1)
            let phone = await f.access.readIPhone(identifier: UUID(), timeout: 1)
            XCTAssertTrue(scan.isEmpty)
            XCTAssertNil(phone)
        }
        await cancelled.value
        XCTAssertTrue(f.pool.transports.isEmpty)
    }

    func testConcurrentScansShareRadioAndEachHasOnlyFreshLatestObservations() async throws {
        let f = fixture()
        let first = Task { await f.access.scan(timeout: 0.15) }
        await eventually { f.pool.transports.first?.scanStarts == 1 }
        let transport = try XCTUnwrap(f.pool.transports.first)
        let onlyFirst = UUID()
        let shared = UUID()
        transport.advertise(onlyFirst, data: Data([1]))
        transport.advertise(shared, data: Data([2]))
        let queuedBeforeSecond = DispatchTime.now().uptimeNanoseconds
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return await f.access.scan(timeout: 0.30)
        }
        await eventually { secondStarted }
        transport.advertise(UUID(), observedAt: 0)  // Definitely predates both requests.
        transport.advertise(onlyFirst, data: Data([3]), observedAt: queuedBeforeSecond)
        let older = DispatchTime.now().uptimeNanoseconds
        transport.advertise(shared, data: Data([4]), observedAt: older)
        transport.advertise(shared, data: Data([5]))
        transport.advertise(shared, data: Data([4]), observedAt: older)
        XCTAssertEqual(transport.scanStarts, 1)
        let firstResult = await first.value
        XCTAssertEqual(Set(firstResult.map(\.identifier)), Set([onlyFirst, shared]))
        XCTAssertEqual(
            firstResult.first { $0.identifier == onlyFirst }?.manufacturerData, Data([3]))
        XCTAssertEqual(firstResult.first { $0.identifier == shared }?.manufacturerData, Data([5]))
        XCTAssertEqual(transport.scanStops, 0, "One consumer's deadline cannot stop the other")
        let secondResult = await second.value
        XCTAssertEqual(
            secondResult,
            [BLEAdvertisement(identifier: shared, name: "Candidate", manufacturerData: Data([5]))])
        XCTAssertEqual(transport.scanStops, 1)
        XCTAssertEqual(transport.shutdowns, 1)
    }

    func testCancellingOneScanReturnsPromptlyAndLeavesOtherConsumerRunning() async throws {
        let f = fixture()
        let first = Task { await f.access.scan(timeout: 1) }
        await eventually { f.pool.transports.first?.scanStarts == 1 }
        let transport = try XCTUnwrap(f.pool.transports.first)
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return await f.access.scan(timeout: 0.15)
        }
        await eventually { secondStarted }
        transport.advertise(UUID())
        var cancelledReturned = false
        first.cancel()
        let observer = Task {
            _ = await first.value
            cancelledReturned = true
        }
        await eventually { cancelledReturned }
        let cancelled = await first.value
        XCTAssertTrue(cancelled.isEmpty)
        XCTAssertEqual(transport.scanStops, 0)
        let active = await second.value
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(transport.scanStops, 1)
        await observer.value
    }

    func testScanBoundsCountNameAndDataWithoutRetainingResultsForNextRequest() async throws {
        let f = fixture()
        let scan = Task { await f.access.scan(timeout: 0.15) }
        await eventually { f.pool.transports.first?.scanStarts == 1 }
        let transport = try XCTUnwrap(f.pool.transports.first)
        let first = UUID()
        let hugeName = String(repeating: "🪫\u{301}", count: 400)
        transport.advertise(first, name: hugeName, data: Data(repeating: 1, count: 10_000))
        for _ in 0..<150 {
            transport.advertise(UUID(), name: hugeName, data: Data(repeating: 2, count: 1_000))
        }
        transport.advertise(first, name: hugeName, data: Data([9]))
        let result = await scan.value
        XCTAssertEqual(result.count, 128)
        XCTAssertTrue(
            result.allSatisfy {
                ($0.name?.utf8.count ?? 0) <= 128 && $0.manufacturerData.count <= 512
            })
        XCTAssertEqual(result.first?.manufacturerData, Data([9]))

        let next = Task { await f.access.scan(timeout: 0.03) }
        await eventually { f.pool.transports.count == 2 }
        transport.advertise(first, data: Data([99]))
        let nextResult = await next.value
        XCTAssertTrue(nextResult.isEmpty, "Never replay previous observations/history")
    }

    func testNilNameAndMissingManufacturerDataAreValidFreshObservations() async throws {
        let f = fixture()
        let task = Task { await f.access.scan(timeout: 0.03) }
        await eventually { f.pool.transports.first?.scanStarts == 1 }
        let transport = try XCTUnwrap(f.pool.transports.first)
        let identifier = UUID()
        transport.advertise(identifier, name: nil)
        let values = await task.value
        XCTAssertEqual(
            values, [BLEAdvertisement(identifier: identifier, name: nil, manufacturerData: Data())])
    }

    func testUnknownInitializationAndResettingAreBoundedByEachRequestsDeadline() async {
        for state in [BLEBatteryCentralState.unknown, .resetting] {
            let f = fixture(state: state)
            async let scan = f.access.scan(timeout: 0.03)
            async let phone = f.access.readIPhone(identifier: UUID(), timeout: 0.06)
            let (observations, battery) = await (scan, phone)
            XCTAssertTrue(observations.isEmpty)
            XCTAssertNil(battery)
            XCTAssertTrue(f.access.status.contains("timed out"))
            XCTAssertEqual(f.pool.transports.count, 1)
            XCTAssertEqual(f.pool.transports.first?.scanStarts, 0)
            XCTAssertEqual(f.pool.transports.first?.connections.count, 0)
            XCTAssertEqual(f.pool.transports.first?.shutdowns, 1)
        }
    }

    func testOffDeniedAndUnsupportedNeverStartRadioOrConnect() async {
        let cases: [(BLEBatteryCentralState, String)] = [
            (.poweredOff, "off"), (.denied, "denied"), (.unsupported, "unsupported"),
        ]
        for (state, message) in cases {
            let f = fixture(state: state)
            let scan = await f.access.scan(timeout: 1)
            XCTAssertTrue(scan.isEmpty)
            XCTAssertTrue(f.access.status.contains(message))
            let battery = await f.access.readIPhone(identifier: UUID(), timeout: 1)
            XCTAssertNil(battery)
            XCTAssertTrue(f.access.status.contains(message))
            XCTAssertTrue(
                f.pool.transports.allSatisfy {
                    $0.scanStarts == 0 && $0.connections.isEmpty && $0.retrievals.isEmpty
                })
        }
    }

    func testAuthorizationBecomingAvailableStartsOnlyOutstandingDemand() async throws {
        let f = fixture(state: .unknown)
        let task = Task { await f.access.scan(timeout: 0.15) }
        await eventually { f.pool.transports.count == 1 }
        let transport = try XCTUnwrap(f.pool.transports.first)
        XCTAssertEqual(transport.scanStarts, 0)
        transport.emit(.state(.poweredOn))
        XCTAssertEqual(transport.scanStarts, 1)
        transport.advertise(UUID())
        let results = await task.value
        XCTAssertEqual(results.count, 1)
        transport.emit(.state(.poweredOn))
        XCTAssertEqual(
            transport.scanStarts, 1, "Late state notifications must not restart an idle backend")
    }

    func testPhoneRetrievalAndDiscoveryTargetOnlyExplicitUUID() async throws {
        let target = UUID()
        let f = fixture()
        let phone = Task { await f.access.readIPhone(identifier: target, timeout: 1) }
        await eventually { f.pool.transports.first?.scanStarts == 1 }
        let transport = try XCTUnwrap(f.pool.transports.first)
        XCTAssertEqual(transport.retrievals, [target])
        transport.advertise(UUID(), name: "iPhone")
        transport.advertise(UUID(), name: "Apple Inc.")
        XCTAssertTrue(transport.connections.isEmpty)
        transport.advertise(target, name: "Not trusted as identity")
        XCTAssertEqual(transport.connections.map(\.identifier), [target])
        XCTAssertEqual(transport.scanStops, 1)
        let request = try XCTUnwrap(transport.connections.first?.request)
        discover(transport, request)
        validValues(transport, request)
        let battery = await phone.value
        XCTAssertEqual(battery, 64)
        XCTAssertEqual(transport.cancellations, [request])
        transport.acknowledge(request)
    }

    func testPhoneLocationAndScanShareRadioAndCancellingPhoneLeavesScanActive() async throws {
        let f = fixture()
        let target = UUID()
        let scan = Task { await f.access.scan(timeout: 0.15) }
        await eventually { f.pool.transports.first?.scanStarts == 1 }
        let transport = try XCTUnwrap(f.pool.transports.first)
        let phone = Task { await f.access.readIPhone(identifier: target, timeout: 1) }
        await eventually { transport.retrievals == [target] }
        XCTAssertEqual(transport.scanStarts, 1)
        phone.cancel()
        let battery = await phone.value
        XCTAssertNil(battery)
        XCTAssertTrue(transport.cancellations.isEmpty, "Locating never acquired a connection")
        XCTAssertEqual(transport.scanStops, 0)
        transport.advertise(target)
        XCTAssertTrue(transport.connections.isEmpty, "Discovery after cancellation cannot connect")
        let observations = await scan.value
        XCTAssertEqual(observations.map(\.identifier), [target])
        XCTAssertEqual(transport.scanStops, 1)
    }

    func testSelectedPhoneAbsentTimesOutWithoutConnectingToNearbyDevices() async throws {
        let f = fixture()
        let target = UUID()
        let task = Task { await f.access.readIPhone(identifier: target, timeout: 0.04) }
        await eventually { f.pool.transports.first?.scanStarts == 1 }
        let transport = try XCTUnwrap(f.pool.transports.first)
        for _ in 0..<10 { transport.advertise(UUID(), name: "iPhone") }
        let battery = await task.value
        XCTAssertNil(battery)
        XCTAssertTrue(f.access.status.contains("timed out"))
        XCTAssertTrue(transport.connections.isEmpty)
        XCTAssertTrue(transport.cancellations.isEmpty)
        XCTAssertEqual(transport.scanStops, 1)
        XCTAssertEqual(transport.shutdowns, 1)
    }

    func testKnownPhoneSkipsScanningAndReadsOnlyRequiredGATTFieldsInAnyOrder() async throws {
        let orders = [
            ["2A19", "2A29", "2A24"], ["2A19", "2A24", "2A29"],
            ["2A29", "2A19", "2A24"], ["2A29", "2A24", "2A19"],
            ["2A24", "2A19", "2A29"], ["2A24", "2A29", "2A19"],
        ]
        for (index, order) in orders.enumerated() {
            let target = UUID()
            let f = fixture(known: [target])
            let (task, transport, request) = try await beginPhone(f, identifier: target)
            XCTAssertEqual(transport.retrievals, [target])
            XCTAssertEqual(transport.scanStarts, 0)
            discover(transport, request, metadataFirst: index.isMultiple(of: 2))
            XCTAssertEqual(transport.serviceRequests.count, 1)
            XCTAssertEqual(Set(transport.serviceRequests[0].uuids), Set(["180F", "180A"]))
            XCTAssertEqual(transport.characteristicRequests.count, 2)
            XCTAssertEqual(
                transport.characteristicRequests.first { $0.service == "180F" }?.uuids, ["2A19"])
            XCTAssertEqual(
                Set(transport.characteristicRequests.first { $0.service == "180A" }?.uuids ?? []),
                Set(["2A29", "2A24"]))
            XCTAssertEqual(
                Set(transport.reads.map { $0.service + ":" + $0.characteristic }),
                Set(["180F:2A19", "180A:2A29", "180A:2A24"]))
            let level: UInt8 = index.isMultiple(of: 2) ? 0 : 100
            let values = [
                "2A19": Data([level]), "2A29": Data("Apple Inc.".utf8),
                "2A24": Data("iPhone15,2".utf8),
            ]
            for field in order { transport.value(request, field, values[field]) }
            let result = await task.value
            XCTAssertEqual(result, Int(level))
            XCTAssertEqual(transport.cancellations, [request])
            transport.acknowledge(request)
        }
    }

    func testBatteryValueBeforeMetadataDiscoveryCannotCompleteEarly() async throws {
        let target = UUID()
        let f = fixture(known: [target])
        let (task, transport, request) = try await beginPhone(f, identifier: target)
        transport.emit(.connected(request: request))
        transport.emit(.services(request: request, uuids: ["180F", "180A"]))
        transport.emit(
            .characteristics(
                request: request, service: "180F", values: [.init(uuid: "2A19", readable: true)]))
        transport.value(request, "2A19", Data([88]))
        XCTAssertTrue(transport.cancellations.isEmpty)
        transport.emit(
            .characteristics(
                request: request, service: "180A",
                values: [.init(uuid: "2A29", readable: true), .init(uuid: "2A24", readable: true)]))
        transport.value(request, "2A24", Data("iPhone".utf8))
        XCTAssertTrue(transport.cancellations.isEmpty)
        transport.value(request, "2A29", Data("Apple Inc.".utf8))
        let result = await task.value
        XCTAssertEqual(result, 88)
        transport.acknowledge(request)
    }

    func testStrictBatteryAndAppleIPhoneMetadataValidation() async throws {
        let invalid: [(String, Data?)] = [
            ("2A19", nil), ("2A19", Data()), ("2A19", Data([101])),
            ("2A19", Data([255])), ("2A19", Data([1, 2])),
            ("2A29", Data("Apple".utf8)), ("2A29", Data("apple inc.".utf8)),
            ("2A29", Data("Apple Inc.\0".utf8)), ("2A29", Data([0xff])),
            ("2A24", Data("iPad16,1".utf8)), ("2A24", Data("My iPhone".utf8)),
            ("2A24", Data("iphone".utf8)), ("2A24", nil),
            ("2A24", Data(("iPhone" + String(repeating: "x", count: 200)).utf8)),
        ]
        for (field, data) in invalid {
            let target = UUID()
            let f = fixture(known: [target])
            let (task, transport, request) = try await beginPhone(f, identifier: target)
            discover(transport, request)
            transport.value(request, field, data)
            validValues(transport, request)  // Even plausible late fields must not rescue failure.
            let result = await task.value
            XCTAssertNil(result, "Must reject invalid \(field): \(String(describing: data))")
            XCTAssertEqual(transport.cancellations, [request])
            XCTAssertTrue(
                f.access.status.contains("unavailable") || f.access.status.contains("not an iPhone")
            )
            transport.acknowledge(request)
        }
    }

    func testMissingFailedAndUnreadableServicesAndCharacteristicsFailClosed() async throws {
        let failures: [([String]?, String?, [BLEBatteryCharacteristic]?)] = [
            (nil, nil, nil), (["180F"], nil, nil), (["180A"], nil, nil),
            (["1234", "180F"], nil, nil), (["180A", "180F"], "180F", nil),
            (["180A", "180F"], "180F", []),
            (["180A", "180F"], "180F", [.init(uuid: "2A19", readable: false)]),
            (["180A", "180F"], "180A", [.init(uuid: "2A29", readable: true)]),
            (
                ["180A", "180F"], "180A",
                [.init(uuid: "2A29", readable: false), .init(uuid: "2A24", readable: true)]
            ),
        ]
        for (services, service, characteristics) in failures {
            let target = UUID()
            let f = fixture(known: [target])
            let (task, transport, request) = try await beginPhone(f, identifier: target)
            transport.emit(.connected(request: request))
            transport.emit(.services(request: request, uuids: services))
            if let service {
                transport.emit(
                    .characteristics(request: request, service: service, values: characteristics))
            }
            let result = await task.value
            XCTAssertNil(result)
            XCTAssertTrue(f.access.status.contains("unavailable"))
            XCTAssertTrue(transport.reads.isEmpty)
            XCTAssertEqual(transport.cancellations, [request])
            transport.acknowledge(request)
        }
    }

    func testWrongServiceUnsolicitedAndDuplicateValuesAreIgnored() async throws {
        let target = UUID()
        let f = fixture(known: [target])
        let (task, transport, request) = try await beginPhone(f, identifier: target)
        transport.value(request, "2A19", Data([99]))  // Not read yet.
        discover(transport, request)
        transport.value(request, "2A19", Data([99]), service: "1234")
        transport.value(UUID(), "2A19", Data([99]))
        transport.value(request, "2A19", Data([23]))
        transport.value(request, "2A19", Data([99]))  // Duplicate callback is not a new read.
        transport.value(request, "2A29", Data("Apple Inc.".utf8))
        XCTAssertTrue(transport.cancellations.isEmpty)
        transport.value(request, "2A24", Data("iPhone".utf8))
        let result = await task.value
        XCTAssertEqual(result, 23)
        transport.acknowledge(request)
    }

    func testOnlyOnePhoneConnectionAndNoRestartUntilDisconnectAcknowledgment() async throws {
        let target = UUID()
        let f = fixture(known: [target])
        let (first, oldTransport, oldRequest) = try await beginPhone(f, identifier: target)
        let competing = await f.access.readIPhone(identifier: UUID(), timeout: 1)
        XCTAssertNil(competing)
        XCTAssertEqual(oldTransport.connections.count, 1)
        XCTAssertTrue(oldTransport.cancellations.isEmpty)
        discover(oldTransport, oldRequest)
        validValues(oldTransport, oldRequest)
        let result = await first.value
        XCTAssertEqual(result, 64)
        let second = Task { await f.access.readIPhone(identifier: target, timeout: 1) }
        await eventually { f.access.status.contains("cleanup") }
        XCTAssertEqual(f.pool.transports.count, 1)
        XCTAssertEqual(oldTransport.cancellations, [oldRequest])
        oldTransport.emit(.connected(request: oldRequest))
        validValues(oldTransport, oldRequest)
        XCTAssertEqual(oldTransport.serviceRequests.count, 1)
        oldTransport.acknowledge(oldRequest)
        XCTAssertEqual(oldTransport.shutdowns, 1)

        await eventually {
            f.pool.transports.count == 2 && f.pool.transports.last?.connections.count == 1
        }
        let newTransport = try XCTUnwrap(f.pool.transports.last)
        let newRequest = try XCTUnwrap(newTransport.connections.first?.request)
        oldTransport.emit(.connected(request: oldRequest))
        oldTransport.emit(.services(request: oldRequest, uuids: ["180A", "180F"]))
        validValues(oldTransport, oldRequest)
        oldTransport.acknowledge(oldRequest)
        newTransport.emit(.disconnected(request: oldRequest))
        XCTAssertTrue(newTransport.serviceRequests.isEmpty)
        XCTAssertTrue(newTransport.cancellations.isEmpty)
        discover(newTransport, newRequest)
        validValues(newTransport, newRequest, battery: 17)
        let secondResult = await second.value
        XCTAssertEqual(secondResult, 17)
        newTransport.acknowledge(newRequest)
    }

    func testPendingConnectTimeoutBoundsTeardownAndIgnoresLateConnectOrValues() async throws {
        let target = UUID()
        let f = fixture(known: [target], disconnectTimeout: 0.03)
        let (task, oldTransport, request) = try await beginPhone(
            f, identifier: target, timeout: 0.03)
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertTrue(f.access.status.contains("timed out"))
        XCTAssertEqual(oldTransport.cancellations, [request])
        oldTransport.emit(.connected(request: request))
        validValues(oldTransport, request)
        XCTAssertTrue(oldTransport.serviceRequests.isEmpty)
        await eventually { oldTransport.shutdowns == 1 }
        let (next, newTransport, newRequest) = try await beginPhone(f, identifier: target)
        oldTransport.emit(.connectionFailed(request: request))
        oldTransport.acknowledge(request)
        discover(newTransport, newRequest)
        validValues(newTransport, newRequest, battery: 31)
        let nextResult = await next.value
        XCTAssertEqual(nextResult, 31)
        newTransport.acknowledge(newRequest)
    }

    func testPhoneCancellationReturnsWithoutWaitingForNativeDisconnect() async throws {
        let target = UUID()
        let f = fixture(known: [target])
        let (task, transport, request) = try await beginPhone(f, identifier: target)
        discover(transport, request)
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(transport.cancellations, [request])
        XCTAssertEqual(
            transport.shutdowns, 0,
            "Cancellation returns while native cancellation is being acknowledged")
        validValues(transport, request)
        transport.acknowledge(request)
        XCTAssertEqual(transport.shutdowns, 1)
    }

    func testNativeConnectionFailureDoesNotCancelAnAlreadyDisconnectedConnection() async throws {
        for failsToConnect in [true, false] {
            let target = UUID()
            let f = fixture(known: [target])
            let (task, transport, request) = try await beginPhone(f, identifier: target)
            if failsToConnect {
                transport.emit(.connectionFailed(request: request))
            } else {
                transport.emit(.connected(request: request))
                transport.acknowledge(request)
            }
            let result = await task.value
            XCTAssertNil(result)
            XCTAssertTrue(transport.cancellations.isEmpty)
            XCTAssertEqual(transport.shutdowns, 1)
        }
    }

    func testStopCancelsAllConsumersAndOnlyOwnConnectionAndIsReusable() async throws {
        let target = UUID()
        let f = fixture(known: [target])
        let (phone, transport, request) = try await beginPhone(f, identifier: target)
        let scan = Task { await f.access.scan(timeout: 1) }
        await eventually { transport.scanStarts == 1 }
        var secondStarted = false
        let secondScan = Task {
            secondStarted = true
            return await f.access.scan(timeout: 1)
        }
        await eventually { secondStarted }
        transport.advertise(UUID(), data: Data([80]))
        f.access.stop()
        f.access.stop()
        let phoneResult = await phone.value
        let scanResult = await scan.value
        let secondResult = await secondScan.value
        XCTAssertNil(phoneResult)
        XCTAssertTrue(scanResult.isEmpty)
        XCTAssertTrue(secondResult.isEmpty)
        XCTAssertEqual(transport.cancellations, [request])
        XCTAssertEqual(transport.scanStarts, 1)
        XCTAssertEqual(transport.scanStops, 1)
        transport.acknowledge(request)
        let next = Task { await f.access.scan(timeout: 0.03) }
        await eventually { f.pool.transports.count == 2 }
        let newTransport = try XCTUnwrap(f.pool.transports.last)
        let identifier = UUID()
        newTransport.advertise(identifier)
        let nextResult = await next.value
        XCTAssertEqual(nextResult.map(\.identifier), [identifier])
    }

    func testPhoneTeardownRecyclesNativeGenerationWithoutEndingOtherScanConsumers() async throws {
        let target = UUID()
        let f = fixture(known: [target])
        let scan = Task { await f.access.scan(timeout: 0.20) }
        await eventually { f.pool.transports.first?.scanStarts == 1 }
        let (phone, oldTransport, request) = try await beginPhone(f, identifier: target)
        let firstObservation = UUID()
        let secondObservation = UUID()
        oldTransport.advertise(firstObservation)
        let oldScan = try XCTUnwrap(oldTransport.scanID)
        discover(oldTransport, request)
        validValues(oldTransport, request)
        let battery = await phone.value
        XCTAssertEqual(battery, 64)
        XCTAssertEqual(oldTransport.scanStops, 0)
        oldTransport.acknowledge(request)
        XCTAssertEqual(f.pool.transports.count, 2)
        let newTransport = try XCTUnwrap(f.pool.transports.last)
        XCTAssertEqual(newTransport.scanStarts, 1)
        oldTransport.emit(
            .advertisement(
                scan: oldScan,
                observation: BLEAdvertisement(
                    identifier: UUID(), name: "Late", manufacturerData: Data([99])),
                observedAt: DispatchTime.now().uptimeNanoseconds))
        newTransport.advertise(secondObservation)
        let results = await scan.value
        XCTAssertEqual(Set(results.map(\.identifier)), Set([firstObservation, secondObservation]))
        XCTAssertEqual(oldTransport.scanStops, 1)
        XCTAssertEqual(newTransport.scanStops, 1)
    }

    func testResetDuringActivePhoneReadInvalidatesItsNativeGenerationAndLateValues() async throws {
        for state in [BLEBatteryCentralState.unknown, .resetting] {
            let target = UUID()
            let f = fixture(known: [target])
            let (phone, oldTransport, request) = try await beginPhone(f, identifier: target)
            discover(oldTransport, request)
            oldTransport.value(request, "2A19", Data([80]))
            oldTransport.emit(.state(state))
            let result = await phone.value
            XCTAssertNil(result)
            XCTAssertEqual(oldTransport.shutdowns, 1)
            validValues(oldTransport, request)
            oldTransport.emit(.state(.poweredOn))
            let (fresh, newTransport, freshRequest) = try await beginPhone(f, identifier: target)
            discover(newTransport, freshRequest)
            validValues(newTransport, freshRequest, battery: 70)
            let freshResult = await fresh.value
            XCTAssertEqual(freshResult, 70)
            newTransport.acknowledge(freshRequest)
        }
    }

    func testResetAndRecoveryRearmsScanningWithoutAcceptingOldScanCallbacks() async throws {
        let f = fixture()
        let scan = Task { await f.access.scan(timeout: 0.15) }
        await eventually { f.pool.transports.first?.scanStarts == 1 }
        let transport = try XCTUnwrap(f.pool.transports.first)
        let oldScanID = try XCTUnwrap(transport.scanID)
        transport.emit(.state(.resetting))
        transport.emit(.state(.poweredOn))
        XCTAssertEqual(transport.scanStarts, 2)
        XCTAssertEqual(transport.scanStops, 1)
        transport.emit(
            .advertisement(
                scan: oldScanID,
                observation: BLEAdvertisement(
                    identifier: UUID(), name: "Stale", manufacturerData: Data()),
                observedAt: DispatchTime.now().uptimeNanoseconds
            ))
        let freshID = UUID()
        transport.advertise(freshID)
        let values = await scan.value
        XCTAssertEqual(values.map(\.identifier), [freshID])
    }

    func testEquivalentBluetoothBaseUUIDRepresentationsAreAccepted() async throws {
        func full(_ value: String) -> String { "0000\(value)-0000-1000-8000-00805f9b34fb" }
        for value in ["180A", "180F", "2A19", "2A24", "2A29"] {
            XCTAssertEqual(BLEBatteryUUID.canonical(value.lowercased()), value)
            XCTAssertEqual(BLEBatteryUUID.canonical("0000" + value), value)
            XCTAssertEqual(BLEBatteryUUID.canonical(full(value)), value)
        }
        XCTAssertNotEqual(BLEBatteryUUID.canonical("0000180F-0000-1000-8000-00805F9B34FC"), "180F")
        let target = UUID()
        let f = fixture(known: [target])
        let (task, transport, request) = try await beginPhone(f, identifier: target)
        transport.emit(.connected(request: request))
        transport.emit(.services(request: request, uuids: [full("180a"), "0000180f"]))
        transport.emit(
            .characteristics(
                request: request, service: full("180f"),
                values: [
                    BLEBatteryCharacteristic(uuid: full("2a19"), readable: true)
                ]))
        transport.emit(
            .characteristics(
                request: request, service: "0000180a",
                values: [
                    BLEBatteryCharacteristic(uuid: "00002a24", readable: true),
                    BLEBatteryCharacteristic(uuid: full("2a29"), readable: true),
                ]))
        transport.value(request, full("2a19"), Data([71]), service: full("180f"))
        transport.value(request, "00002a24", Data("iPhone16,1".utf8), service: full("180a"))
        transport.value(request, full("2a29"), Data("Apple Inc.".utf8), service: "0000180a")
        let result = await task.value
        XCTAssertEqual(result, 71)
        transport.acknowledge(request)
    }

    func testReplacementWaitingForDisconnectCanTimeOutOrCancelWithoutConnecting() async throws {
        for cancel in [false, true] {
            let target = UUID()
            let f = fixture(known: [target])
            let (first, transport, request) = try await beginPhone(f, identifier: target)
            first.cancel()
            _ = await first.value
            let replacement = Task { await f.access.readIPhone(identifier: target, timeout: 0.05) }
            await eventually { f.access.status.contains("cleanup") }
            if cancel { replacement.cancel() }
            let result = await replacement.value
            XCTAssertNil(result)
            transport.acknowledge(request)
            XCTAssertEqual(f.pool.transports.count, 1)
            XCTAssertEqual(transport.connections.count, 1)
        }
    }

    func testPowerOrAuthorizationLossFailsAllCurrentRequestsWithoutReturningPartialData()
        async throws
    {
        for state in [BLEBatteryCentralState.poweredOff, .denied, .unsupported] {
            let target = UUID()
            let f = fixture(known: [target])
            let (phone, transport, request) = try await beginPhone(f, identifier: target)
            let scan = Task { await f.access.scan(timeout: 1) }
            await eventually { transport.scanStarts == 1 }
            transport.advertise(UUID(), data: Data([90]))
            transport.emit(.state(state))
            let phoneResult = await phone.value
            let scanResult = await scan.value
            XCTAssertNil(phoneResult)
            XCTAssertTrue(scanResult.isEmpty)
            XCTAssertEqual(transport.cancellations, [request])
            XCTAssertEqual(transport.scanStops, 1)
            transport.acknowledge(request)
            transport.emit(.state(.poweredOn))
            XCTAssertEqual(transport.connections.count, 1)
            XCTAssertEqual(transport.scanStarts, 1)
        }
    }
}
