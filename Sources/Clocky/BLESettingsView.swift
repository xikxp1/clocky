import ClockyCore
import SwiftUI

struct BLESettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var ble: BLEBatteryController

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.preferences.ble.enabled },
            set: { enabled in
                settings.update { $0.ble.enabled = enabled }
                if !enabled { ble.cancelDiscovery() }
            }
        )
    }

    var body: some View {
        Section {
            Toggle("Enable Bluetooth fallback", isOn: enabledBinding)
                .disabled(!ble.available)
            HStack {
                Button(ble.isDiscovering ? "Stop Scan" : "Scan for Devices") {
                    if ble.isDiscovering {
                        ble.cancelDiscovery()
                    } else if ble.available && settings.preferences.ble.enabled {
                        ble.discover()
                    }
                }
                .disabled(
                    !ble.isDiscovering && (!ble.available || !settings.preferences.ble.enabled))
                Text(ble.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            devicePicker("AirPods", kind: .airPods, keyPath: \.airPods)
            devicePicker("iPhone (experimental)", kind: .iPhone, keyPath: \.iPhone)
        } header: {
            Text("Optional Bluetooth fallback")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "Off by default. System/USB/Wi-Fi readings take priority. BLE fills only an entirely missing device reading, never individual components."
                )
                Text(
                    "AirPods: approximate 10-percentage-point steps (~), not precise charge. Closed-case readings are not guaranteed."
                )
                Text(
                    "iPhone: experimental GATT. Discovery hints must pass device-metadata verification; newer iOS may not work. Only the selected iPhone may be connected."
                )
                Text(
                    "Bluetooth permission is required; scans stop automatically. UUID/name choices stay local. Identifiers can change and require reselection. Forget clears a choice."
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func devicePicker(
        _ title: String, kind: BLEDeviceCandidate.Kind,
        keyPath: WritableKeyPath<BLEPreferences, BLEDeviceSelection?>
    ) -> some View {
        let saved = settings.preferences.ble[keyPath: keyPath]
        let choices = deviceChoices(kind: kind, saved: saved)
        return HStack {
            Picker(title, selection: selectionBinding(kind: kind, keyPath: keyPath)) {
                Text("None").tag(Optional<UUID>.none)
                ForEach(choices) { device in
                    Text(deviceTitle(device)).tag(Optional(device.id))
                }
            }
            .disabled(!settings.preferences.ble.enabled || !ble.available)
            Button("Forget") { settings.update { $0.ble[keyPath: keyPath] = nil } }
                .disabled(saved == nil)
                .accessibilityLabel("Forget selected \(title)")
        }
    }

    private func deviceChoices(
        kind: BLEDeviceCandidate.Kind, saved: BLEDeviceSelection?
    ) -> [BLEDeviceSelection] {
        var choices = ble.candidates.filter { $0.kind == kind }.map {
            BLEDeviceSelection(id: $0.id, name: $0.name)
        }
        // Keep the remembered UUID selectable even when this scan cannot see it.
        if let saved, !choices.contains(where: { $0.id == saved.id }) {
            choices.insert(saved, at: 0)
        }
        return choices
    }

    private func selectionBinding(
        kind: BLEDeviceCandidate.Kind,
        keyPath: WritableKeyPath<BLEPreferences, BLEDeviceSelection?>
    ) -> Binding<UUID?> {
        Binding(
            get: { settings.preferences.ble[keyPath: keyPath]?.id },
            set: { id in
                guard let id else {
                    settings.update { $0.ble[keyPath: keyPath] = nil }
                    return
                }
                // Resolve identities, never names, and accept only scanned or saved choices.
                let saved = settings.preferences.ble[keyPath: keyPath]
                guard
                    let device = deviceChoices(kind: kind, saved: saved).first(where: {
                        $0.id == id
                    })
                else { return }
                settings.update { $0.ble[keyPath: keyPath] = device }
            }
        )
    }

    private func deviceTitle(_ device: BLEDeviceSelection) -> String {
        let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(name.isEmpty ? "Unnamed device" : name) · \(device.id.uuidString.suffix(8))"
    }
}
