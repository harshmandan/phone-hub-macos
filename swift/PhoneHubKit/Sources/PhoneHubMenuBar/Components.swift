import SwiftUI

/// One notification, Phone Hub-style: app + title + text, with a dismiss button
/// and (when the notification supports it) an inline reply field.
struct NotificationRow: View {
    @EnvironmentObject var engine: PhoneHubEngine
    let note: UINotification
    @State private var replying = false
    @State private var replyText = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: appIcon).font(.body).foregroundStyle(Palette.accent).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(note.app.isEmpty ? "App" : note.app).font(.caption.weight(.semibold))
                        Spacer()
                        Button { engine.dismiss(note.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                    }
                    if !note.title.isEmpty { Text(note.title).font(.subheadline.weight(.medium)) }
                    if !note.text.isEmpty {
                        Text(note.text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if note.canReply {
                        if replying {
                            HStack(spacing: 6) {
                                TextField("Reply…", text: $replyText)
                                    .textFieldStyle(.roundedBorder).font(.caption).focused($focused)
                                    .onSubmit(send)
                                Button(action: send) { Image(systemName: "paperplane.fill") }
                                    .buttonStyle(.plain).foregroundStyle(Palette.accent)
                                    .disabled(replyText.isEmpty)
                            }
                        } else {
                            Button { replying = true; focused = true } label: {
                                Label("Reply", systemImage: "arrowshape.turn.up.left").font(.caption2)
                            }
                            .buttonStyle(.plain).foregroundStyle(Palette.accent).padding(.top, 2)
                        }
                    }
                }
            }
        }
        .padding(10)
        .glassCard(cornerRadius: 12)
    }

    private func send() {
        let t = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        engine.reply(to: note.id, text: t)
        replyText = ""; replying = false
    }

    private var appIcon: String {
        let a = note.app.lowercased()
        if a.contains("whats") || a.contains("messag") || a.contains("sms") { return "message.fill" }
        if a.contains("mail") || a.contains("gmail") { return "envelope.fill" }
        if a.contains("phone") || a.contains("call") { return "phone.fill" }
        if a.contains("cal") { return "calendar" }
        return "app.badge"
    }
}

/// A camera-roll thumbnail (loads the decoded thumbnail file the CLI wrote).
struct PhotoThumb: View {
    let photo: UIPhoto
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let path = photo.thumbnailPath, let img = NSImage(contentsOfFile: path) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial)
                        .overlay(Image(systemName: photo.isVideo ? "play.rectangle" : "photo").foregroundStyle(.secondary))
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if photo.isVideo {
                Image(systemName: "play.circle.fill").font(.caption).foregroundStyle(.white).padding(3)
            }
        }
        .help(photo.fileName)
    }
}
