import Foundation
import XCTest

@testable import ClockyCore

final class BLEAdvertisementParserTests: XCTestCase {
    func testStandardCleartextFrameUsesApproximateTenPercentLevels() {
        let data = proximity(status: 0x20, levels: 0xA7, caseStatus: 0x36)
        XCTAssertTrue(BLEAdvertisementParser.isAirPods(data))
        XCTAssertEqual(
            BLEAdvertisementParser.airPods(from: data),
            AirPodsBattery(left: 70, right: 100, caseLevel: 60, isApproximate: true)
        )
    }

    func testStatusBitFiveControlsOrientationAndBitSixDoesNot() {
        // Source: podpower 58202c9, paired-mode byte 5 (company-inclusive byte 7).
        // Set bit 5 = low nibble left; clear bit 5 = high nibble left.
        for status in UInt8.min...UInt8.max {
            let reading = BLEAdvertisementParser.airPods(
                from: proximity(status: status, levels: 0x37))
            XCTAssertEqual(reading?.left, status & 0x20 != 0 ? 70 : 30, "status \(status)")
            XCTAssertEqual(reading?.right, status & 0x20 != 0 ? 30 : 70, "status \(status)")
        }
    }

    func testEveryNibbleIsIndependentAndInvalidValuesAreNeverClamped() {
        for left in UInt8(0)...15 {
            for right in UInt8(0)...15 {
                for caseLevel in UInt8(0)...15 {
                    let data = proximity(
                        status: 0x20, levels: (right << 4) | left, caseStatus: 0xF0 | caseLevel)
                    let reading = BLEAdvertisementParser.airPods(from: data)
                    let expectedLeft = left <= 10 ? Int(left) * 10 : nil
                    let expectedRight = right <= 10 ? Int(right) * 10 : nil
                    let expectedCase = caseLevel <= 10 ? Int(caseLevel) * 10 : nil
                    XCTAssertTrue(BLEAdvertisementParser.isAirPods(data))
                    if expectedLeft == nil && expectedRight == nil && expectedCase == nil {
                        XCTAssertNil(reading)
                    } else {
                        XCTAssertEqual(
                            reading,
                            AirPodsBattery(
                                left: expectedLeft, right: expectedRight, caseLevel: expectedCase,
                                isApproximate: true
                            ))
                    }
                }
            }
        }
    }

    func testUnavailableAndInvalidLevelsDoNotPreventIdentityDiscovery() {
        for nibble in UInt8(11)...15 {
            let data = proximity(levels: (nibble << 4) | nibble, caseStatus: nibble)
            XCTAssertTrue(BLEAdvertisementParser.isAirPods(data))
            XCTAssertNil(BLEAdvertisementParser.airPods(from: data))
        }
        XCTAssertEqual(
            BLEAdvertisementParser.airPods(from: proximity(levels: 0xFF, caseStatus: 0x00)),
            AirPodsBattery(caseLevel: 0, isApproximate: true)
        )
    }

    func testKnownAirPodsProductIDsAreRecognizedWithoutNames() {
        for productID: UInt16 in [
            0x2002, 0x200F, 0x2013, 0x2019, 0x201B, 0x200E, 0x2014, 0x2024, 0x2027, 0x200A, 0x201F,
        ] {
            let data = proximity(productID: productID)
            XCTAssertTrue(BLEAdvertisementParser.isAirPods(data), "PID \(productID)")
            XCTAssertNotNil(BLEAdvertisementParser.airPods(from: data), "PID \(productID)")
        }
    }

    func testBeatsUnknownAndByteSwappedProductIDsAreRejected() {
        for productID: UInt16 in [
            0x0000, 0xFFFF, 0x0220, 0x0A20, 0x2003, 0x2005, 0x2006, 0x2009, 0x200B, 0x200C, 0x2010,
            0x2011, 0x2012, 0x2017,
        ] {
            assertNotAirPods(proximity(productID: productID))
        }
    }

    func testBothMaxModelsUseOnlyLowNibbleRegardlessOfStatusOrCase() {
        for productID: UInt16 in [0x200A, 0x201F] {
            for status: UInt8 in [0x00, 0x20, 0x40, 0x60, 0xFF] {
                for highNibble in UInt8(0)...15 {
                    let data = proximity(
                        productID: productID, status: status, levels: (highNibble << 4) | 7,
                        caseStatus: 0xAA)
                    XCTAssertEqual(
                        BLEAdvertisementParser.airPods(from: data),
                        AirPodsBattery(main: 70, isApproximate: true))
                }
            }
            for unavailable in UInt8(11)...15 {
                let data = proximity(
                    productID: productID, levels: 0xA0 | unavailable, caseStatus: 0x0A)
                XCTAssertTrue(BLEAdvertisementParser.isAirPods(data))
                XCTAssertNil(BLEAdvertisementParser.airPods(from: data))
            }
        }
    }

    func testCompanyTypeLengthAndVersionMustMatchIndependentlyOfLevels() {
        for (index, expected): (Int, UInt8) in [
            (0, 0x4C), (1, 0x00), (2, 0x07), (3, 0x19), (4, 0x01),
        ] {
            for invalid in UInt8.min...UInt8.max where invalid != expected {
                var bytes = [UInt8](proximity())
                bytes[index] = invalid
                assertNotAirPods(Data(bytes))
            }
        }
        var closedCase = [UInt8](proximity())
        closedCase[2] = 0x12
        assertNotAirPods(Data(closedCase))
    }

    func testEveryTruncationAndNonstandardFrameLengthIsRejected() {
        let complete = proximity()
        for length in 0..<complete.count {
            assertNotAirPods(Data(complete.prefix(length)))
        }
        for extraCount in 1...256 {
            assertNotAirPods(complete + Data(repeating: 0, count: extraCount))
        }
        // Changing the declared length never makes a shortened frame acceptable.
        for count in 4..<29 {
            var shortened = [UInt8](complete.prefix(count))
            shortened[3] = UInt8(count - 4)
            assertNotAirPods(Data(shortened))
        }
    }

    func testOpaqueBytesAndChargingBitsNeverBecomeBatteryReadings() {
        let expected = AirPodsBattery(left: 70, right: 30, caseLevel: 60, isApproximate: true)
        for index in 10..<29 {
            for sentinel: UInt8 in [0, 1, 50, 99, 100, 0xFF] {
                var bytes = [UInt8](proximity(status: 0x20, levels: 0x37, caseStatus: 6))
                bytes[index] = sentinel
                XCTAssertEqual(BLEAdvertisementParser.airPods(from: Data(bytes)), expected)
            }
        }
        for charging in UInt8(0)...15 {
            XCTAssertEqual(
                BLEAdvertisementParser.airPods(
                    from: proximity(status: 0x20, levels: 0x37, caseStatus: (charging << 4) | 6)),
                expected
            )
        }
        var noBattery = [UInt8](proximity(levels: 0xFF, caseStatus: 0xFF))
        for index in 10..<29 { noBattery[index] = 100 }
        XCTAssertNil(BLEAdvertisementParser.airPods(from: Data(noBattery)))
    }

    func testDataSlicesWithNonzeroStartIndicesAreSupported() {
        let packet = proximity()
        let padded = Data([0xDE, 0xAD, 0xBE, 0xEF]) + packet
        let slice = padded.dropFirst(4)
        XCTAssertEqual(slice.startIndex, 4)
        XCTAssertEqual(
            BLEAdvertisementParser.airPods(from: slice),
            BLEAdvertisementParser.airPods(from: packet))
        XCTAssertTrue(BLEAdvertisementParser.isAirPods(slice))
        let nearby = Data([0, 0]) + phoneMessage(type: 0x10, payload: [3, 0x1C, 1, 2, 3])
        XCTAssertTrue(BLEAdvertisementParser.isPhoneCandidate(nearby.dropFirst(2)))
    }

    func testNearbyAndHandoffAreOnlyPhoneDiscoveryHints() {
        // Public Continuity docs identify 0x0C as Handoff, not Hotspot (0x0E).
        for payload: [UInt8] in [[3, 4], [3, 0x1C, 1, 2, 3], [3, 0x1E, 1, 2, 3, 4, 0x80]] {
            XCTAssertTrue(
                BLEAdvertisementParser.isPhoneCandidate(phoneMessage(type: 0x10, payload: payload)))
        }
        XCTAssertTrue(
            BLEAdvertisementParser.isPhoneCandidate(
                phoneMessage(type: 0x0C, payload: Array(repeating: 0, count: 14))))
        XCTAssertFalse(BLEAdvertisementParser.isPhoneCandidate(proximity()))
        XCTAssertFalse(
            BLEAdvertisementParser.isPhoneCandidate(
                phoneMessage(type: 0x12, payload: Array(repeating: 0, count: 25))))
        XCTAssertFalse(
            BLEAdvertisementParser.isPhoneCandidate(
                phoneMessage(type: 0x0E, payload: [1, 0, 50, 1, 4, 0])))
    }

    func testPhoneDiscoveryValidatesAllTLVsBeforeAndAfterCandidate() {
        let candidate = phoneMessage(type: 0x10, payload: [3, 4])
        let unknown: [UInt8] = [0x55, 3, 0x10, 0x0C, 0xFF]
        let combined = Data([0x4C, 0]) + Data(unknown) + candidate.dropFirst(2) + Data([0x66, 0])
        XCTAssertTrue(BLEAdvertisementParser.isPhoneCandidate(combined))
        XCTAssertFalse(BLEAdvertisementParser.isPhoneCandidate(candidate + Data([0x55])))
        XCTAssertFalse(BLEAdvertisementParser.isPhoneCandidate(candidate + Data([0x55, 2, 0])))
        XCTAssertFalse(BLEAdvertisementParser.isPhoneCandidate(candidate + Data([0x0C, 1, 0])))
        XCTAssertFalse(
            BLEAdvertisementParser.isPhoneCandidate(
                phoneMessage(type: 0x55, payload: [0x10, 2, 3, 4])))
    }

    func testPhoneCompanyKnownMessageSizesAndTruncationAreValidated() {
        for type: UInt8 in [0x10, 0x0C] {
            let validSize = type == 0x10 ? 5 : 14
            // Nonzero sentinels cannot turn a shortened payload into valid extra TLVs.
            let complete = phoneMessage(
                type: type, payload: Array(repeating: 0xFF, count: validSize))
            for count in 0..<complete.count {
                XCTAssertFalse(
                    BLEAdvertisementParser.isPhoneCandidate(Data(complete.prefix(count))))
            }
            for length in UInt8.min...UInt8.max {
                var bytes = [UInt8](complete)
                bytes[3] = length
                XCTAssertEqual(
                    BLEAdvertisementParser.isPhoneCandidate(Data(bytes)), Int(length) == validSize)
            }
            for index in 0...1 {
                var bytes = [UInt8](complete)
                bytes[index] ^= 0xFF
                XCTAssertFalse(BLEAdvertisementParser.isPhoneCandidate(Data(bytes)))
            }
            for size in 0..<2 {
                XCTAssertFalse(
                    BLEAdvertisementParser.isPhoneCandidate(
                        phoneMessage(type: type, payload: Array(repeating: 0, count: size))))
            }
        }
        for size in [2, 5, 13, 15, 25] {
            XCTAssertFalse(
                BLEAdvertisementParser.isPhoneCandidate(
                    phoneMessage(type: 0x0C, payload: Array(repeating: 0, count: size))))
        }
    }

    func testDeterministicLengthFuzzCannotInventAirPodsOrOutOfRangeLevels() {
        var state: UInt64 = 0x1234_5678
        for count in 0...512 {
            let bytes: [UInt8] = (0..<count).map { _ in
                state = state &* 6_364_136_223_846_793_005 &+ 1
                return UInt8(truncatingIfNeeded: state >> 32)
            }
            let data = Data(bytes)
            assertNotAirPods(data)
            // Deliberately prepend the Apple company ID to exercise TLV walking.
            _ = BLEAdvertisementParser.isPhoneCandidate(Data([0x4C, 0x00]) + data)
        }
    }

    private func proximity(
        productID: UInt16 = 0x200E, status: UInt8 = 0x20, levels: UInt8 = 0xA7,
        caseStatus: UInt8 = 0x36
    ) -> Data {
        // Manufacturer company (2), TLV header (2), cleartext (9), opaque tail (16).
        Data(
            [
                0x4C, 0x00, 0x07, 0x19, 0x01,
                UInt8(truncatingIfNeeded: productID), UInt8(productID >> 8),
                status, levels, caseStatus, 0x08, 0x00, 0x00,
            ] + Array(repeating: UInt8(0xED), count: 16))
    }

    private func phoneMessage(type: UInt8, payload: [UInt8]) -> Data {
        Data([0x4C, 0x00, type, UInt8(payload.count)] + payload)
    }

    private func assertNotAirPods(_ data: Data, file: StaticString = #filePath, line: UInt = #line)
    {
        XCTAssertFalse(BLEAdvertisementParser.isAirPods(data), file: file, line: line)
        XCTAssertNil(BLEAdvertisementParser.airPods(from: data), file: file, line: line)
    }
}

final class BLEBatteryPresentationTests: XCTestCase {
    func testApproximateAirPodsTextAndAccessibilityDoNotApproximateUnknownValues() {
        let snapshot = BatterySnapshot(
            airPods: AirPodsBattery(left: 70, caseLevel: 0, isApproximate: true))
        XCTAssertEqual(snapshot.text, "Mac N/A · iPhone N/A · AirPods L ~70% R N/A C ~0%")
        XCTAssertEqual(
            snapshot.accessibilityText,
            "Mac unavailable, iPhone unavailable, AirPods left approximately 70 percent, right unavailable, case approximately 0 percent"
        )
        XCTAssertEqual(snapshot.airPods?.headsetPercentage, 70)
    }

    func testApproximateMaxAndMissingReadings() {
        let snapshot = BatterySnapshot(airPods: AirPodsBattery(main: 100, isApproximate: true))
        XCTAssertEqual(snapshot.text, "Mac N/A · iPhone N/A · AirPods ~100%")
        XCTAssertEqual(
            snapshot.accessibilityText,
            "Mac unavailable, iPhone unavailable, AirPods approximately 100 percent")
        let unknown = BatterySnapshot(
            airPods: AirPodsBattery(left: -1, main: 101, isApproximate: true))
        XCTAssertEqual(unknown.text, BatterySnapshot().text)
        XCTAssertEqual(unknown.accessibilityText, BatterySnapshot().accessibilityText)
    }

    func testIPhoneBLESourceIsExplicitWithoutImplyingApproximation() {
        let snapshot = BatterySnapshot(
            mac: 80, iPhone: 70, airPods: AirPodsBattery(main: 50), iPhoneUsesBLE: true)
        XCTAssertTrue(snapshot.iPhoneUsesBLE)
        XCTAssertEqual(snapshot.text, "Mac 80% · iPhone 70% (BLE) · AirPods 50%")
        XCTAssertEqual(
            snapshot.accessibilityText,
            "Mac 80 percent, iPhone 70 percent via Bluetooth, AirPods 50 percent")
        XCTAssertNotEqual(
            snapshot, BatterySnapshot(mac: 80, iPhone: 70, airPods: AirPodsBattery(main: 50)))
    }

    func testIPhoneSourceIsClearedForMissingAndInvalidReadings() {
        for level: Int? in [nil, -1, 101, Int.min, Int.max] {
            let snapshot = BatterySnapshot(iPhone: level, iPhoneUsesBLE: true)
            XCTAssertFalse(snapshot.iPhoneUsesBLE)
            XCTAssertEqual(snapshot, BatterySnapshot())
        }
        for level in [0, 100] {
            XCTAssertTrue(BatterySnapshot(iPhone: level, iPhoneUsesBLE: true).iPhoneUsesBLE)
        }
    }

    func testExistingSourcesRemainExactAndUnmarkedByDefault() {
        let battery = AirPodsBattery(left: 70, right: 80, caseLevel: 90)
        let snapshot = BatterySnapshot(mac: 50, iPhone: 60, airPods: battery)
        XCTAssertFalse(battery.isApproximate)
        XCTAssertFalse(snapshot.iPhoneUsesBLE)
        XCTAssertEqual(snapshot.text, "Mac 50% · iPhone 60% · AirPods L 70% R 80% C 90%")
        XCTAssertEqual(
            snapshot.accessibilityText,
            "Mac 50 percent, iPhone 60 percent, AirPods left 70 percent, right 80 percent, case 90 percent"
        )
        XCTAssertNotEqual(
            battery, AirPodsBattery(left: 70, right: 80, caseLevel: 90, isApproximate: true))
    }
}
