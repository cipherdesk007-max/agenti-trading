import Foundation
import SwiftUI

struct CalendarView: View {
    @Environment(AppStore.self) private var store
    @State private var selected = Date()
    @State private var showAdd = false

    private var days: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (-3...3).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
    }

    private var dayEvents: [CalendarEvent] {
        store.events
            .filter { Calendar.current.isDate($0.date, inSameDayAs: selected) }
            .sorted { $0.date < $1.date }
    }

    private var completion: Double {
        guard !dayEvents.isEmpty else { return 0 }
        return Double(dayEvents.filter { $0.isDone }.count) / Double(dayEvents.count)
    }

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(days, id: \.self) { day in
                        dayButton(day)
                    }
                }
                .padding(.horizontal)
            }

            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: completion)
                        .stroke(completion >= 1 ? .green : Theme.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(completion * 100))%")
                        .font(.caption.bold())
                        .monospacedDigit()
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Completamento giornata").font(.subheadline.bold())
                    Text("\(dayEvents.filter { $0.isDone }.count) di \(dayEvents.count) attività spuntate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)

            List {
                if dayEvents.isEmpty {
                    Text("Nessuna attività per questo giorno. Tocca + per aggiungerne una.")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                ForEach(0..<24, id: \.self) { hour in
                    let eventsAtHour = dayEvents.filter { Calendar.current.component(.hour, from: $0.date) == hour }
                    if !eventsAtHour.isEmpty {
                        Section {
                            ForEach(eventsAtHour) { ev in
                                eventRow(ev)
                            }
                            .onDelete { indexSet in
                                let ids = indexSet.map { eventsAtHour[$0].id }
                                store.events.removeAll { ids.contains($0.id) }
                            }
                        } header: {
                            Text("\(String(format: "%02d", hour)):00")
                                .font(.caption.bold())
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("TIMELINE 24H")
        .background(Color.black)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    haptic()
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAdd) { AddEventView(baseDate: selected) }
    }

    private func dayButton(_ day: Date) -> some View {
        let cal = Calendar.current
        let isSelected = cal.isDate(day, inSameDayAs: selected)
        let isToday = cal.isDateInToday(day)
        return Button {
            haptic()
            selected = day
        } label: {
            VStack(spacing: 2) {
                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.caption2)
                Text(day.formatted(.dateTime.day()))
                    .font(.headline)
            }
            .frame(width: 52, height: 64)
            .foregroundStyle(isSelected ? .black : (isToday ? Theme.accent : .primary))
            .background(isSelected ? Theme.accent : Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func eventRow(_ ev: CalendarEvent) -> some View {
        HStack(spacing: 12) {
            Button {
                store.toggleEvent(ev.id)
            } label: {
                Image(systemName: ev.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(ev.isDone ? .green : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(ev.title)
                    .strikethrough(ev.isDone)
                Text(ev.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if ev.reminder {
                Image(systemName: "bell.fill")
                    .foregroundStyle(Theme.gold)
            }
        }
    }
}

struct AddEventView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var baseDate: Date
    @State private var title = ""
    @State private var date: Date
    @State private var reminder = false

    init(baseDate: Date) {
        self.baseDate = baseDate
        _date = State(initialValue: baseDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Titolo (es. allenamento, lavoro, abitudine...)", text: $title)
                DatePicker("Data e ora", selection: $date)
                Toggle("Promemoria", isOn: $reminder)
            }
            .navigationTitle("Nuovo evento")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        let clean = title.trimmingCharacters(in: .whitespaces)
                        guard !clean.isEmpty else { return }
                        haptic(.medium)
                        store.events.append(CalendarEvent(title: clean, date: date, reminder: reminder))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
