import SwiftUI

/// The minimal ask popover: text field, mic, send; lasso hint; thinking state.
struct InkyAskCard: View {
    @Bindable var session: InkySession
    let editor: PageEditorModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                InkyCharacterView(state: session.characterState, size: 30)

                if session.phase == .thinking {
                    Text("Looking at your page…")
                        .font(.system(size: 16, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("inky.thinking")
                    ProgressView()
                        .controlSize(.small)
                } else {
                    TextField(session.speechInput.isListening ? "Listening…" : "Ask Inky…", text: $session.question, axis: .vertical)
                        .font(.system(size: 17))
                        .lineLimit(1...4)
                        .focused($focused)
                        .submitLabel(.send)
                        .onSubmit { session.submit(editor: editor) }
                        .accessibilityIdentifier("inky.ask.field")

                    Button(action: session.toggleListening) {
                        Image(systemName: session.speechInput.isListening ? "waveform" : "mic")
                            .font(.system(size: 17, weight: .medium))
                            .symbolEffect(.variableColor.iterative, isActive: session.speechInput.isListening)
                            .frame(width: 34, height: 34)
                            .foregroundStyle(session.speechInput.isListening ? Theme.accent : Color.primary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(session.speechInput.isListening ? "Stop listening" : "Ask by voice")
                    .accessibilityIdentifier("inky.ask.mic")

                    Button { session.submit(editor: editor) } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(canSend ? Theme.accent : Color.gray.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityLabel("Ask")
                    .accessibilityIdentifier("inky.ask.send")
                }
            }

            HStack(spacing: 8) {
                if editor.lassoRegion != nil {
                    Label("Selected area", systemImage: "lasso")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.accent)
                    Button { editor.clearLasso() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear selection")
                } else if let error = session.speechInput.errorMessage {
                    Text(error).font(.system(size: 13)).foregroundStyle(.red.opacity(0.8))
                } else {
                    Text("Circle part of the page to point Inky at it")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button(session.phase == .thinking ? "Stop" : "Close") { session.dismiss(editor: editor) }
                    .font(.system(size: 13, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("inky.ask.close")
            }
        }
        .padding(14)
        .frame(width: 420)
        .inkySurface(cornerRadius: 18)
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inky.ask")
    }

    private var canSend: Bool {
        !session.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct InkyFloatingButton: View {
    let state: InkyCharacterState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            InkyCharacterView(state: state, size: 34)
                .frame(width: 58, height: 58)
                .background(Circle().fill(Theme.surface).shadow(color: Theme.shadowColor, radius: 12, y: 4))
                .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask Inky")
        .accessibilityIdentifier("inky.summon")
    }
}

struct InkyToastView: View {
    let toast: InkySession.Toast
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if toast.isError {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.red.opacity(0.8))
            } else {
                InkyCharacterView(state: .happy, size: 22)
            }
            Text(toast.text)
                .font(.system(size: 15, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("inky.toast.text")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 520)
        .inkySurface(cornerRadius: 22)
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inky.toast")
    }
}

/// Long explanations. Play button reads it aloud.
struct InkySidebarView: View {
    let content: InkySession.SidebarContent
    let speech: SpeechOutput
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                InkyCharacterView(state: speech.isSpeaking && !speech.isPaused ? .speaking : .idle, size: 26)
                Text("Inky")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer()
                if content.speakable {
                    Button { speech.toggle(markdown: content.markdown) } label: {
                        Image(systemName: speech.isSpeaking && !speech.isPaused ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Theme.accent))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(speech.isSpeaking && !speech.isPaused ? "Pause" : "Read aloud")
                    .accessibilityIdentifier("inky.sidebar.play")
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("inky.sidebar.close")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !content.question.isEmpty {
                        Text(content.question)
                            .font(.system(size: 14, design: .rounded))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    MarkdownView(markdown: content.markdown)
                }
                .padding(20)
            }
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity)
        .background(Theme.surface)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inky.sidebar")
        .onDisappear { speech.stop() }
    }
}
