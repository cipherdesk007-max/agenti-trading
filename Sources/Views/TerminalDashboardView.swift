import SwiftUI

struct TerminalDashboardView: View {
    @EnvironmentObject private var engine: QuantSwarmEngine
    @State private var symbols = "SPY"
    @State private var news = ""
    @State private var showKillConfirmation = false

    private let terminalGreen = Color(red: 0.1, green: 1.0, blue: 0.55)

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        statusPanel
                        edgePanel
                        controlPanel
                        logPanel
                        killButton
                    }
                    .padding()
                }
            }
            .navigationTitle("QUANTSWARM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("LOGOUT") {
                        Task { await engine.logout() }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(terminalGreen)
                    .disabled(engine.isKillInProgress)
                }
            }
            .alert("HARD KILL SWITCH", isPresented: $showKillConfirmation) {
                Button("ANNULLA", role: .cancel) {}
                Button("LIQUIDA TUTTO", role: .destructive) {
                    Task { await engine.hardKill() }
                }
            } message: {
                Text("Ferma il motore, cancella tutti gli ordini e richiede ad Alpaca la chiusura a mercato di tutte le posizioni del conto configurato.")
            }
        }
    }

    private var statusPanel: some View {
        HStack {
            Circle()
                .fill(engine.isRunning ? terminalGreen : .gray)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 4) {
                Text(engine.paperTrading ? "PAPER ENVIRONMENT" : "LIVE CAPITAL")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(engine.paperTrading ? terminalGreen : .red)
                Text(engine.statusMessage)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.gray)
            }
            Spacer()
        }
        .panelStyle(terminalGreen)
    }

    private var edgePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EDGE · EQUITY DELTA USD")
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(terminalGreen)
            EdgeChart(points: engine.edgeHistory, color: terminalGreen)
                .frame(height: 180)
        }
        .panelStyle(terminalGreen)
    }

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SYMBOLS · COMMA SEPARATED")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.gray)
            TextField("SPY,QQQ", text: $symbols)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(10)
                .background(Color(white: 0.08))
                .disabled(engine.isRunning)

            Text("NEWS / SENTIMENT INPUT")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.gray)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $news)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color(white: 0.08))
                    .frame(height: 80)
                    .disabled(engine.isRunning)
                if news.isEmpty {
                    Text("Incolla notizie con data e fonte; nessun feed news automatico.")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.gray)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 12) {
                Button("START") {
                    Task { await engine.start(symbolsText: symbols, news: news) }
                }
                .buttonStyle(TerminalButtonStyle(color: terminalGreen))
                .disabled(engine.isRunning || engine.isKillInProgress)

                Button("STOP") {
                    Task { await engine.stop() }
                }
                .buttonStyle(TerminalButtonStyle(color: .orange))
                .disabled(!engine.isRunning || engine.isKillInProgress)
            }
        }
        .panelStyle(terminalGreen)
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ATOMIC AGENT LOG")
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(terminalGreen)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(engine.logs) { entry in
                            Text("\(entry.timestamp.formatted(date: .omitted, time: .standard))  \(entry.message)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                }
                .frame(height: 220)
                .onChange(of: engine.logs.count) { _, _ in
                    if let id = engine.logs.last?.id {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
        }
        .panelStyle(terminalGreen)
    }

    private var killButton: some View {
        Button {
            showKillConfirmation = true
        } label: {
            Text("HARD KILL SWITCH")
                .font(.system(.headline, design: .monospaced, weight: .black))
                .frame(maxWidth: .infinity)
                .padding()
                .background(engine.isKillInProgress ? Color.gray : Color.red)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .disabled(engine.isKillInProgress)
        .accessibilityHint("Richiede conferma prima di liquidare tutte le posizioni")
    }
}

private struct EdgeChart: View {
    let points: [EdgePoint]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let gridPath = Path { path in
                for index in 0...4 {
                    let y = size.height * Double(index) / 4
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
            context.stroke(gridPath, with: .color(.gray.opacity(0.25)), lineWidth: 0.5)

            guard !points.isEmpty else {
                context.draw(
                    Text("ATTESA DATI EQUITY").font(.system(.caption, design: .monospaced)),
                    at: CGPoint(x: size.width / 2, y: size.height / 2)
                )
                return
            }

            let values = points.map(\.value)
            let minimum = min(values.min() ?? 0, 0)
            let maximum = max(values.max() ?? 0, 0)
            let span = max(maximum - minimum, 0.000_001)
            let line = Path { path in
                for (index, point) in points.enumerated() {
                    let x = points.count == 1
                        ? size.width / 2
                        : size.width * Double(index) / Double(points.count - 1)
                    let y = size.height - ((point.value - minimum) / span) * size.height
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
        .background(Color(white: 0.04))
        .overlay(Rectangle().stroke(color.opacity(0.4), lineWidth: 1))
    }
}

private struct TerminalButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .monospaced, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding()
            .background(color.opacity(configuration.isPressed ? 0.35 : 0.18))
            .foregroundStyle(color)
            .overlay(Rectangle().stroke(color, lineWidth: 1))
    }
}

private extension View {
    func panelStyle(_ color: Color) -> some View {
        padding()
            .background(Color(white: 0.06))
            .overlay(Rectangle().stroke(color.opacity(0.35), lineWidth: 1))
    }
}
