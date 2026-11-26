import SwiftUI
import DORMEKit

/// A message on DORM-E's own screen, with an optional countdown (command screen.note, 2026-11-26).
/// Works now with just the Pi and the screen: a door sign ("Studying, back at 5"), a study timer, a reminder.
struct ScreenNoteCard: View {
    @Environment(RobotStore.self) private var store
    @State private var text = ""
    @State private var minutes = 0
    @State private var busy = false
    private let choices = [0, 5, 15, 25, 50, 60]

    private var current: ScreenNote? { store.state?.screen?.note }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "text.bubble").font(.title3.weight(.semibold))
                    Text("On DORM-E's screen").font(.headline)
                    Spacer()
                }
                if let note = current {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.text).font(.body.weight(.semibold))
                        if let until = note.until {
                            Text(timerInterval: Date()...max(Date(), Date(timeIntervalSince1970: until)), countsDown: true)
                                .font(.title3.monospacedDigit()).foregroundStyle(Theme.accent)
                        }
                    }
                    Button("Clear the screen") { send("", 0) }
                        .buttonStyle(.bordered).tint(Theme.ink).disabled(busy)
                }
                TextField("Message, e.g. Studying - back at 5", text: $text)
                    .accessibilityIdentifier("note.text")
                    .padding(10).background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onChange(of: text) { _, new in if new.count > 60 { text = String(new.prefix(60)) } }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(choices, id: \.self) { m in
                            Button(m == 0 ? "No timer" : "\(m) min") { minutes = m }
                                .buttonStyle(.bordered)
                                .tint(minutes == m ? Theme.accent : Theme.ink)
                        }
                    }
                }
                Button { send(text, minutes * 60) } label: {
                    Label(minutes > 0 ? "Show with \(minutes) min timer" : "Show on screen", systemImage: "display")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.ink)
                .disabled(busy || !store.hasClient || (text.trimmingCharacters(in: .whitespaces).isEmpty && minutes == 0))
            }
        }
    }

    private func send(_ message: String, _ seconds: Int) {
        busy = true
        Task {
            let ack = await store.screenNote(message.trimmingCharacters(in: .whitespacesAndNewlines), seconds: seconds)
            busy = false
            if ack.ok, !message.isEmpty { text = "" }
        }
    }
}
