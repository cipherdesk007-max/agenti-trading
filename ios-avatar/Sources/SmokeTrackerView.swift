import Foundation
import SwiftUI

struct SmokeTrackerView: View {
    @Environment(AppStore.self) private var store
    @State private var now = Date()
    @State private var editing = false

    private var elapsed: TimeInterval {
        guard store.smoke.enabled else { return 0 }
        return max(0, now.timeIntervalSince(store.smoke.quitDate))
    }

    private var moneySaved: Double {
        let cigarettes = elapsed / 86400 * Double(store.smoke.cigarettesPerDay)
        guard store.smoke.cigarettesPerPack > 0 else { return 0 }
        return cigarettes / Double(store.smoke.cigarettesPerPack) * store.smoke.packPrice
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if store.smoke.enabled {
                    countdownCard
                    moneyCard
                    healthCard
                    Button {
                        editing = true
                    } label: {
                        Label("Modifica impostazioni", systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    SmokeSetupView(standalone: true)
                }
            }
            .padding()
        }
        .navigationTitle("Smetti di fumare")
        .background(Color.black)
        .sheet(isPresented: $editing) { SmokeSetupView(standalone: false) }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    private var countdownCard: some View {
        VStack(spacing: 12) {
            Text("Senza fumare da")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            let d = Int(elapsed) / 86400
            let hh = Int(elapsed) / 3600 % 24
            let mm = Int(elapsed) / 60 % 60
            let ss = Int(elapsed) % 60
            HStack(spacing: 10) {
                TimeTile(value: d, label: "giorni")
                TimeTile(value: hh, label: "ore")
                TimeTile(value: mm, label: "min")
                TimeTile(value: ss, label: "sec")
            }
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private var moneyCard: some View {
        HStack {
            Image(systemName: "eurosign.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading) {
                Text("Risparmiati")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(moneySaved.formatted(.currency(code: "EUR")))
                    .font(.title3.bold())
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text("Sigarette evitate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(Int(elapsed / 86400 * Double(store.smoke.cigarettesPerDay)))")
                    .font(.title3.bold())
            }
        }
        .card()
    }

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recupero della salute")
                .font(.headline)
            ForEach(HealthMilestone.all) { milestone in
                let progress = min(1, (elapsed / 60) / milestone.minutes)
                HStack(spacing: 10) {
                    Image(systemName: milestone.icon)
                        .foregroundStyle(progress >= 1 ? .green : Theme.accent)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(milestone.title).font(.subheadline.bold())
                            Spacer()
                            Text(progress >= 1 ? "Completato" : formatDuration(milestone.minutes))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: progress)
                            .tint(progress >= 1 ? .green : Theme.accent)
                        Text(milestone.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .card()
    }

    private func formatDuration(_ minutes: Double) -> String {
        if minutes < 60 { return "\(Int(minutes)) min" }
        if minutes < 1440 { return "\(Int(minutes / 60)) h" }
        if minutes < 10080 { return "\(Int(minutes / 1440)) gg" }
        if minutes < 525600 { return "\(Int(minutes / 10080)) sett." }
        return "\(Int(minutes / 525600)) anni"
    }
}

struct TimeTile: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(.title2, design: .rounded).bold())
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(uiColor: .tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SmokeSetupView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var standalone: Bool

    var body: some View {
        Group {
            if standalone {
                form
                    .padding()
                    .card()
            } else {
                NavigationStack {
                    form
                        .padding()
                        .navigationTitle("Impostazioni")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Chiudi") { dismiss() }
                            }
                        }
                }
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ultimo mozzicone")
                .font(.headline)
            DatePicker("Data e ora", selection: $store.smoke.quitDate)
                .datePickerStyle(.compact)
            Stepper("Sigarette al giorno: \(store.smoke.cigarettesPerDay)", value: $store.smoke.cigarettesPerDay, in: 1...60)
            Stepper("Prezzo pacchetto: € \(String(format: "%.2f", store.smoke.packPrice))", value: $store.smoke.packPrice, in: 1...30, step: 0.5)
            Stepper("Sigarette per pacchetto: \(store.smoke.cigarettesPerPack)", value: $store.smoke.cigarettesPerPack, in: 10...40, step: 10)
            Button {
                store.smoke.enabled = true
                if !standalone { dismiss() }
            } label: {
                Label(store.smoke.enabled ? "Salva" : "Avvia il contatore", systemImage: store.smoke.enabled ? "checkmark" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            if store.smoke.enabled {
                Button("Disattiva tracker", role: .destructive) {
                    store.smoke.enabled = false
                    if !standalone { dismiss() }
                }
            }
        }
    }
}
