import AppKit
import DictationCore
import SwiftUI

/// Drafts the follow-up mail for a meeting with the meeting notes' engine, shows it to edit, and
/// copies it or opens it in the mail app addressed to the other participants.
struct FollowUpMailSheet: View {
    let meeting: Meeting
    let settings: DictationSettings
    let done: () -> Void

    @State private var subject = ""
    @State private var mailBody = ""
    @State private var writing = true
    @State private var problem: String?
    @State private var copied = false

    private var recipients: [MeetingParticipant] {
        meeting.participants.filter { !$0.displayName.lowercased().hasPrefix(NotetakerController.ownName.lowercased()) && !$0.email.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Folge-Mail").font(.system(size: 22, design: .serif))
            if writing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Schreibe die Mail aus den Notizen …").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                .padding(.vertical, 30)
            } else if let problem {
                Text(problem).font(.system(size: 13)).foregroundStyle(.red)
            } else {
                Text("An: " + (recipients.isEmpty ? "keine Adressen im Kalendereintrag" : recipients.map(\.displayName).joined(separator: ", ")))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                TextField("Betreff", text: $subject).textFieldStyle(.roundedBorder)
                TextEditor(text: $mailBody)
                    .font(.system(size: 13))
                    .frame(minHeight: 320)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            }
            HStack {
                Button("Schließen") { done() }
                Spacer()
                if !writing && problem == nil {
                    Button(copied ? "Kopiert" : "Kopieren") {
                        let board = NSPasteboard.general
                        board.clearContents()
                        board.setString("\(subject)\n\n\(mailBody)", forType: .string)
                        copied = true
                    }
                    Button("In Mail-App öffnen") {
                        if let url = FollowUpMail(subject: subject, body: mailBody).mailto(to: recipients.map(\.email)) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 640)
        .task { await write() }
    }

    private func write() async {
        let client = settings.ai.completer(for: .meetings, llm: settings.llm)
        let language = MeetingTranscriber.mainLanguage(meeting.segments) ?? "de"
        let signature = settings.emailSignatureEnabled ? settings.emailSignature : ""
        do {
            let mail = try await FollowUpMail.write(meetingTitle: meeting.displayTitle, date: meeting.date, notes: meeting.notesMarkdown,
                                                    recipients: recipients.map(\.displayName), me: DemoMode.fullUserName,
                                                    signature: signature, language: language, client: client)
            subject = mail.subject
            mailBody = mail.body
            AppLog.info("follow-up mail written")
        } catch {
            problem = "Die Mail konnte nicht geschrieben werden: \(error)"
        }
        writing = false
    }
}
