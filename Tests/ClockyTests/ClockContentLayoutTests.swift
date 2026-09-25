import AppKit
import ClockyCore
import XCTest

@testable import Clocky

final class ClockContentLayoutTests: XCTestCase {
    @MainActor
    func testTwoColumnsHaveFixedDeviceSlotsAndSeparateCaseCharge() async throws {
        let snapshot = BatterySnapshot(
            mac: 59, iPhone: 42, airPods: AirPodsBattery(left: 74, right: 56, caseLevel: 63))
        let layout = ClockContentLayout(
            text: "1:00", battery: snapshot, preferences: ClockPreferences())
        let left = try XCTUnwrap(layout.leftColumn)
        let right = try XCTUnwrap(layout.rightColumn)
        XCTAssertEqual(left.id, .left)
        XCTAssertEqual(left.top?.id, .mac)
        XCTAssertEqual(left.bottom?.id, .iPhone)
        XCTAssertEqual(right.id, .right)
        XCTAssertEqual(right.top?.id, .airPods)
        XCTAssertEqual(right.bottom?.id, .airPodsCase)
        XCTAssertEqual(layout.items.map(\.id.side), [.left, .left, .right, .right])
        XCTAssertEqual(layout.items.map(\.id.row), [.top, .bottom, .top, .bottom])
        XCTAssertEqual(
            layout.items.map(\.systemImage),
            ["laptopcomputer", "iphone", "airpods", "airpods.chargingcase"])
        XCTAssertEqual(layout.items.map(\.text), ["59%", "42%", "56%", "63%"])
        XCTAssertEqual(
            layout.accessibilityValue,
            "1:00. Mac 59 percent, iPhone 42 percent, AirPods 56 percent, AirPods case 63 percent")
        // The full, unabridged readings remain available to Settings.
        XCTAssertTrue(snapshot.text.contains("L 74% R 56% C 63%"))
        XCTAssertTrue(
            snapshot.accessibilityText.contains(
                "left 74 percent, right 56 percent, case 63 percent"))
    }

    @MainActor
    func testMissingZeroMaximumAndInvalidReadingsKeepTheirIcons() async {
        let samples: [(BatterySnapshot, [String])] = [
            (BatterySnapshot(), ["-", "-", "-", "-"]),
            (
                BatterySnapshot(mac: 0, iPhone: 100, airPods: AirPodsBattery(caseLevel: 80)),
                ["0%", "100%", "-", "80%"]
            ),
            (
                BatterySnapshot(
                    mac: 100, iPhone: 0,
                    airPods: AirPodsBattery(left: 100, right: 0, caseLevel: 100)),
                ["100%", "0%", "0%", "100%"]
            ),
            (
                BatterySnapshot(
                    mac: -1, iPhone: 101,
                    airPods: AirPodsBattery(left: -1, right: 101, caseLevel: -1)),
                ["-", "-", "-", "-"]
            ),
            (
                BatterySnapshot(airPods: AirPodsBattery(left: 20, caseLevel: 0)),
                ["-", "-", "20%", "0%"]
            ),
            (
                BatterySnapshot(airPods: AirPodsBattery(right: 30, caseLevel: 100)),
                ["-", "-", "30%", "100%"]
            ),
            (
                BatterySnapshot(
                    airPods: AirPodsBattery(left: 74, right: 56, caseLevel: 5, main: 1)),
                ["-", "-", "56%", "5%"]
            ),
        ]
        for (snapshot, expected) in samples {
            let layout = ClockContentLayout(
                text: "1:00", battery: snapshot, preferences: ClockPreferences())
            XCTAssertEqual(layout.items.map(\.text), expected)
            XCTAssertEqual(layout.items.count, 4)
            XCTAssertEqual(layout.rightColumn?.top?.systemImage, "airpods")
            XCTAssertEqual(layout.rightColumn?.bottom?.systemImage, "airpods.chargingcase")
        }
        let missing = ClockContentLayout(
            text: "1:00", battery: BatterySnapshot(), preferences: ClockPreferences())
        XCTAssertEqual(
            missing.accessibilityValue,
            "1:00. Mac unavailable, iPhone unavailable, AirPods unavailable, AirPods case unavailable"
        )
    }

    @MainActor
    func testAirPodsMaxUsesHeadsetSymbolAndMainChargeWithoutBorrowingCase() async {
        for percentage in [0, 80, 100] {
            let layout = ClockContentLayout(
                text: "1:00", battery: BatterySnapshot(airPods: AirPodsBattery(main: percentage)),
                preferences: ClockPreferences()
            )
            XCTAssertEqual(layout.rightColumn?.top?.systemImage, "airpodsmax")
            XCTAssertEqual(layout.rightColumn?.top?.text, "\(percentage)%")
            XCTAssertEqual(layout.rightColumn?.bottom?.systemImage, "airpods.chargingcase")
            XCTAssertEqual(layout.rightColumn?.bottom?.text, "-")
        }
        let withCase = ClockContentLayout(
            text: "1:00",
            battery: BatterySnapshot(airPods: AirPodsBattery(caseLevel: 20, main: 80)),
            preferences: ClockPreferences()
        )
        XCTAssertEqual(withCase.rightColumn?.top?.systemImage, "airpodsmax")
        XCTAssertEqual(withCase.rightColumn?.top?.text, "80%")
        XCTAssertEqual(withCase.rightColumn?.bottom?.text, "20%")
    }

    @MainActor
    func testSymbolsExistAndMeasurementsPreventIconAndTextCollisions() async {
        let snapshot = BatterySnapshot(
            mac: 100, iPhone: 0, airPods: AirPodsBattery(caseLevel: 100, main: 80))
        for name in [nil, "Helvetica-Bold", "Clocky-Missing-Test-Font"] as [String?] {
            for fontSize in [14.0, 28, 96] {
                var preferences = ClockPreferences()
                preferences.fontName = name
                preferences.fontSize = fontSize
                let layout = ClockContentLayout(
                    text: "12:59:59 PM", battery: snapshot, preferences: preferences)
                XCTAssertEqual(layout.batteryFont, ClockFont.battery(preferences))
                for item in layout.items {
                    XCTAssertNotNil(
                        NSImage(systemSymbolName: item.systemImage, accessibilityDescription: nil))
                    let measured = (item.text as NSString).size(withAttributes: [
                        .font: layout.batteryFont
                    ])
                    XCTAssertEqual(item.textSize.width, ceil(measured.width))
                    XCTAssertEqual(item.textSize.height, ceil(measured.height))
                    XCTAssertGreaterThanOrEqual(layout.rowHeight, measured.height)
                    XCTAssertEqual(
                        item.width,
                        layout.iconSize + ClockContentLayout.iconSpacing + ceil(measured.width))
                    XCTAssertGreaterThan(item.width - item.textSize.width, layout.iconSize)
                }
                for column in layout.columns {
                    XCTAssertEqual(column.size.width, column.items.map(\.width).max())
                    XCTAssertEqual(
                        column.size.height, 2 * layout.rowHeight + ClockContentLayout.rowSpacing)
                    XCTAssertGreaterThan(column.size.height, 2 * layout.iconSize)
                    for item in column.items {
                        XCTAssertGreaterThanOrEqual(column.size.width, item.width)
                    }
                }
                XCTAssertEqual(
                    layout.size.width,
                    layout.clockSize.width
                        + layout.columns.reduce(0) { $0 + $1.size.width }
                        + 2 * ClockContentLayout.columnSpacing)
                XCTAssertGreaterThanOrEqual(layout.rowHeight, layout.iconSize)
                XCTAssertEqual(
                    layout.size.height,
                    max(
                        layout.clockSize.height,
                        2 * layout.rowHeight + ClockContentLayout.rowSpacing))
            }
        }
        XCTAssertNotNil(NSImage(systemSymbolName: "airpods", accessibilityDescription: nil))
    }

    @MainActor
    func testAllSixteenToggleCombinationsPreserveSlotsAndCollapseOnlyEmptyColumns() async {
        let snapshot = BatterySnapshot(
            mac: 100, iPhone: 0, airPods: AirPodsBattery(left: 70, right: 56, caseLevel: 100))
        let full = ClockContentLayout(
            text: "1:00", battery: snapshot, preferences: ClockPreferences())
        for mask in 0..<16 {
            var preferences = ClockPreferences()
            preferences.showsMacBattery = mask & 1 != 0
            preferences.showsIPhoneBattery = mask & 2 != 0
            preferences.showsAirPodsBattery = mask & 4 != 0
            preferences.showsAirPodsCaseBattery = mask & 8 != 0
            let enabled = [
                preferences.showsMacBattery, preferences.showsIPhoneBattery,
                preferences.showsAirPodsBattery, preferences.showsAirPodsCaseBattery,
            ]
            let expectedItems = zip(full.items, enabled).compactMap { $1 ? $0 : nil }
            let layout = ClockContentLayout(
                text: "1:00", battery: snapshot, preferences: preferences)
            XCTAssertEqual(layout.items.map(\.id), expectedItems.map(\.id), "mask \(mask)")
            XCTAssertEqual(layout.leftColumn != nil, enabled[0] || enabled[1])
            XCTAssertEqual(layout.rightColumn != nil, enabled[2] || enabled[3])
            XCTAssertEqual(layout.leftColumn?.top?.id, enabled[0] ? .mac : nil)
            XCTAssertEqual(layout.leftColumn?.bottom?.id, enabled[1] ? .iPhone : nil)
            XCTAssertEqual(layout.rightColumn?.top?.id, enabled[2] ? .airPods : nil)
            XCTAssertEqual(layout.rightColumn?.bottom?.id, enabled[3] ? .airPodsCase : nil)
            XCTAssertEqual(layout.rowHeight, full.rowHeight)
            for column in layout.columns {
                XCTAssertEqual(column.size.height, full.columns[0].size.height)
                XCTAssertEqual(column.size.width, column.items.map(\.width).max())
            }
            XCTAssertEqual(
                layout.size.width,
                layout.clockSize.width
                    + layout.columns.reduce(0) { $0 + $1.size.width }
                    + CGFloat(layout.columns.count) * ClockContentLayout.columnSpacing)
            XCTAssertEqual(
                layout.size.height, mask == 0 ? layout.clockSize.height : full.size.height)
            XCTAssertEqual(
                layout.panelSize,
                ClockPanel.preferredSize(text: "1:00", preferences: preferences, battery: snapshot))
            XCTAssertEqual(
                layout.accessibilityLabel,
                mask == 0 ? "Current time" : "Current time and battery levels")
            XCTAssertEqual(
                layout.accessibilityValue,
                mask == 0
                    ? "1:00"
                    : "1:00. \(expectedItems.map(\.accessibilityText).joined(separator: ", "))")
            if mask == 0 {
                XCTAssertEqual(layout.size, layout.clockSize)
                XCTAssertEqual(
                    layout.panelSize,
                    CGSize(
                        width: layout.clockSize.width + 30,
                        height: layout.clockSize.height + 22))
            }
        }
    }

    @MainActor
    func testApproximateAirPodsMarksLowerBudAndCaseButNotMacOrIPhone() async {
        let snapshot = BatterySnapshot(
            mac: 59, iPhone: 42,
            airPods: AirPodsBattery(left: 70, right: 50, caseLevel: 60, isApproximate: true),
            iPhoneUsesBLE: true
        )
        let layout = ClockContentLayout(
            text: "1:00", battery: snapshot, preferences: ClockPreferences())
        XCTAssertEqual(layout.items.map(\.text), ["59%", "42%", "~50%", "~60%"])
        XCTAssertEqual(layout.items.map(\.isApproximate), [false, false, true, true])
        XCTAssertEqual(layout.items.map(\.usesBluetooth), [false, true, false, false])
        XCTAssertEqual(
            layout.accessibilityValue,
            "1:00. Mac 59 percent, iPhone 42 percent via Bluetooth, AirPods approximately 50 percent, AirPods case approximately 60 percent"
        )
    }

    @MainActor
    func testApproximateAirPodsPreservesMissingZeroAndMaximumReadings() async {
        let samples: [(AirPodsBattery, [String])] = [
            (AirPodsBattery(isApproximate: true), ["-", "-"]),
            (AirPodsBattery(left: -1, right: 101, caseLevel: -1, isApproximate: true), ["-", "-"]),
            (
                AirPodsBattery(left: 100, right: 0, caseLevel: 100, isApproximate: true),
                ["~0%", "~100%"]
            ),
            (AirPodsBattery(left: 100, caseLevel: 0, isApproximate: true), ["~100%", "~0%"]),
            (AirPodsBattery(right: 30, isApproximate: true), ["~30%", "-"]),
            (AirPodsBattery(caseLevel: 80, isApproximate: true), ["-", "~80%"]),
            (AirPodsBattery(main: 100, isApproximate: true), ["~100%", "-"]),
        ]
        for (airPods, expected) in samples {
            let layout = ClockContentLayout(
                text: "1:00", battery: BatterySnapshot(airPods: airPods),
                preferences: ClockPreferences()
            )
            XCTAssertEqual(layout.rightColumn?.items.map(\.text), expected)
            XCTAssertEqual(
                layout.rightColumn?.items.map(\.isApproximate), expected.map { $0.hasPrefix("~") })
            XCTAssertEqual(layout.leftColumn?.items.map(\.text), ["-", "-"])
            XCTAssertFalse(layout.accessibilityValue.contains("~"))
            for item in layout.items {
                if let percentage = item.percentage {
                    XCTAssertTrue(
                        item.accessibilityText.contains("approximately \(percentage) percent"))
                } else {
                    XCTAssertEqual(item.text, "-")
                    XCTAssertEqual(item.accessibilityText, "\(item.id.title) unavailable")
                }
            }
        }
    }

    @MainActor
    func testApproximateTextFitsAndVisibilityKeepsFixedSlots() async throws {
        let snapshot = BatterySnapshot(
            mac: 100, iPhone: 0,
            airPods: AirPodsBattery(left: 100, right: 100, caseLevel: 0, isApproximate: true)
        )
        for name in [nil, "Helvetica-Bold", "Clocky-Missing-Test-Font"] as [String?] {
            for fontSize in [14.0, 28, 96] {
                var preferences = ClockPreferences()
                preferences.fontName = name
                preferences.fontSize = fontSize
                let full = ClockContentLayout(
                    text: "12:59:59 PM", battery: snapshot, preferences: preferences)
                let exact = ClockContentLayout(
                    text: full.text,
                    battery: BatterySnapshot(
                        mac: 100, iPhone: 0, airPods: AirPodsBattery(left: 100, caseLevel: 0)),
                    preferences: preferences
                )
                XCTAssertEqual(full.rowHeight, exact.rowHeight)
                let approximateColumn = try XCTUnwrap(full.rightColumn)
                let exactColumn = try XCTUnwrap(exact.rightColumn)
                XCTAssertGreaterThan(approximateColumn.size.width, exactColumn.size.width)
                let glyphHeight = ("0123456789%~-" as NSString).size(withAttributes: [
                    .font: full.batteryFont
                ]).height
                XCTAssertGreaterThanOrEqual(full.rowHeight, ceil(glyphHeight))
                for item in full.items {
                    let measured = (item.text as NSString).size(withAttributes: [
                        .font: full.batteryFont
                    ])
                    XCTAssertEqual(
                        item.textSize,
                        CGSize(width: ceil(measured.width), height: ceil(measured.height)))
                    XCTAssertGreaterThanOrEqual(full.rowHeight, item.textSize.height)
                    XCTAssertEqual(
                        item.width,
                        full.iconSize + ClockContentLayout.iconSpacing + item.textSize.width)
                }
                for mask in 0..<16 {
                    preferences.showsMacBattery = mask & 1 != 0
                    preferences.showsIPhoneBattery = mask & 2 != 0
                    preferences.showsAirPodsBattery = mask & 4 != 0
                    preferences.showsAirPodsCaseBattery = mask & 8 != 0
                    let enabled = [
                        preferences.showsMacBattery, preferences.showsIPhoneBattery,
                        preferences.showsAirPodsBattery, preferences.showsAirPodsCaseBattery,
                    ]
                    let expected = zip(full.items, enabled).compactMap { $1 ? $0 : nil }
                    let layout = ClockContentLayout(
                        text: full.text, battery: snapshot, preferences: preferences)
                    XCTAssertEqual(layout.items.map(\.text), expected.map(\.text))
                    XCTAssertEqual(layout.items.map(\.isApproximate), expected.map(\.isApproximate))
                    XCTAssertEqual(layout.leftColumn?.top?.id, enabled[0] ? .mac : nil)
                    XCTAssertEqual(layout.leftColumn?.bottom?.id, enabled[1] ? .iPhone : nil)
                    XCTAssertEqual(layout.rightColumn?.top?.id, enabled[2] ? .airPods : nil)
                    XCTAssertEqual(layout.rightColumn?.bottom?.id, enabled[3] ? .airPodsCase : nil)
                    XCTAssertEqual(
                        layout.columns.count,
                        (enabled[0] || enabled[1] ? 1 : 0) + (enabled[2] || enabled[3] ? 1 : 0))
                    XCTAssertEqual(layout.rowHeight, full.rowHeight)
                    XCTAssertEqual(
                        layout.size.height, mask == 0 ? layout.clockSize.height : full.size.height)
                    XCTAssertEqual(
                        layout.panelSize,
                        ClockPanel.preferredSize(
                            text: full.text, preferences: preferences, battery: snapshot))
                    for column in layout.columns {
                        XCTAssertEqual(column.size.width, column.items.map(\.width).max())
                        XCTAssertEqual(
                            column.size.height, 2 * full.rowHeight + ClockContentLayout.rowSpacing)
                    }
                    let available = CGSize(width: 80, height: 12)
                    let scale = layout.scaleFactor(in: available)
                    XCTAssertLessThanOrEqual(layout.size.width * scale, available.width + 0.0001)
                    XCTAssertLessThanOrEqual(layout.size.height * scale, available.height + 0.0001)
                }
            }
        }
    }

    @MainActor
    func testWholeContentScalesOnBothAxesWithoutClipping() async {
        let battery = BatterySnapshot(
            mac: 100, iPhone: 100, airPods: AirPodsBattery(left: 100, caseLevel: 100))
        for fontSize in [14.0, 96] {
            var preferences = ClockPreferences()
            preferences.fontSize = fontSize
            let layout = ClockContentLayout(
                text: "12:59:59 PM", battery: battery, preferences: preferences)
            XCTAssertEqual(layout.scaleFactor(in: layout.size), 1)
            for available in [
                CGSize(width: 800, height: 400), CGSize(width: 80, height: 300),
                CGSize(width: 500, height: 10), CGSize(width: 20, height: 8), .zero,
            ] {
                let scale = layout.scaleFactor(in: available)
                XCTAssertGreaterThanOrEqual(scale, 0)
                XCTAssertLessThanOrEqual(scale, 1)
                XCTAssertLessThanOrEqual(layout.size.width * scale, available.width + 0.0001)
                XCTAssertLessThanOrEqual(layout.size.height * scale, available.height + 0.0001)
                if available.width > 0 && available.height > 0 {
                    XCTAssertGreaterThan(scale, 0)
                    // Scaling is shared by every box and its separating gap.
                    for item in layout.items {
                        XCTAssertGreaterThan(
                            (item.width - item.textSize.width) * scale, layout.iconSize * scale)
                    }
                }
            }
        }
    }
}
