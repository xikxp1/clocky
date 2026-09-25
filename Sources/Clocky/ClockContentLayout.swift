import AppKit
import ClockyCore
import SwiftUI

/// Natural content metrics shared by rendering and native panel sizing.
struct ClockContentLayout {
    enum Side { case left, right }
    enum Row { case top, bottom }

    enum Reading: CaseIterable {
        case mac, iPhone, airPods, airPodsCase

        var side: Side {
            switch self {
            case .mac, .iPhone: return .left
            case .airPods, .airPodsCase: return .right
            }
        }

        var row: Row {
            switch self {
            case .mac, .airPods: return .top
            case .iPhone, .airPodsCase: return .bottom
            }
        }

        var title: String {
            switch self {
            case .mac: return "Mac"
            case .iPhone: return "iPhone"
            case .airPods: return "AirPods"
            case .airPodsCase: return "AirPods case"
            }
        }
    }

    struct Item: Identifiable {
        let id: Reading
        let systemImage: String
        let percentage: Int?
        let isApproximate: Bool
        let usesBluetooth: Bool
        let text: String
        let textSize: CGSize
        let width: CGFloat

        var accessibilityText: String {
            let value =
                percentage.map { "\(isApproximate ? "approximately " : "")\($0) percent" }
                ?? "unavailable"
            return "\(id.title) \(value)\(usesBluetooth ? " via Bluetooth" : "")"
        }
    }

    struct Column: Identifiable {
        let id: Side
        let top: Item?
        let bottom: Item?
        let size: CGSize

        var items: [Item] { [top, bottom].compactMap { $0 } }
    }

    static let iconSpacing: CGFloat = 3
    static let columnSpacing: CGFloat = 10
    static let rowSpacing: CGFloat = 2
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 10

    let text: String
    let clockFont: NSFont
    let batteryFont: NSFont
    let clockSize: CGSize
    let iconSize: CGFloat
    let rowHeight: CGFloat
    let columns: [Column]
    let size: CGSize

    var items: [Item] { columns.flatMap(\.items) }
    var leftColumn: Column? { columns.first { $0.id == .left } }
    var rightColumn: Column? { columns.first { $0.id == .right } }

    /// Preserve the existing padding and two-point native rounding allowance.
    var panelSize: CGSize {
        CGSize(
            width: size.width + 2 * Self.horizontalPadding + 2,
            height: size.height + 2 * Self.verticalPadding + 2)
    }

    var accessibilityLabel: String {
        columns.isEmpty ? "Current time" : "Current time and battery levels"
    }

    var accessibilityValue: String {
        columns.isEmpty
            ? text : "\(text). \(items.map(\.accessibilityText).joined(separator: ", "))"
    }

    /// Constrain both axes as a unit, including the clock, icons, text, and gaps.
    func scaleFactor(in availableSize: CGSize) -> CGFloat {
        min(
            1, max(0, availableSize.width) / max(1, size.width),
            max(0, availableSize.height) / max(1, size.height))
    }

    init(text: String, battery: BatterySnapshot, preferences: ClockPreferences) {
        let clockFont = ClockFont.resolve(preferences)
        let batteryFont = ClockFont.battery(preferences)
        let clockSize = Self.measure(text, font: clockFont)
        let iconSize = ceil(batteryFont.pointSize * 1.1)
        // Independent of enabled readings and values: disabling a top reading
        // never moves the bottom reading into its slot (or vice versa).
        let rowHeight = max(iconSize, Self.measure("0123456789%~-", font: batteryFont).height)
        let headsetSymbol =
            battery.airPods?.main != nil
                && battery.airPods?.left == nil && battery.airPods?.right == nil
            ? "airpodsmax" : "airpods"
        let readings: [(Reading, String, Int?, Bool)] = [
            (.mac, "laptopcomputer", battery.mac, preferences.showsMacBattery),
            (.iPhone, "iphone", battery.iPhone, preferences.showsIPhoneBattery),
            (
                .airPods, headsetSymbol, battery.airPods?.headsetPercentage,
                preferences.showsAirPodsBattery
            ),
            (
                .airPodsCase, "airpods.chargingcase", battery.airPods?.caseLevel,
                preferences.showsAirPodsCaseBattery
            ),
        ]
        let items = readings.compactMap { reading, symbol, percentage, enabled -> Item? in
            guard enabled else { return nil }
            let isApproximate =
                (reading == .airPods || reading == .airPodsCase)
                && battery.airPods?.isApproximate == true && percentage != nil
            let usesBluetooth = reading == .iPhone && battery.iPhoneUsesBLE && percentage != nil
            let value = percentage.map { "\(isApproximate ? "~" : "")\($0)%" } ?? "-"
            let measured = Self.measure(value, font: batteryFont)
            return Item(
                id: reading, systemImage: symbol, percentage: percentage,
                isApproximate: isApproximate, usesBluetooth: usesBluetooth, text: value,
                textSize: measured, width: iconSize + Self.iconSpacing + measured.width)
        }
        let columns = [Side.left, .right].compactMap { side -> Column? in
            let top = items.first { $0.id.side == side && $0.id.row == .top }
            let bottom = items.first { $0.id.side == side && $0.id.row == .bottom }
            guard top != nil || bottom != nil else { return nil }
            return Column(
                id: side, top: top, bottom: bottom,
                size: CGSize(
                    width: max(top?.width ?? 0, bottom?.width ?? 0),
                    height: 2 * rowHeight + Self.rowSpacing))
        }
        self.text = text
        self.clockFont = clockFont
        self.batteryFont = batteryFont
        self.clockSize = clockSize
        self.iconSize = iconSize
        self.rowHeight = rowHeight
        self.columns = columns
        self.size = CGSize(
            width: clockSize.width + columns.reduce(0) { $0 + $1.size.width }
                + CGFloat(columns.count) * Self.columnSpacing,
            height: max(clockSize.height, columns.map(\.size.height).max() ?? 0)
        )
    }

    private static func measure(_ text: String, font: NSFont) -> CGSize {
        let measured = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(measured.width), height: ceil(measured.height))
    }
}

struct ClockContent: View {
    let layout: ClockContentLayout

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: ClockContentLayout.columnSpacing) {
                if let column = layout.leftColumn { batteryColumn(column) }
                Text(layout.text)
                    .font(Font(layout.clockFont))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: layout.clockSize.width, height: layout.clockSize.height)
                if let column = layout.rightColumn { batteryColumn(column) }
            }
            .symbolRenderingMode(.monochrome)
            .frame(width: layout.size.width, height: layout.size.height)
            .scaleEffect(layout.scaleFactor(in: geometry.size))
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }

    private func batteryColumn(_ column: ClockContentLayout.Column) -> some View {
        VStack(spacing: ClockContentLayout.rowSpacing) {
            batterySlot(column.top, width: column.size.width)
            batterySlot(column.bottom, width: column.size.width)
        }
        .frame(width: column.size.width, height: column.size.height)
    }

    private func batterySlot(_ item: ClockContentLayout.Item?, width: CGFloat) -> some View {
        Group {
            if let item {
                HStack(spacing: ClockContentLayout.iconSpacing) {
                    Image(systemName: item.systemImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: layout.iconSize, height: layout.iconSize)
                    Text(item.text)
                        .font(Font(layout.batteryFont))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: item.textSize.width, height: item.textSize.height)
                }
            } else {
                Color.clear
            }
        }
        .frame(width: width, height: layout.rowHeight, alignment: .leading)
    }
}
