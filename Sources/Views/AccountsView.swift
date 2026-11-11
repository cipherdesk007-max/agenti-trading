import SwiftUI

/// Conti Alpaca: stessa chiave Kimi, più conti paper o live da alternare
/// (es. un paper da 1.000 $ per le prove e uno più grande per altri test).
struct AccountsView: View {
    @EnvironmentObject private var engine: QuantSwarmEngine
    @State private var adding = false
    @State private var name = ""
    @State private var keyID = ""
    @State private var secret = ""
    @State private var paper = true
    @State private var busy = false
    @State private var message: String?
    @State private var confirmLive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Capsule().fill(Theme.cyan).frame(width: 3, height: 12)
                Text("CONTI ALPACA")
                    .font(.system(.caption, design: .monospaced, weight: .heavy))
                    .foregroundStyle(Theme.cyan)
                Spacer()
                Button(adding ? "ANNULLA" : "+ AGGIUNGI") { adding.toggle(); message = nil }
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(Theme.cyan)
            }
            ForEach(engine.alpacaProfiles) { profile in
                let active = profile.id == engine.activeProfileID
                HStack(spacing: 10) {
                    Image(systemName: active ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(active ? Theme.green : Theme.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        Text((profile.paperTrading ? "PAPER" : "LIVE") + " · chiave …" + String(profile.keyID.suffix(4)))
                            .font(.caption.monospaced())
                            .foregroundStyle(profile.paperTrading ? Theme.textSecondary : Theme.red)
                    }
                    Spacer()
                    if active {
                        Text("ATTIVO").themedChip(Theme.green)
                    } else {
                        Button("USA") { Task { await use(profile) } }
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(Theme.cyan)
                            .disabled(busy || engine.isRunning)
                        Button { Task { await engine.removeAlpacaProfile(id: profile.id) } } label: {
                            Image(systemName: "trash").foregroundStyle(Theme.red)
                        }
                        .disabled(busy)
                    }
                }
                .padding(10)
                .background(Theme.surface, in: Theme.shape(Theme.smallRadius))
            }
            if engine.isRunning {
                Text("Per cambiare conto ferma prima il motore.")
                    .font(.caption).foregroundStyle(Theme.amber)
            }
            if adding {
                VStack(alignment: .leading, spacing: 8) {
                    field("Nome (es. Paper 1.000 $)", $name, secure: false)
                    field("API Key ID", $keyID, secure: false)
                    field("Secret Key", $secret, secure: true)
                    Toggle("Conto paper (simulato)", isOn: $paper)
                        .font(.caption.weight(.semibold))
                        .tint(Theme.green)
                    Button(busy ? "VERIFICO…" : "VERIFICA E SALVA") { Task { await save() } }
                        .font(.system(.body, design: .monospaced, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(Theme.cyan.opacity(0.18), in: Theme.shape(Theme.smallRadius))
                        .foregroundStyle(Theme.cyan)
                        .disabled(busy || keyID.isEmpty || secret.isEmpty)
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(message.hasPrefix("Errore") ? Theme.red : Theme.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("La chiave Kimi resta la stessa. Ogni conto ha registro, curva del capitale e protezioni separati. Le chiavi restano nel Keychain con Face ID.")
                .font(.caption).foregroundStyle(.gray)
                .fixedSize(horizontal: false, vertical: true)
                .explanation()
        }
        .themedCard(Theme.cyan)
        .alert("PASSARE A UN CONTO LIVE?", isPresented: $confirmLive) {
            Button("ANNULLA", role: .cancel) {}
            Button("USA LIVE", role: .destructive) { Task { await performSwitch() } }
        } message: {
            Text("Con un conto live gli ordini usano soldi veri.")
        }
    }

    @State private var pending: AlpacaProfile?

    private func use(_ profile: AlpacaProfile) async {
        pending = profile
        if !profile.paperTrading { confirmLive = true } else { await performSwitch() }
    }

    private func performSwitch() async {
        guard let profile = pending else { return }
        busy = true
        defer { busy = false }
        do {
            try await engine.switchAlpacaProfile(id: profile.id)
            message = "Conto attivo: \(profile.name)."
        } catch {
            message = "Errore: \(error.localizedDescription)"
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            try await engine.addAlpacaProfile(name: name, keyID: keyID, secretKey: secret, paperTrading: paper)
            message = "Conto salvato. Tocca USA per attivarlo."
            name = ""; keyID = ""; secret = ""; adding = false
        } catch {
            message = "Errore: \(error.localizedDescription)"
        }
    }

    private func field(_ title: String, _ text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure { SecureField(title, text: text) } else { TextField(title, text: text) }
        }
        .font(.system(.body, design: .monospaced))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .padding(10)
        .background(Theme.surfaceHigh, in: Theme.shape(Theme.smallRadius))
    }
}
