import AppKit
import ClockyCore

/// Rendering and window measurement must use the same font, including fallback.
enum ClockFont {
    static func resolve(_ preferences: ClockPreferences) -> NSFont {
        resolve(preferences, size: preferences.fontSize)
    }

    static func battery(_ preferences: ClockPreferences) -> NSFont {
        resolve(preferences, size: max(10, preferences.fontSize * 0.45))
    }

    private static func resolve(_ preferences: ClockPreferences, size: CGFloat) -> NSFont {
        if let name = preferences.fontName, let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
    }

    static func isAvailable(_ name: String?) -> Bool {
        guard let name else { return true }
        return NSFont(name: name, size: 28) != nil
    }
}

struct FontFace: Identifiable, Equatable {
    let name: String
    let title: String
    var id: String { name }
}

@MainActor
final class FontCatalog: ObservableObject {
    @Published private(set) var families: [String] = []
    private var facesByFamily: [String: [FontFace]] = [:]
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: NSFont.fontSetChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        facesByFamily.removeAll()
        families = Set(NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func family(for name: String?) -> String? {
        guard let name, let family = NSFont(name: name, size: 28)?.familyName,
              families.contains(family) else { return nil }
        return family
    }

    func faces(in family: String) -> [FontFace] {
        if let cached = facesByFamily[family] { return cached }
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        var seen: Set<String> = []
        let faces = members.compactMap { member -> FontFace? in
            guard member.count >= 2, let name = member[0] as? String,
                  let title = member[1] as? String, ClockFont.isAvailable(name),
                  seen.insert(name).inserted else { return nil }
            return FontFace(name: name, title: title)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        facesByFamily[family] = faces
        return faces
    }

    func defaultFace(in family: String) -> String? {
        let choices = faces(in: family)
        if let regular = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 28),
           choices.contains(where: { $0.name == regular.fontName }) {
            return regular.fontName
        }
        return choices.first?.name
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
