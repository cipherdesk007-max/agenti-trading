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

    private let terminalGreen = Color(red: 0.1, green: 1.0, blue: 0.55)

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("QUANTSWARM // ALPHA ZERO")
                            .font(.system(.title2, design: .monospaced, weight: .bold))
                            .foregroundStyle(terminalGreen)
                        Text("KIMI DECISION CORE · ALPACA EXECUTION")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }

                    credentialField(title: "MOONSHOT / KIMI API KEY", text: $moonshotAPIKey)
                    credentialField(title: "ALPACA KEY ID", text: $alpacaKeyID)
                    credentialField(title: "ALPACA SECRET KEY", text: $alpacaSecretKey)

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
                            .font(.system(.callout, design: .monospaced, weight: .bold))
                            .tint(terminalGreen)
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
                             : "ATTENZIONE: ordini su capitale reale. Verifica prima in paper trading.")
                            .font(.caption)
                            .foregroundStyle(paperTrading ? .gray : .red)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }

                    Button {
                        validate()
                    } label: {
                        HStack {
                            Spacer()
                            if validating {
                                ProgressView().tint(.black)
                            } else {
                                Text("VALIDA · FACE ID · SBLOCCA")
                                    .font(.system(.body, design: .monospaced, weight: .bold))
                            }
                            Spacer()
                        }
                        .padding()
                        .background(terminalGreen)
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(validating || !canSubmit)
                    .opacity(validating ? 0.6 : 1)

                    Text("Le credenziali sono salvate come generic password nel Keychain con protezione biometrica e accessibilità ThisDeviceOnly. Il Keychain non rende le API key chiavi private del Secure Enclave.")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                .padding(24)
            }
        }
    }

    private func credentialField(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(terminalGreen)
            SecureField("INSERISCI CREDENZIALE", text: text)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(Color(white: 0.08), in: Theme.shape(Theme.smallRadius))
                .overlay(Theme.shape(Theme.smallRadius).strokeBorder(terminalGreen.opacity(0.55), lineWidth: 1))
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
