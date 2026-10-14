import SwiftUI
import AppKit

/// Settings -> Accounts -> card -> Terminal -> "Set token…". Walks the user
/// through `claude setup-token` for the card's account and stores the result
/// in the Keychain through `ProfileStore.setTerminalToken` (see
/// `docs/terminal-accounts-plan.md` §5).
///
/// The token only ever lives in the `SecureField`'s local state: it is never
/// logged, printed or displayed, and the field is cleared on every exit path.
struct TerminalTokenSheet: View {
    let profile: AccountProfile
    /// Passed explicitly rather than read from the environment: the sheet is
    /// hosted outside the card's view tree.
    @ObservedObject var profileStore: ProfileStore
    @Binding var isPresented: Bool

    @State private var token = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var copied = false
    @FocusState private var fieldFocused: Bool

    private static let setupCommand = "claude setup-token"

    private var accent: Color { Color(hex: profile.colorHex) }

    private var commandName: String {
        profileStore.terminalName(for: profile.id) ?? profile.effectiveTerminalName
    }

    private var canSave: Bool {
        !isSaving && TerminalTokenFormat.isPlausible(token)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 16) {
                step(1) {
                    VStack(alignment: .leading, spacing: 6) {
                        inlineMarkdownText(String(
                            format: String(localized: "terminal.token.sheet.step1"),
                            profile.accountEmail ?? profile.name
                        ))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)

                        Button {
                            if let url = URL(string: "https://claude.ai") { NSWorkspace.shared.open(url) }
                        } label: {
                            HStack(spacing: 4) {
                                Text(String(localized: "terminal.token.sheet.openClaude"))
                                    .font(.system(size: 11, weight: .medium))
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }
                }

                step(2) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "terminal.token.sheet.step2"))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                        commandBox
                        Text(String(localized: "terminal.token.sheet.step2.hint"))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                step(3) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "terminal.token.sheet.step3"))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                        tokenField
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .padding(.top, 2)
                    Text(String(localized: "terminal.token.sheet.storage"))
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.white.opacity(0.4))

                footer
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
        .frame(width: 480)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.55))
        .interactiveDismissDisabled(isSaving)
        .onExitCommand { cancel() }
        .onDisappear { token = "" }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(accent)
                        .frame(width: 8, height: 8)
                        .shadow(color: accent.opacity(0.6), radius: 3)
                    Text(String(localized: "terminal.token.sheet.title"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                inlineMarkdownText(String(
                    format: String(localized: "terminal.token.sheet.subtitle"),
                    commandName, profile.name
                ))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    // MARK: Steps

    private func step<Content: View>(_ number: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(DS.Palette.accentSettings)
                .frame(width: 18, height: 18)
                .background(Circle().fill(DS.Palette.accentSettings.opacity(0.16)))
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var commandBox: some View {
        HStack(spacing: 8) {
            Text(Self.setupCommand)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.black.opacity(0.45))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(.white.opacity(0.06), lineWidth: 1)
                        )
                )

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.setupCommand, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(copied ? DS.Palette.semanticSuccess : .white.opacity(0.75))
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(.white.opacity(0.1), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .help(String(localized: "terminal.token.sheet.copy"))
        }
    }

    private var tokenField: some View {
        VStack(alignment: .leading, spacing: 4) {
            SecureField(String(localized: "terminal.token.sheet.placeholder"), text: $token)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($fieldFocused)
                .disabled(isSaving)
                .onSubmit { save() }
                // Ready for Cmd-V when the user comes back from the terminal.
                .onAppear { fieldFocused = true }
            // Shape hint only, never the value itself.
            if !token.isEmpty && !TerminalTokenFormat.isPlausible(token) {
                Text(String(localized: "terminal.token.sheet.format"))
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Palette.semanticWarning)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            if isSaving {
                ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                Text(String(localized: "terminal.token.sheet.saving"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            CardActionButton(
                title: String(localized: "terminal.token.sheet.cancel"),
                icon: "xmark",
                tint: .white,
                isEnabled: !isSaving
            ) {
                cancel()
            }
            .keyboardShortcut(.cancelAction)
            CardActionButton(
                title: String(localized: "terminal.token.sheet.save"),
                icon: "key.fill",
                tint: DS.Palette.accentSettings,
                isEnabled: canSave,
                isProminent: true
            ) {
                save()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Behaviour

    private func save() {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        let value = token
        Task {
            do {
                try await profileStore.setTerminalToken(profile.id, token: value)
                token = ""
                isPresented = false
            } catch {
                // `ProfileStoreError` descriptions never include the token.
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func cancel() {
        guard !isSaving else { return }
        token = ""
        isPresented = false
    }
}

/// Renders the inline Markdown of a localized string (`code`, **bold**) so
/// command names read as code. Falls back to the plain string.
func inlineMarkdownText(_ string: String) -> Text {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    if let attributed = try? AttributedString(markdown: string, options: options) {
        return Text(attributed)
    }
    return Text(verbatim: string)
}
