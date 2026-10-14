# Terminal accounts (Phase 4) — implementation plan

Goal: start Claude Code in a terminal **with a chosen account**, passing any `claude` flags, and open a **Warp tab coloured for that account**, with the colour chosen in TokenEater. Every account shares the **same `~/.claude`** (memory, `CLAUDE.md`, session history for `--resume` / `--continue`, settings, MCP servers, plugins, skills): switching account never loses context.

This replaces the earlier idea of one `CLAUDE_CONFIG_DIR` per account, which the user rejected because each account would get its own memory and history.

Builds on the multi-profile work (`docs/multi-profile-plan.md`). Monitoring is unchanged: the Accounts cards keep tracking usage; the terminal token below is a separate credential used only by terminals.

---

## 0. Verified facts

| Fact | Evidence |
|------|----------|
| `CLAUDE_CODE_OAUTH_TOKEN=<token> claude …` authenticates with that token and keeps the default config dir | `claude auth status` → `authMethod: "oauth_token"`, `configDirectory` / `projectsDirectory` unchanged (Claude Code 2.1.296, 2026-10-13) |
| `claude setup-token` issues a long-lived token for the account authorised **in the browser** | Binary strings (2.1.299): "long-lived (1-year) auth token", "Store this token securely. You won't be able to see it again.", "Use this token by setting: export CLAUDE_CODE_OAUTH_TOKEN=<token>"; prefix `sk-ant-oat01-` |
| A setup-token works for normal use | User test 2026-10-14: `CLAUDE_CODE_OAUTH_TOKEN=$T claude -p "di hola"` answered |
| `cc` is taken | `/usr/bin/cc` (the C compiler). Commands are named **`cla`** and **`claw`** (both free) |
| Keychain round-trip without prompts | `security -i` with `add-generic-password -U -a <user> -s <service> -X <hex>` on **stdin** (secret never in argv), then `security find-generic-password -a <user> -s <service> -w` reads it silently (item created by `/usr/bin/security`, so its ACL trusts it) |
| The shell can read the account signed in to `~/.claude` | `/usr/bin/plutil -extract oauthAccount.accountUuid raw -o - ~/.claude.json` |
| Argument handoff survives any characters | zsh `${(j: :)${(q)@}}` + `eval "args=( … )"` round-trips spaces, quotes, `$HOME`, `*`, empty strings (zsh 5.9) |
| Warp Tab Configs | `~/.warp/tab_configs/<stem>.toml`; keys `name`, `title`, `color` (`black red green yellow blue magenta cyan white`), `[[panes]]` with `id`, `type = "terminal"`, `directory`, `commands`; opened with `warp://tab_config/<stem>` (`?new_window=true` for a window). Parameters can only be filled in Warp's modal, **not** through the URI ([docs](https://docs.warp.dev/terminal/windows/tab-configs/), [URI scheme](https://docs.warp.dev/terminal/more-features/uri-scheme/)) |
| No shell escape sequence sets a Warp tab colour | Only the tab context menu, `/set-tab-color`, or a Tab Config's `color` ([Tabs](https://docs.warp.dev/terminal/windows/tabs/)) |

---

## 1. User-facing behaviour

### 1.1 Commands (zsh)

```
cla <account> [claude args…]            # Claude Code in THIS terminal with that account
claw [-w|--new-window] <account> [args…] # new Warp tab (or window) coloured for the account, same cwd
cla                                      # usage + list of accounts with token status
```

- `<account>` is the profile's **terminal name** (slug, e.g. `4gentic`, `lincyou`, `gpt`), completed with Tab.
- `cla 4gentic --resume`, `claw gpt --model opus -c`, `claw -w lincyou` all work: every argument after the account goes to `claude` unchanged.
- Token resolution in `cla`:
  1. the account's terminal token from the Keychain → `CLAUDE_CODE_OAUTH_TOKEN=<token> command claude "$@"`;
  2. no token, but the account is the one signed in to `~/.claude` (`oauthAccount.accountUuid`) → plain `command claude "$@"` (no env);
  3. otherwise: error `No terminal token for <account> - TokenEater → Settings → Accounts → <name> → Terminal`.
- `cla` sets the terminal title to `claude · <account>` (OSC 0).
- `claw` writes a **pending handoff** (cwd + quoted args, never the token) and opens `warp://tab_config/tokeneater_<account>`. The tab's command is `cla <account> --te-pending`, which consumes the handoff (≤ 120 s old, then deleted), `cd`s to the original directory and runs Claude with the original arguments. No handoff → plain `cla <account>` in the home directory.

### 1.2 TokenEater

- **Settings → Accounts → each card → new "Terminal" section**
  - Command: `cla <name>` with an editable name (validated, unique).
  - Warp tab colour: the 8 Warp colours as swatches; default derived from the profile colour.
  - Token: "Set token…" sheet (steps: sign in to claude.ai with *<email>* in the browser → run `claude setup-token` [copy button] → paste into a secure field); status "Set on <date> · valid until ~<date + 1 year>", "Expires in N days" warning under 14 days, "Replace…" / "Remove".
  - When the card's account is the one signed in to `~/.claude` and no token is set: hint "Without a token `cla <name>` uses the session of ~/.claude".
  - "Open in Warp" button (same as `claw <name>`, home directory).
- **Settings → General → new "Terminal integration" card**
  - Toggle "Generate `cla` / `claw` commands and Warp tabs" (off by default).
  - Shell status: "Loaded from ~/.zshrc ✓" or "Not installed" + **"Install in ~/.zshrc"** (adds a 3-line marked block; "Remove" undoes it).
  - Generated files (paths), "Regenerate now", two usage examples.

---

## 2. Data model (`Shared/Models`)

`AccountProfile` gains three optional fields (tolerant decoding, absent = nil):

```swift
var terminalName: String?        // slug; nil = TerminalName.suggested(from: name)
var warpColor: WarpTabColor?     // nil = WarpTabColor.default(forProfileHex: colorHex)
var terminalTokenSetAt: Date?    // when the user last stored a terminal token
```

`Shared/Models/TerminalAccounts.swift`:

```swift
enum WarpTabColor: String, Codable, CaseIterable, Identifiable {
    case black, red, green, yellow, blue, magenta, cyan, white
    var id: String { rawValue }
    var previewHex: String                      // swatch colour for the UI
    static func `default`(forProfileHex: String) -> WarpTabColor
}
// Preset mapping: #32CE6A→green, #60A5FA→blue, #A78BFA→magenta, #FFB347→yellow,
// #F87171→red, #2DD4BF→cyan, #F472B6→magenta, #FACC15→yellow; other hex → nearest hue
// (saturation < 0.15 → white / black by brightness).

enum TerminalName {
    static let pattern = "^[a-z0-9][a-z0-9-]{0,30}$"
    static func isValid(_ s: String) -> Bool
    static func suggested(from profileName: String) -> String   // lowercase, diacritics folded,
                                                                // non [a-z0-9] runs → "-", trimmed, ≤ 31, "account" if empty
    static func uniqued(_ candidate: String, taken: Set<String>) -> String  // "x", "x-2", "x-3", …
}

/// One row of the generated integration (pure value, what the generators consume).
struct TerminalAccountEntry: Equatable {
    let name: String            // slug
    let profileID: UUID
    let profileName: String
    let accountUUID: String?
    let warpColor: WarpTabColor
    let keychainService: String // TerminalTokenStore.service(for: profileID)
}

extension AccountProfile {
    var effectiveTerminalName: String       // terminalName ?? suggested
    var effectiveWarpColor: WarpTabColor    // warpColor ?? default(forProfileHex:)
    var terminalTokenExpiresAt: Date?       // terminalTokenSetAt + 365 days
}
```

---

## 3. Services (`Shared/Services`)

### 3.1 `TerminalTokenStore` + `Protocols/TerminalTokenStoreProtocol.swift`

```swift
protocol TerminalTokenStoreProtocol: Sendable {
    func save(token: String, profileID: UUID, profileName: String) throws
    func exists(profileID: UUID) -> Bool
    func delete(profileID: UUID)
}
enum TerminalTokenStoreError: Error, Equatable { case implausibleToken, writeFailed(String) }
```

- Service `TokenEater terminal token: <profile UUID>` (stable across renames), account `NSUserName()`, label `TokenEater terminal token (<profile name>)`.
- `save`: validates with `static func isPlausible(_:)` (trimmed, prefix `sk-ant-oat01-`, length ≥ 40, no whitespace), then runs `/usr/bin/security -i` and writes **on stdin** `add-generic-password -U -a "<acct>" -s "<service>" -l "<label>" -X <hex(token)>\n`. Values are double-quoted; `"`/`\`/control characters are removed from the label. 5 s watchdog; non-zero exit → `writeFailed(stderr)`. The token never appears in any argv.
- `exists`: `security find-generic-password -a <acct> -s <service>` (attributes only, no `-w`), exit 0.
- `delete`: `security delete-generic-password -a <acct> -s <service>`.
- TokenEater never reads the secret back (only the shell does).
- Process runner injectable: `typealias ProcessRunner = @Sendable (_ executable: String, _ arguments: [String], _ stdin: Data?, _ timeout: TimeInterval) throws -> (status: Int32, stdout: Data, stderr: String)`.

### 3.2 `TerminalIntegrationGenerator` (pure, `Shared/Helpers`)

```swift
enum TerminalIntegrationGenerator {
    static let marker = "Generated by TokenEater"
    static func tabConfigStem(for name: String) -> String          // "tokeneater_<name>"
    static func warpTabConfig(for entry: TerminalAccountEntry) -> String
    static func zshScript(for entries: [TerminalAccountEntry]) -> String
}
```

Tab Config (one per entry):

```toml
# Generated by TokenEater - overwritten whenever your accounts change.
name = "Claude · <profile name>"
title = "claude · <name>"
color = "<warp colour>"

[[panes]]
id = "main"
type = "terminal"
commands = ["cla <name> --te-pending"]
```

(TOML strings escaped: `\` and `"`; the profile name is free text.)

zsh script `~/.config/tokeneater/claude-accounts.zsh`:

- Header with the marker; `zmodload zsh/datetime` for `$EPOCHSECONDS`.
- Tables: `typeset -gA _te_service _te_account _te_label` filled per entry with **single-quoted** values (`'` escaped as `'\''`).
- Overridable binaries for tests: `${TOKENEATER_SECURITY_BIN:-/usr/bin/security}`, `${TOKENEATER_PLUTIL_BIN:-/usr/bin/plutil}`, `${TOKENEATER_CLAUDE_BIN:-claude}` (called through `command`), `${TOKENEATER_OPEN_BIN:-/usr/bin/open}`; pending dir `${TOKENEATER_PENDING_DIR:-$HOME/.config/tokeneater/pending}`; global config `${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}` else `$HOME/.claude.json`.
- `cla` / `claw` exactly as §1.1; `claw` writes the handoff with `umask 077`: line 1 `$EPOCHSECONDS`, line 2 `${(q)PWD}`, line 3 `${(j: :)${(q)@}}`; `cla --te-pending` reads it with `IFS= read -r`, `eval "args=( $line3 )"`, `cd -- ${(Q)line2}`, deletes it, ignores it when older than 120 s.
- Completion: `_te_cla() { compadd -- ${(k)_te_service} }` and `compdef _te_cla cla claw` only if `compdef` exists.
- Must pass `zsh -n`.

### 3.3 `TerminalIntegrationService` + protocol

```swift
protocol TerminalIntegrationServiceProtocol: Sendable {
    var scriptPath: String { get }
    var tabConfigDirectory: String { get }
    func regenerate(entries: [TerminalAccountEntry]) throws   // script + tab configs, prunes stale ones
    func removeGeneratedFiles() throws                         // script + every marked tokeneater_*.toml
    func shellIntegrationStatus() -> ShellIntegrationStatus    // .installed / .notInstalled / .noZshrc
    func installShellIntegration() throws
    func uninstallShellIntegration() throws
    var isWarpInstalled: Bool { get }
}
enum ShellIntegrationStatus: Equatable { case installed, notInstalled, noZshrc }
```

- `init(realHome:fileManager:warpAppPath:)`: base `~/.config/tokeneater/`, Warp dir `~/.warp/tab_configs/`, `~/.zshrc`; tests pass a temp "home".
- `regenerate`: creates dirs (pending dir `0700`), writes the script atomically (`0644`), writes every `tokeneater_<name>.toml`, deletes `tokeneater_*.toml` files **whose first line carries the marker** and are not in the set (user-made files are never touched). Skips Warp files when `~/.warp` does not exist.
- zshrc block (idempotent, appended with a leading newline):

```zsh
# >>> TokenEater terminal accounts >>>
[[ -f "$HOME/.config/tokeneater/claude-accounts.zsh" ]] && source "$HOME/.config/tokeneater/claude-accounts.zsh"
# <<< TokenEater terminal accounts <<<
```

  `uninstall` removes exactly the block. `.noZshrc` when the file does not exist (`install` then creates it).

---

## 4. `ProfileStore` wiring

New members (all `@MainActor`, errors through `ProfileStoreError` + `lastError`):

```swift
@Published private(set) var terminalIntegrationEnabled: Bool     // UserDefaults "terminalIntegration.enabled", default false
func setTerminalIntegrationEnabled(_ on: Bool)                   // on → regenerate; off → removeGeneratedFiles
func setTerminalName(_ id: UUID, _ name: String) throws          // normalised, valid, unique → .terminalNameInvalid / .terminalNameTaken
func setWarpColor(_ id: UUID, _ color: WarpTabColor)
func setTerminalToken(_ id: UUID, token: String) async throws    // TerminalTokenStore.save off the main thread → terminalTokenSetAt = now
func verifyTerminalTokens() async                                // clears terminalTokenSetAt when the Keychain item is gone (run at bootstrap)
func removeTerminalToken(_ id: UUID)
var terminalEntries: [TerminalAccountEntry] { get }              // every profile (pausing monitoring keeps the command), effective names/colours
func regenerateTerminalIntegration()                             // no-op when disabled; logs and records errors
var terminalTokenStore: TerminalTokenStoreProtocol               // injected (init param, default TerminalTokenStore())
var terminalIntegration: TerminalIntegrationServiceProtocol      // injected (init param, default TerminalIntegrationService())
```

- Every catalog mutation that persists (`insert`, `rename`, `setColor`, `setEnabled`, `remove`, the new setters) calls `regenerateTerminalIntegration()` after `persist()`.
- `remove` also deletes the profile's terminal token.
- `bootstrap` regenerates once when enabled, so the files always match the catalog after an upgrade.
- Names are made unique at read time too (`terminalEntries` resolves duplicates with `TerminalName.uniqued` in catalog order) so a stale catalog can never generate two identical commands.

---

## 5. UI (`TokenEaterApp`)

- `Settings/AccountsSectionView.swift` → `ProfileCard` gets a collapsible **Terminal** section (`DisclosureGroup`-like custom header in the card language), shown only when the integration is enabled; otherwise a single line "Enable terminal commands in Settings → General".
  - Name field: local `@State` draft, commit on Return/blur → `setTerminalName`; inline error.
  - Warp colour row: 8 swatches (`WarpTabColor.previewHex`), selected = ring.
  - Token status + buttons; **TerminalTokenSheet** (new file `Settings/TerminalTokenSheet.swift`): numbered steps, copy button for `claude setup-token`, `SecureField`, Save (disabled until `isPlausible`), errors inline. The sheet never logs or displays the token.
  - "Open in Warp": `NSWorkspace.shared.open(URL(string: "warp://tab_config/tokeneater_<name>")!)`, disabled when Warp is missing.
- `Settings/SettingsSectionView.swift` → new "Terminal integration" glass card (§1.2).
- Strings (EN + FR) in a `/* === terminal accounts === */` block.
- SwiftUI rules from `AGENTS.md` apply (no `@Observable`, no computed bindings, `@State` + `.onChange`).

---

## 6. Tests

- `TerminalAccountsModelTests`: preset colour mapping, nearest-hue fallback, slug suggestions (accents, spaces, symbols, empty), validity, uniqueness, profile decoding with/without the new fields.
- `TerminalTokenStoreTests` (fake runner): the token is in **stdin only**, never in argv; hex encoding; label sanitising; exists/delete argv; plausibility; write failure.
- `TerminalIntegrationGeneratorTests`: TOML content and escaping; script contains each entry with safe quoting (names with `'`, `"`, `$`); `zsh -n` passes on the generated script.
- `TerminalIntegrationShellTests` (runs `/bin/zsh` on the generated script with stub binaries through the `TOKENEATER_*` overrides): token → `CLAUDE_CODE_OAUTH_TOKEN` + args passed unchanged; no token + live account matches → no env; no token otherwise → error, claude not run; unknown account → usage; `claw` writes a handoff (no token inside) and calls `open` with the right URL (`?new_window=true` with `-w`); `--te-pending` consumes a fresh handoff (cwd + args) and ignores/deletes a stale one.
- `TerminalIntegrationServiceTests` (temp home): regenerate writes + prunes only marked files; remove; zshrc install/uninstall idempotent, `.noZshrc`.
- `ProfileStoreTerminalTests`: setters, uniqueness, token save/remove through mocks, regenerate calls on mutations, disabled = no writes.

---

## 7. Work breakdown

| Lane | Scope | Owns |
|------|-------|------|
| **P0 Foundation** (integrator) | §2 models, protocols of §3.1/§3.3, `ProfileStore` API of §4 with mocks wired and compiling bodies, strings skeleton | `Shared/Models/TerminalAccounts.swift`, `AccountProfile.swift`, protocols, mocks, `ProfileStore.swift` |
| **T1 Token store** | §3.1 implementation + tests | `Shared/Services/TerminalTokenStore.swift`, its tests |
| **T2 Generator + service** | §3.2, §3.3 + generator, shell and service tests | `Shared/Helpers/TerminalIntegrationGenerator.swift`, `Shared/Services/TerminalIntegrationService.swift`, tests |
| **T3 UI + store logic** | §4 bodies (beyond P0), §5 | `ProfileStore.swift` terminal section, `AccountsSectionView.swift`, `TerminalTokenSheet.swift`, `SettingsSectionView.swift`, strings, `ProfileStoreTerminalTests` |

T1, T2, T3 run in parallel after P0. Integration: merge, `xcodebuild test`, signed Release build, install keeping data, QA with the user:

1. Enable the integration, install in `~/.zshrc`, open a new terminal: `cla` lists the three accounts.
2. Set the 4gentic token (from `claude setup-token`); `cla 4gentic -p "hola"` answers with 4gentic; `cla lincyou` (no token, signed in to `~/.claude`) runs plain `claude`.
3. `claw gpt --model opus` from a project folder: a magenta Warp tab opens in that folder with the right account and flag.
4. Change a Warp colour / rename a command in TokenEater: the next `claw` reflects it; the old `tokeneater_*.toml` is gone.
5. `claude --continue` in a `cla 4gentic` terminal continues the last conversation from another account (shared `~/.claude`).
