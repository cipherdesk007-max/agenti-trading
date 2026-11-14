import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var engine: QuantSwarmEngine
    @State private var moonshotAPIKey = ""
    @State private var alpacaKeyID = ""
    @State private var alpacaSecretKey = ""
    @State private var paperTrading = true
    @State private var validating = false
    @State private var errorMessage: String?
    @State private var showLiveConfirmation = false
    @State private var liveConfirmText = ""

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("QuantSwarm")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Theme.ivory)
                            Text("Alpha Zero")
                                .font(.title2.weight(.medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Text("Kimi decision core · Alpaca execution")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }

                    credentialField(title: "Moonshot / Kimi API key", text: $moonshotAPIKey)
                    credentialField(title: "Alpaca key ID", text: $alpacaKeyID)
                    credentialField(title: "Alpaca secret key", text: $alpacaSecretKey)

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("PAPER TRADING", isOn: Binding(
                            get: { paperTrading },
                            set: { wantsPaper in
                                if wantsPaper {
                                    paperTrading = true
                                } else {
                                    // Live: seconda conferma obbligatoria.
                                    liveConfirmText = ""
                                    showLiveConfirmation = true
                                }
                            }
                        ))
                            .font(.callout.weight(.semibold))
                            .tint(Theme.accent)
                            .alert("PASSARE AL LIVE?", isPresented: $showLiveConfirmation) {
                                TextField("scrivi LIVE", text: $liveConfirmText)
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                                Button("ANNULLA", role: .cancel) { paperTrading = true }
                                Button("CONFERMA LIVE", role: .destructive) {
                                    paperTrading = liveConfirmText.trimmingCharacters(in: .whitespaces).uppercased() != "LIVE"
                                }
                            } message: {
                                Text("Con il live gli ordini usano SOLDI VERI e le perdite sono reali. Scrivi LIVE per confermare.")
                            }
                        Text(paperTrading
                             ? "Ordini inviati all'ambiente paper Alpaca."
                             : "Attenzione: ordini su capitale reale. Verifica prima in paper trading.")
                            .font(.caption)
                            .foregroundStyle(paperTrading ? Theme.textTertiary : Theme.red)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(Theme.red)
                            .textSelection(.enabled)
                    }

                    Button {
                        validate()
                    } label: {
                        HStack {
                            Spacer()
                            if validating {
                                ProgressView().tint(Theme.background)
                            } else {
                                Text("VALIDA · FACE ID · SBLOCCA")
                                    .font(.headline)
                            }
                            Spacer()
                        }
                    }
                    .primaryButton()
                    .disabled(validating || !canSubmit)
                    .opacity(validating ? 0.6 : 1)

                    Text("Le credenziali sono salvate come generic password nel Keychain con protezione biometrica e accessibilità ThisDeviceOnly. Il Keychain non rende le API key chiavi private del Secure Enclave.")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(Layout.paddingL)
            }
        }
    }

    private func credentialField(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            SecureField("Inserisci credenziale", text: text)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(Theme.surfaceHigh, in: Theme.shape(Theme.smallRadius))
        }
    }

    private var canSubmit: Bool {
        [moonshotAPIKey, alpacaKeyID, alpacaSecretKey].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func validate() {
        guard !validating, canSubmit else { return }
        validating = true
        errorMessage = nil
        Task {
            do {
                try await engine.validateAndSave(
                    moonshotAPIKey: moonshotAPIKey,
                    alpacaKeyID: alpacaKeyID,
                    alpacaSecretKey: alpacaSecretKey,
                    paperTrading: paperTrading
                )
                moonshotAPIKey = ""
                alpacaKeyID = ""
                alpacaSecretKey = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            validating = false
        }
    }
}
