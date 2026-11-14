import BlockEngine
import HubLink
import SwiftUI

/// Pastille d'état : connexion et batterie du hub.
struct HubStatusButton: View {
    @Environment(AppModel.self) private var app
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if app.isConnecting {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Circle()
                        .fill(app.hub.isConnected ? Color.green : Color.gray)
                        .frame(width: 12, height: 12)
                }
                Text(app.hub.isConnected ? app.connectionText : (app.isConnecting ? "Recherche…" : "Connecter"))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(1)
                if app.mode == .simulated {
                    Image(systemName: "desktopcomputer").font(.system(size: 13, weight: .bold))
                }
                if let battery = app.hub.batteryPercent {
                    Image(systemName: Self.batterySymbol(battery))
                        .foregroundStyle(battery <= 15 ? Color.red : Color.white)
                    Text("\(battery) %").font(.system(size: 13, weight: .semibold, design: .rounded))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 48)
            .frame(maxWidth: 320)
            .background(Capsule().fill(Theme.panelBackground))
        }
        .buttonStyle(.plain)
    }

    static func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// Feuille de connexion : choix du mode, état, commandes du simulateur, journal.
struct ConnectionSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Mode") {
                    Picker("Mode", selection: modeBinding) {
                        ForEach(AppModel.HubMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    if app.mode == .real {
                        Text("Allume le hub en appuyant sur son bouton, puis touche « Connecter ».")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Aucun matériel requis : un faux hub exécute les commandes et les journalise.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("État") {
                    HStack {
                        Text(app.connectionText)
                        Spacer()
                        if app.isConnecting { ProgressView() }
                        if let battery = app.hub.batteryPercent {
                            Label("\(battery) %", systemImage: HubStatusButton.batterySymbol(battery))
                        }
                    }
                    if app.hub.isConnected || app.isConnecting {
                        Button("Déconnecter", role: .destructive) { app.disconnect() }
                    } else {
                        Button("Connecter") { app.connect() }
                    }
                    if app.hub.isConnected {
                        sensorSummary
                    }
                }

                if app.mode == .simulated, app.hub.isConnected {
                    SimulatorControls()
                    Section("Commandes reçues par le faux hub") {
                        logLines(app.simulatorLog.suffix(30).reversed().map { $0 })
                    }
                }

                Section("Journal") {
                    let lines = app.log
                        .filter { $0.kind == .info || $0.kind == .warning }
                        .suffix(30)
                        .reversed()
                        .map { ($0.kind == .warning ? "⚠︎ " : "") + $0.text }
                    logLines(lines)
                    Button("Effacer les journaux") { app.clearLogs() }
                }
            }
            .navigationTitle("Hub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }

    private var modeBinding: Binding<AppModel.HubMode> {
        Binding(get: { app.mode }, set: { app.setMode($0) })
    }

    private var sensorSummary: some View {
        let hub = app.hub
        let color = hub.color.map { String(describing: $0) } ?? "aucune"
        let distance = hub.distance.map(String.init) ?? "rien en vue"
        return VStack(alignment: .leading, spacing: 4) {
            Text("Couleur : \(color) · Distance : \(distance)")
            Text("Inclinaison : \(hub.tiltX)° / \(hub.tiltY)° · Bouton : \(hub.buttonPressed ? "pressé" : "relâché")")
            Text("Moteurs : A \(position(.motorA)) · B \(position(.motorB)) · externe \(position(.motorExternal))")
        }
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func position(_ port: LogicalPort) -> String {
        app.hub.motorPosition(port).map { "\($0)°" } ?? "absent"
    }

    @ViewBuilder
    private func logLines(_ lines: [String]) -> some View {
        if lines.isEmpty {
            Text("Rien pour l'instant.").font(.footnote).foregroundStyle(.secondary)
        } else {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 12, design: .monospaced))
            }
        }
    }
}

/// Réglage à la main des capteurs du faux hub.
struct SimulatorControls: View {
    @Environment(AppModel.self) private var app

    @State private var color: SensorColor?
    @State private var hasObject = false
    @State private var distance = 5.0
    @State private var tiltX = 0.0
    @State private var tiltY = 0.0

    var body: some View {
        Section("Capteurs simulés") {
            HStack(spacing: 10) {
                Text("Couleur")
                Spacer()
                colorButton(nil)
                ForEach(SensorColor.allCases, id: \.self) { item in
                    colorButton(item)
                }
            }

            Toggle("Objet devant le capteur", isOn: $hasObject)
            if hasObject {
                HStack {
                    Text("Distance \(Int(distance))")
                    Slider(value: $distance, in: 0...10, step: 1)
                }
            }

            HStack {
                Text("Penché gauche-droite \(Int(tiltX))°").frame(width: 230, alignment: .leading)
                Slider(value: $tiltX, in: -90...90, step: 5)
            }
            HStack {
                Text("Penché avant-arrière \(Int(tiltY))°").frame(width: 230, alignment: .leading)
                Slider(value: $tiltY, in: -90...90, step: 5)
            }

            HStack {
                Button("Appuyer sur le bouton") { app.simulateButtonPress() }
                Spacer()
                Button("Secouer") { app.simulateShake(restingX: Int(tiltX), restingY: Int(tiltY)) }
            }
            .buttonStyle(.bordered)
        }
        .onChange(of: hasObject) { _, _ in sendDistance() }
        .onChange(of: distance) { _, _ in sendDistance() }
        .onChange(of: tiltX) { _, _ in sendTilt() }
        .onChange(of: tiltY) { _, _ in sendTilt() }
    }

    private func colorButton(_ item: SensorColor?) -> some View {
        let swatch = item.flatMap { Theme.swatch(for: String(describing: $0)) }
        return Button {
            color = item
            app.inject(.color(item?.rawValue))
        } label: {
            ZStack {
                Circle().fill(swatch ?? Color.gray.opacity(0.3))
                if item == nil {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                }
            }
            .frame(width: 32, height: 32)
            .overlay(Circle().stroke(color == item ? Theme.accent : Color.gray.opacity(0.6),
                                     lineWidth: color == item ? 4 : 1))
        }
        .buttonStyle(.plain)
    }

    private func sendDistance() {
        app.inject(.distance(hasObject ? UInt8(distance) : nil))
    }

    private func sendTilt() {
        app.inject(.tilt(x: Int(tiltX), y: Int(tiltY)))
    }
}
