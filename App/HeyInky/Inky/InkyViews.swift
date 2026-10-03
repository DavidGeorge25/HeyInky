import SwiftUI

/// The minimal ask popover: text field, mic, send; lasso hint; thinking state.
struct InkyAskCard: View {
    @Bindable var session: InkySession
    let editor: PageEditorModel
    @FocusState private var focused: Bool

    private var isListening: Bool { session.speechInput.isListening }
    private var isThinking: Bool { session.phase == .thinking }
    /// Inky is out on the page drawing (answers stream in while the card is still up).
    private var isDrawing: Bool { editor.choreographer.isOnStage }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                InkyAvatar(state: session.characterState, size: 38, isAway: isDrawing)

                if isThinking {
                    HStack(spacing: 10) {
                        Text(isDrawing ? "Drawing on your page" : "Looking at your page")
                            .font(InkyStyle.voice(16, .medium))
                            .foregroundStyle(Color.primary.opacity(0.75))
                            .contentTransition(.opacity)
                        InkyThinkingDots(dotSize: 5)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("inky.thinking")
                } else {
                    TextField(isListening ? "Listening…" : "Ask Inky about this page…", text: $session.question, axis: .vertical)
                        .font(.system(size: 17))
                        .lineLimit(1...4)
                        .focused($focused)
                        .submitLabel(.send)
                        .onSubmit { session.submit(editor: editor) }
                        .accessibilityIdentifier("inky.ask.field")

                    micButton
                    sendButton
                }
            }
            .frame(minHeight: 40)

            HStack(spacing: 8) {
                footerHint
                Spacer(minLength: 8)
                Button(isThinking ? "Stop" : "Close") { session.dismiss(editor: editor) }
                    .font(InkyStyle.voice(13, .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.04)))
                    .accessibilityIdentifier("inky.ask.close")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 420)
        .inkySurface(cornerRadius: 22)
        .animation(InkyStyle.spring, value: isThinking)
        .animation(InkyStyle.spring, value: isListening)
        .animation(InkyStyle.spring, value: editor.lassoRegion)
        .sensoryFeedback(.selection, trigger: isListening)
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inky.ask")
    }

    private var micButton: some View {
        Button(action: session.toggleListening) {
            Image(systemName: isListening ? "waveform" : "mic")
                .font(.system(size: 16, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: isListening)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(isListening ? Theme.accent : Color.primary.opacity(0.55))
                .frame(width: 36, height: 36)
                .background(Circle().fill(isListening ? InkyStyle.tint : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isListening ? "Stop listening" : "Ask by voice")
        .accessibilityIdentifier("inky.ask.mic")
    }

    private var sendButton: some View {
        Button { session.submit(editor: editor) } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(canSend ? Theme.accent : Color.black.opacity(0.12)))
                .scaleEffect(canSend ? 1 : 0.92)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .animation(InkyStyle.spring, value: canSend)
        .accessibilityLabel("Ask")
        .accessibilityIdentifier("inky.ask.send")
    }

    @ViewBuilder private var footerHint: some View {
        if editor.lassoRegion != nil {
            HStack(spacing: 6) {
                Label("Selected area", systemImage: "lasso")
                    .font(InkyStyle.voice(13, .semibold))
                    .foregroundStyle(Theme.accent)
                Button { editor.clearLasso() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.accent.opacity(0.45))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear selection")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(InkyStyle.tint))
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        } else if let error = session.speechInput.errorMessage {
            Text(error).font(InkyStyle.voice(13)).foregroundStyle(.red.opacity(0.8))
        } else {
            Label("Circle part of the page to point Inky at it", systemImage: "lasso")
                .font(InkyStyle.voice(13))
                .foregroundStyle(Theme.secondaryText)
                .labelStyle(InkyHintLabelStyle())
        }
    }

    private var canSend: Bool {
        !session.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct InkyHintLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 12, weight: .medium)).opacity(0.8)
            configuration.title
        }
    }
}

struct InkyFloatingButton: View {
    let state: InkyCharacterState
    /// Inky is out on the page; the button shows its empty seat.
    var isAway = false
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isAway {
                    InkyAwayDrop(size: 20)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    InkyCharacterView(state: state, size: 38)
                        .offset(y: 1)
                        .transition(.scale(scale: 0.5, anchor: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: 60, height: 60)
            .background(Circle().fill(Theme.surface).shadow(color: Theme.shadowColor, radius: 14, y: 5))
            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.5))
            .contentShape(Circle())
        }
        .buttonStyle(InkyPressStyle())
        .animation(InkyStyle.spring, value: isAway)
        .accessibilityLabel("Ask Inky")
        .accessibilityIdentifier("inky.summon")
    }
}

/// Buttons that squish slightly when pressed.
struct InkyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct InkyToastView: View {
    let toast: InkySession.Toast
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if toast.isError {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.red.opacity(0.75))
                    .frame(width: 28, height: 28)
            } else {
                InkyAvatar(state: .happy, size: 28)
            }
            Text(toast.text)
                .font(InkyStyle.voice(15, .medium))
                .foregroundStyle(Color.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("inky.toast.text")
        }
        .padding(.leading, 8)
        .padding(.trailing, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: 540)
        .inkySurface(cornerRadius: 24)
        .contentShape(Capsule())
        .onTapGesture(perform: onDismiss)
        .sensoryFeedback(toast.isError ? .warning : .success, trigger: toast.id)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Dismiss")
        .accessibilityIdentifier("inky.toast")
    }
}

/// Long explanations. Play button reads it aloud.
struct InkySidebarView: View {
    let content: InkySession.SidebarContent
    let speech: SpeechOutput
    let onClose: () -> Void

    private var isPlaying: Bool { speech.isSpeaking && !speech.isPaused }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                InkyAvatar(state: isPlaying ? .speaking : .idle, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Inky")
                        .font(InkyStyle.voice(17, .semibold))
                    Text(isPlaying ? "Reading aloud…" : "Explanation")
                        .font(InkyStyle.voice(13))
                        .foregroundStyle(Theme.secondaryText)
                        .contentTransition(.opacity)
                }
                Spacer()
                if content.speakable {
                    Button { speech.toggle(markdown: content.markdown) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 12, weight: .bold))
                                .contentTransition(.symbolEffect(.replace))
                            Text(isPlaying ? "Pause" : "Listen")
                                .font(InkyStyle.voice(14, .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Capsule().fill(Theme.accent))
                    }
                    .buttonStyle(InkyPressStyle())
                    .sensoryFeedback(.selection, trigger: isPlaying)
                    .accessibilityLabel(isPlaying ? "Pause" : "Read aloud")
                    .accessibilityIdentifier("inky.sidebar.play")
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.black.opacity(0.05)))
                }
                .buttonStyle(InkyPressStyle())
                .accessibilityLabel("Close")
                .accessibilityIdentifier("inky.sidebar.close")
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !content.question.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent.opacity(0.35)).frame(width: 3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("You asked")
                                    .font(InkyStyle.voice(11, .semibold))
                                    .textCase(.uppercase)
                                    .kerning(0.6)
                                    .foregroundStyle(Theme.secondaryText)
                                Text(content.question)
                                    .font(InkyStyle.voice(15))
                                    .foregroundStyle(Color.primary.opacity(0.75))
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    MarkdownView(markdown: content.markdown)
                        .lineSpacing(2)
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 400)
        .frame(maxHeight: .infinity)
        .background(Theme.surface)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inky.sidebar")
        .onDisappear { speech.stop() }
    }
}
