# Multi-profile support — implementation plan

Goal: TokenEater monitors **several Claude Code accounts at once** ("profiles", e.g. *Personal* and *Work*). Every enabled profile refreshes on its own schedule, without the user swapping the active `claude /login` on the machine. One profile is *active* (drives the menu bar, the popover and the dashboard hero); all profiles are visible side by side in a dashboard overview strip, in the popover switcher, and in per-profile widgets.

This document is the single source of truth for the work. It is written for the coding agents that implement each lane and for the maintainer merging them. Every section is prescriptive: types, signatures, file paths, behaviours, tests.

---

## 0. Verified facts the design relies on

Verified on 2026-09-05 against Claude Code 2.1.261 (PATH shim on `security` + `claude auth status`, and the binary itself).

| Fact | Value |
|------|-------|
| Keychain read used by Claude Code | `security find-generic-password -a <macOS username> -w -s "<service>"` |
| Service name, default config dir (`~/.claude`) | `Claude Code-credentials` |
| Service name, custom `CLAUDE_CONFIG_DIR=<dir>` | `Claude Code-credentials-<first 8 hex chars of sha256(<dir>)>` — hash of the absolute path string, **no trailing slash** (e.g. `/…/cfg-test` → `7719f642`) |
| Keychain write used by Claude Code | `security add-generic-password -U -a <user> -s <service> -X <hex(json)>` |
| File fallback | `<configDir>/.credentials.json`, same JSON as the keychain payload |
| Payload shape | `{"claudeAiOauth":{"accessToken","refreshToken","expiresAt"(epoch **ms**),"scopes":[…],"subscriptionType", …unknown keys}}` |
| OAuth refresh endpoint | `POST https://platform.claude.com/v1/oauth/token`, JSON body `{grant_type:"refresh_token", refresh_token, client_id:"9d1c250a-e61b-44d9-88ed-5944d1962f5e", scope:"user:inference user:profile"}` |
| Refresh response | `{access_token, refresh_token (optional → keep the old one), expires_in (seconds)}`; `expiresAt = now + expires_in` |
| Claude Code and external writes | Claude Code watches its credential store (file mtime / keychain version) and reloads on change, so a rotated token written back is picked up by running sessions. |
| Existing TokenEater behaviour to preserve | Default profile = live read of the default store, no self-refresh: when the token expires TokenEater shows "waiting for Claude Code" (`isAwaitingRefresh`, #218). This must stay the default for the migrated profile. |

Environment constraint: the development Mac has **no Xcode / xcodegen** (Command Line Tools only). See §7 for the validation loop that works here (SwiftPM harness for the test suite, `swiftc -typecheck` for the UI targets, GitHub Actions on the fork for Release builds and the widget).

---

## 1. Concepts and rules

### 1.1 Profile

An `AccountProfile` is a named Claude account TokenEater monitors. It has a **credential source**:

- `.claudeCode(configDir:)` — *linked* profile. Claude Code's own store for that config dir (`nil` = default `~/.claude`) holds the live credentials. TokenEater reads them (keychain via `/usr/bin/security`, then `<dir>/.credentials.json`, then — for the default dir only — the existing Claude Desktop `config.json` decryption path).
- `.managed` — *captured* profile. TokenEater copied the credentials (access + refresh token) into **its own** keychain item and is the only holder. Created by "Capture current login" while the user is logged into the other account.

Every profile keeps a copy of its latest known credentials in TokenEater's vault (its own keychain item, one per profile). For linked profiles the vault is a cache that is re-synced from the live store on every tick; for managed profiles it is the only copy.

### 1.2 Who renews the OAuth token (`TokenRenewalPolicy`)

| Source | Policy | Behaviour when the access token is expired / a 401 arrives |
|--------|--------|-----------------------------------------------------------|
| `.claudeCode` | `.claudeCode` (**default**) | Do nothing but re-read the live store; state `awaitingClaudeCode` ("waiting for Claude Code to refresh", identical to today). |
| `.claudeCode` | `.tokenEater` (opt-in toggle "Renew the token automatically") | TokenEater calls the refresh grant, stores the result in the vault **and writes it back** to the same backing store it was read from (keychain item or credentials file), so Claude Code keeps working with the rotated tokens. |
| `.managed` | `.tokenEater` (forced) | TokenEater refreshes and stores in the vault. Never writes to any Claude Code store. |

Owner-precedence rule (prevents two holders racing on one refresh-token chain): before self-refreshing, a provider re-reads the relevant live store; if it holds credentials of the **same chain** (same `refreshToken`, or same `accessToken`) that are newer, adopt them instead of refreshing. For managed profiles the "relevant live store" is the default `~/.claude` store (that is where the capture came from).

Refresh failures with HTTP 400/401 (`invalid_grant`) mark the profile `reauthRequired`: the UI asks the user to log in again with that account and re-capture / re-link. No automatic retry loop on that state.

### 1.3 Active profile and simultaneous monitoring

- `ProfileStore.activeProfileID` is app-wide: menu bar, popover content and the dashboard hero/tiles show the active profile. Switching is instant (context menu, popover switcher, dashboard strip, Settings).
- **All enabled profiles refresh independently** with their own `UsageStore` (own backoff, own rate-limit state, own pacing samples, own notifications). Auto-refresh loops start staggered (5 s apart) to avoid bursts.
- The dashboard's Monitoring space gets an **overview strip** with one compact card per enabled profile (5h ring, 7d value, state) so both accounts are visible at the same time.
- Widgets: each widget instance can be pinned to a profile (AppIntents configuration); unpinned widgets follow the active profile and keep working with older `shared.json` readers.

### 1.4 Migration (zero behaviour change for existing users)

On first launch after the upgrade, if `accountProfiles.v1` is absent and onboarding was completed (or a cached usage exists), `ProfileStore` creates one profile:
`{name: "Claude Code", source: .claudeCode(nil), renewalPolicy: .claudeCode, colorHex: "#32CE6A"}` and makes it active. Its pacing-sample key and notification keys stay the legacy, unsuffixed ones. Menu bar, popover and widgets render exactly as before until a second profile is added.

---

## 2. Data model (Shared/Models)

### 2.1 `Shared/Models/AccountProfile.swift`

```swift
enum ProfileCredentialSource: Codable, Equatable, Hashable {
    case claudeCode(configDir: String?)   // nil = default ~/.claude
    case managed
}

enum TokenRenewalPolicy: String, Codable { case claudeCode, tokenEater }

struct AccountProfile: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var colorHex: String                       // one of ProfilePalette.presets, default brand green
    var source: ProfileCredentialSource
    var renewalPolicy: TokenRenewalPolicy      // .managed always reads back as .tokenEater
    var isEnabled: Bool
    var createdAt: Date
    var accountEmail: String?                  // cached from /api/oauth/profile
    var accountUUID: String?
    var planTypeRaw: String?                   // PlanType.rawValue

    var effectiveRenewalPolicy: TokenRenewalPolicy   // .tokenEater when source == .managed
    var isLinked: Bool                                // source is .claudeCode
    var configDir: String?                            // associated value, nil for managed
    /// Path Claude Code actually uses: expands nil to "<realHome>/.claude". Uses getpwuid like the rest of Shared.
    func resolvedConfigDir(realHome: String) -> String
}

enum ProfilePalette {
    static let presets: [String] = ["#32CE6A", "#60A5FA", "#A78BFA", "#FFB347", "#F87171", "#2DD4BF", "#F472B6", "#FACC15"]
    static func next(after used: [String]) -> String   // first preset not in use, else cycles
}
```

Codable: tolerant custom `init(from:)` (missing/unknown fields fall back to defaults; unknown `source` case → decode failure of that profile only, the list decoder uses `decodeLossyArray`, see `LossyDecodableArray.swift`). `source` encodes as `{"kind":"claudeCode","configDir":"…"}` / `{"kind":"managed"}`.

### 2.2 `Shared/Models/OAuthCredentials.swift`

```swift
struct OAuthCredentials: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var scopes: [String]                 // default ["user:inference", "user:profile"]
    var subscriptionType: String?

    static let defaultScopes = ["user:inference", "user:profile"]
    func isExpired(now: Date = Date(), leeway: TimeInterval = 120) -> Bool   // false when expiresAt == nil
    func isSameChain(as other: OAuthCredentials) -> Bool  // refreshToken equal (both non-nil) || accessToken equal
    func isNewer(than other: OAuthCredentials) -> Bool    // expiresAt greater; nil expiresAt never newer
}

/// Claude Code's on-disk / keychain JSON shape. Round-trips unknown keys so a write-back never drops fields.
enum ClaudeCredentialsPayload {
    static func parse(_ data: Data) -> (credentials: OAuthCredentials, raw: [String: Any])?   // reads raw["claudeAiOauth"]
    static func parse(string: String) -> (credentials: OAuthCredentials, raw: [String: Any])?
    static func merge(_ credentials: OAuthCredentials, into raw: [String: Any]) -> Data      // updates only accessToken/refreshToken/expiresAt(ms)/scopes/subscriptionType inside claudeAiOauth
}
```

`expiresAt` is written as epoch milliseconds (`Int`), read tolerant of `Int`/`Double`.

### 2.3 Widget snapshot (`Shared/Models/SharedProfileSnapshot.swift`)

```swift
struct SharedProfileSnapshot: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var colorHex: String
    var isEnabled: Bool
    var planType: String?
    var cachedUsage: CachedUsage?
    var lastSyncDate: Date?
    var credentialState: String?     // ProfileCredentialState.rawKind for a stale/expired badge
}
```

### 2.4 Credential state (`Shared/Models/ProfileCredentialState.swift`)

```swift
enum ProfileCredentialState: Equatable {
    case unknown
    case missing                         // no store / no vault entry
    case ok(expiresAt: Date?)
    case expiringSoon(expiresAt: Date)   // < 30 min
    case awaitingClaudeCode              // expired, policy .claudeCode
    case reauthRequired(reason: String)  // refresh grant rejected, or managed without refresh token
    var rawKind: String                  // "ok" / "expiring" / "awaiting" / "reauth" / "missing" / "unknown"
    var isHealthy: Bool
}
```

`AppErrorState` (`Shared/Models/MetricModels.swift`) gains `case reauthRequired`. Consumers: `PopoverErrorBanner` (new copy `error.banner.reauthRequired` with a "Open Accounts" action), `DiagnosticReporter.errorStateName`, `MenuBarRenderer` (treated like `hasError`).

---

## 3. Services (Shared/Services)

### 3.1 `Shared/Helpers/ClaudeKeychainServiceName.swift`

```swift
enum ClaudeKeychainServiceName {
    static let base = "Claude Code-credentials"
    /// nil or the default dir → base; otherwise base + "-" + first 8 hex of SHA256(dir). `dir` is normalised: expand "~", standardize, strip trailing "/".
    static func service(forConfigDir dir: String?, realHome: String) -> String
    static func isDefaultDir(_ dir: String?, realHome: String) -> Bool
}
```
CryptoKit `SHA256`. Tests: default nil, default explicit path, custom path, trailing slash equivalence, known vector `/private/tmp/…/cfg-test → 7719f642`-style computed in test with CryptoKit.

### 3.2 Readers/writers for Claude Code's store

`SecurityCLIReader` (existing) gains `func readPayload() -> String?` (raw `-w` output; `readToken()` becomes `readPayload().flatMap(extractToken)`), keeps its 3 s watchdog. Protocol `SecurityCLIReaderProtocol` gains `readPayload()`; `MockSecurityCLIReader` gains `payload: String?`.

`CredentialsFileReader` (existing) gains `func readPayload() -> Data?`; protocol + mock updated likewise.

New `Shared/Services/ClaudeCodeCredentialStore.swift` + `Protocols/ClaudeCodeCredentialStoreProtocol.swift`:

```swift
enum ClaudeCodeCredentialBacking: Equatable { case keychain(service: String), file(path: String), claudeDesktop }

struct ClaudeCodeCredentialRead {
    let credentials: OAuthCredentials
    let raw: [String: Any]                   // for merge-preserving write-back ([:] for claudeDesktop)
    let backing: ClaudeCodeCredentialBacking
}

protocol ClaudeCodeCredentialStoreProtocol: Sendable {
    func read(configDir: String?) -> ClaudeCodeCredentialRead?
    func exists(configDir: String?) -> Bool
    /// Writes to the SAME backing the read came from. Throws ClaudeCodeCredentialStoreError.
    func write(_ credentials: OAuthCredentials, raw: [String: Any], backing: ClaudeCodeCredentialBacking) throws
}
```

Implementation:
- `read`: service = `ClaudeKeychainServiceName.service(forConfigDir:)`; `SecurityCLIReader(service:)`.readPayload → parse; else `CredentialsFileReader(filePath: dir + "/.credentials.json")`; else (default dir only) `ClaudeConfigReader` + `ElectronDecryptionService` (token-only credentials, backing `.claudeDesktop`, `refreshToken == nil`). Readers are created per call through injectable factories `(String) -> SecurityCLIReaderProtocol` and `(String) -> CredentialsFileReaderProtocol` so tests inject mocks.
- `write(.keychain)`: `/usr/bin/security add-generic-password -U -a <NSUserName()> -s <service> -X <hex(payload)>` through `Process` with the same watchdog pattern (5 s). Exit code ≠ 0 → throw.
- `write(.file)`: atomic write, `chmod 0600`, only if the file already exists.
- `write(.claudeDesktop)`: throws `.readOnlyBacking`.
- All I/O off the main thread is the caller's responsibility (same as today: `SecurityCLIReader` can block up to 3 s).

### 3.3 `Shared/Services/ProfileCredentialVault.swift` + protocol

```swift
protocol ProfileCredentialVaultProtocol: Sendable {
    func load(profileID: UUID) -> OAuthCredentials?
    func save(_ credentials: OAuthCredentials, profileID: UUID) throws
    func delete(profileID: UUID)
}
```
Keychain generic password: service `com.tokeneater.profile-credentials`, account `profileID.uuidString`, label `TokenEater profile credentials`, `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, data = `JSONEncoder` of `OAuthCredentials`. `SecItemCopyMatching` → update with `SecItemUpdate`, else `SecItemAdd`. Never prompts (items created by us). Test mock: `InMemoryProfileCredentialVault`.

### 3.4 `Shared/Services/OAuthTokenRefresher.swift` + protocol

```swift
enum OAuthRefreshError: Error, Equatable {
    case noRefreshToken
    case invalidGrant(status: Int, body: String)   // 400 / 401
    case http(status: Int)
    case network(String)
    case invalidResponse
}
protocol OAuthTokenRefresherProtocol: Sendable {
    func refresh(_ credentials: OAuthCredentials, proxyConfig: ProxyConfig?) async throws -> OAuthCredentials
}
```
- `URLSessionFactory.make(proxyConfig:)` extracted from `APIClient.session(proxyConfig:)` into `Shared/Services/URLSessionFactory.swift`; `APIClient` uses it too.
- Request: POST, `Content-Type: application/json`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/<version>` (reuse `ProcessResolver.detectClaudeCodeVersion()` as `APIClient` does), timeout 30 s, body as in §0.
- Response 200 → `OAuthCredentials(accessToken: access_token, refreshToken: refresh_token ?? old, expiresAt: now + expires_in, scopes: old scopes, subscriptionType: old)`.
- Transport injected as `typealias HTTPTransport = @Sendable (URLRequest, ProxyConfig?) async throws -> (Data, HTTPURLResponse)` (default = URLSession) so tests need no network.
- Single-flight: an internal actor keyed by `refreshToken` so two callers sharing a token wait for one request.

### 3.5 `Shared/Services/ProfileTokenProvider.swift`

Conforms to `TokenProviderProtocol`, which gains two members with **default implementations** (protocol extension) so the legacy `TokenProvider` and `MockTokenProvider` keep compiling:

```swift
enum TokenReadiness: Equatable { case ready, awaitingClaudeCode, reauthRequired, missing }

protocol TokenProviderProtocol: Sendable {
    // existing members unchanged …
    /// Adopt newer live credentials; renew when expired and allowed. Called by UsageStore before every fetch and after a 401 (force = true).
    func ensureFreshToken(force: Bool) async -> TokenReadiness          // default: .ready
    var credentialState: ProfileCredentialState { get }                 // default: .unknown
}
```

```swift
final class ProfileTokenProvider: TokenProviderProtocol, @unchecked Sendable {
    init(profile: AccountProfile,
         vault: ProfileCredentialVaultProtocol,
         store: ClaudeCodeCredentialStoreProtocol,
         refresher: OAuthTokenRefresherProtocol,
         proxyProvider: @escaping @Sendable () -> ProxyConfig?,
         realHome: String = <getpwuid>,
         now: @escaping @Sendable () -> Date = Date.init)
    func update(profile: AccountProfile)            // policy / name changes at runtime
    private(set) var credentialState: ProfileCredentialState
    private(set) var lastRead: ClaudeCodeCredentialRead?
}
```
State guarded by an `NSLock`; `ensureFreshToken` serialises through an internal `AsyncSerialQueue` (one in-flight per provider).

Algorithm of `ensureFreshToken(force:)`:
1. `cached = cached ?? vault.load(id)`.
2. `live = profile.isLinked ? store.read(profile.configDir) : (profile.source == .managed ? store.read(nil) : nil)`.
3. Adopt when `live != nil` and (`cached == nil` || (profile.isLinked && live.accessToken != cached.accessToken) || (managed && live.isSameChain(cached) && live.isNewer(than: cached))): `cached = live; vault.save`. For managed profiles a live read whose chain differs is ignored (that is another account).
4. `guard let cached else { state = .missing; return .missing }`.
5. `let expired = force || cached.isExpired(now)`. If `!expired` → state `.ok/.expiringSoon`; return `.ready`.
6. If `profile.effectiveRenewalPolicy == .claudeCode` → state `.awaitingClaudeCode`; return `.awaitingClaudeCode`.
7. `guard cached.refreshToken != nil` else state `.reauthRequired("noRefreshToken")`; return `.reauthRequired`.
8. `new = try await refresher.refresh(cached, proxy)`; on `.invalidGrant` → `.reauthRequired`; on `.network/.http` → keep `cached`, state unchanged, return `.ready` if not expired else `.awaitingClaudeCode` (transient; caller's normal 401 path handles it).
9. `vault.save(new)`, `cached = new`; if linked && policy `.tokenEater` && `lastRead?.backing` writable → `try? store.write(new, raw: lastRead.raw, backing:)` (log on failure, do not fail the refresh). Return `.ready`.

Other members: `currentToken()` → `cached?.accessToken` (loads vault / live once when nil, synchronous, no network). `hasTokenSource()` → linked: `store.exists`; managed: `vault.load != nil`. `invalidateToken()` → sets `forceNext = true` (cache is kept: for managed profiles it is the only copy). `refreshTokenIfChanged()` → step 2–3 only; returns true when the access token changed (keeps the existing account-swap semantics that `UsageStore.reconcileTokenIfChanged` relies on). `bootstrap()` → default linked profile: delegate to legacy `TokenProvider().bootstrap()`; others no-op. `isBootstrapped` → true.

### 3.6 `SharedFileService` (widget bridge)

`SharedData` gains `profiles: [SharedProfileSnapshot]?` and `activeProfileID: String?`. Protocol additions:

```swift
var profileSnapshots: [SharedProfileSnapshot] { get }
var activeProfileID: UUID? { get }
func updateProfileCatalog(_ profiles: [SharedProfileSnapshot], activeProfileID: UUID?)   // replaces names/colors/enabled/plan, keeps each entry's cachedUsage/lastSyncDate
func updateProfileUsage(profileID: UUID, usage: CachedUsage, syncDate: Date, credentialState: String?)
func removeProfile(id: UUID)
```
`updateAfterSync` (legacy top-level `cachedUsage`) keeps existing semantics and is written **only by the active profile's** repository, so older widget code and `isConfigured` keep working. Add `init(rootDirectory: URL?)` (nil = current behaviour) so tests write to a temp dir. `MockSharedFileService` mirrors the new members.

`UsageRepository` gains `profileID: UUID?` and `isActive: @Sendable () -> Bool` (default `{ true }`): `refreshUsage` writes `updateProfileUsage` when `profileID != nil` and additionally `updateAfterSync` when `isActive()`.

### 3.7 `NotificationService` scope

```swift
struct NotificationScope: Sendable {
    let profileID: UUID?                      // nil = legacy/unsuffixed keys and ids
    let displayName: @Sendable () -> String?  // nil → no title prefix
    static let legacy = NotificationScope(profileID: nil, displayName: { nil })
}
init(center:stateStore:scope: NotificationScope = .legacy)
```
- State keys: `lastLevel_fiveHour` → `lastLevel_fiveHour_<uuid>` when `profileID != nil` (same for `lastPacing_*`, `lastResetsAt_*`, `lastLevel_extra`, `lastTokenExpiredFiredAt`). `NotificationStateStore` gets `tokenExpiredFiredAt(forKey:)` / `setTokenExpiredFiredAt(_:forKey:)` with the old two kept as forwarding defaults.
- Request identifiers: `escalation_fiveHour` → `escalation_fiveHour_<uuid>`, `reminder_session` → `reminder_session_<uuid>`, etc. `removePending` uses the scoped ids.
- Title prefix: when `displayName()` returns a name, titles become `"[<name>] " + title`. `ProfileStore` supplies `{ profiles.count > 1 ? profile.name : nil }`.
- Vendor-health notifications stay global (unchanged).

### 3.8 `TokenFileMonitor`

`init(debounceInterval:watchedFiles: [(directory: String, filename: String)])`; the old `init()` builds the legacy two entries. Protocol gains nothing. `ProfileStore.watchedCredentialFiles` lists `<configDir>/.credentials.json` for every linked profile plus the two legacy entries; `StatusBarController` rebuilds the monitor when the profile list changes.

---

## 4. Stores

### 4.1 `Shared/Stores/ProfileStore.swift` (`@MainActor final class ProfileStore: ObservableObject`)

```swift
@Published private(set) var profiles: [AccountProfile]
@Published var activeProfileID: UUID                   // persisted "activeProfileID"
@Published private(set) var credentialStates: [UUID: ProfileCredentialState]
@Published private(set) var lastError: ProfileStoreError?

var enabledProfiles: [AccountProfile]
var activeProfile: AccountProfile
var activeUsageStore: UsageStore
func usageStore(for id: UUID) -> UsageStore?
var isMultiProfile: Bool                               // profiles.count > 1
var watchedCredentialFiles: [(directory: String, filename: String)]

init(persistence: ProfilePersistenceProtocol = UserDefaultsProfilePersistence(),
     vault: ProfileCredentialVaultProtocol = ProfileCredentialVault(),
     credentialStore: ClaudeCodeCredentialStoreProtocol = ClaudeCodeCredentialStore(),
     refresher: OAuthTokenRefresherProtocol = OAuthTokenRefresher(),
     sharedFileService: SharedFileServiceProtocol = SharedFileService(),
     identityClient: APIClientProtocol = APIClient(),
     usageStoreFactory: ((AccountProfile, ProfileTokenProvider) -> UsageStore)? = nil,   // nil = production factory
     legacyHasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"))

// mutations
func ensureDefaultProfileIfNeeded()                                       // §1.4
func addLinkedProfile(name: String, configDir: String?) async throws -> AccountProfile
func captureCurrentLogin(name: String) async throws -> AccountProfile
func rename(_ id: UUID, to: String)
func setColor(_ id: UUID, hex: String)
func setEnabled(_ id: UUID, _ enabled: Bool)
func setRenewalPolicy(_ id: UUID, _ policy: TokenRenewalPolicy)
func remove(_ id: UUID) throws                                            // .cannotRemoveLast
func move(fromOffsets: IndexSet, toOffset: Int)
func setActive(_ id: UUID)

// lifecycle (called by StatusBarController)
func bootstrap(configure: @escaping (UsageStore) -> Void, thresholds: UsageThresholds)   // stores configurator; reloadConfig + startAutoRefresh(initialDelay: i*5) per enabled profile
func stopAll()
func refreshAll(force: Bool) async
func handleTokenChange()                                                  // every store: handleTokenChange + refresh(force: true)
func refreshIfStaleAll() async
```

Rules:
- Persistence: JSON under `UserDefaults` key `accountProfiles.v1` (array) + `activeProfileID`. `ProfilePersistenceProtocol { load() -> [AccountProfile]; save(_:) ; activeID; setActiveID }` with an in-memory mock.
- One `UsageStore` per profile, created lazily by the factory and kept in `usageStores: [UUID: UsageStore]`; each store's `objectWillChange` is relayed to `ProfileStore.objectWillChange` (Combine sink, same pattern as `SettingsStore` relays), and its `credentialState` mirrored into `credentialStates` after each `refresh` (UsageStore publishes it).
- `addLinkedProfile`: validates the directory exists and `credentialStore.exists`; rejects a duplicate config dir; reads live credentials, seeds the vault, then fetches `/api/oauth/profile` once (`identityClient.fetchProfile`) to fill `accountEmail/accountUUID/planTypeRaw`; rejects when `accountUUID` matches an existing profile (`.duplicateAccount(existingName)`). The profile is inserted enabled, configured with the stored configurator, and its store started.
- `captureCurrentLogin`: reads the default store; requires `refreshToken != nil` (`.noRefreshToken`, e.g. Claude Desktop-only users); saves to the vault under the new id; source `.managed`, policy `.tokenEater`; identity fetch + duplicate check as above.
- `remove`: stops the store, `vault.delete`, `sharedFileService.removeProfile`, drops notification pending requests for that scope, re-targets `activeProfileID` to the first remaining profile.
- After every mutation: `persist()`, `syncCatalogToSharedFile()` (`updateProfileCatalog`), `WidgetReloader.scheduleReload()`.
- `setActive`: persists, calls `sharedFileService.updateProfileCatalog` (new active id) **and** writes the active profile's last usage through `updateAfterSync` so legacy widgets flip immediately, then reloads widgets.
- One-shot UX hook: when the profile count goes from 1 to 2, post `Notification.Name.profilesBecameMultiple` — `SettingsStore` observes it and inserts a `profileSwitcher` element at the top of `popoverComposition` if absent (guarded by `UserDefaults` flag `didAutoInsertProfileSwitcher`).

### 4.2 `UsageStore` changes (`Shared/Stores/UsageStore.swift`)

- `init(..., profileID: UUID? = nil)`; `sessionSamplesKey = profileID.map { "sessionPacingSamples.\($0.uuidString)" } ?? "sessionPacingSamples"`. (The migrated default profile is created with `profileID` but flagged `usesLegacyKeys: Bool = true` so its key stays `sessionPacingSamples`; pass `legacyKeys: true` from the factory for the default profile.)
- `@Published private(set) var credentialState: ProfileCredentialState = .unknown` (mirrors the provider after every `refresh`, `reloadConfig`, `ensureFreshToken`).
- `refresh(thresholds:force:)`: after the `isLoading` guard, `let readiness = await tokenProvider.ensureFreshToken(force: false)`; map: `.missing` → `hasConfig = false; errorState = .tokenUnavailable; return`; `.awaitingClaudeCode` → `hasConfig = true; errorState = .tokenUnavailable; return` (this is exactly today's "waiting" state, `isAwaitingRefresh` stays true when a snapshot exists); `.reauthRequired` → `errorState = .reauthRequired; notify token expired; return`; `.ready` → continue. Existing 401 branch becomes: `invalidateToken()`, `let r = await ensureFreshToken(force: true)`, if `r == .ready`, retry once with `currentToken()`; otherwise map as above.
- `startAutoRefresh(interval:thresholds:initialDelay: TimeInterval = 0)` — sleeps `initialDelay` before the loop.
- Everything else (pacing, notifications, widgets reload, backoff) unchanged.

### 4.3 `UsageStoreConfigurator` (`TokenEaterApp/App/UsageStoreConfigurator.swift`)

Pure function extracted from `StatusBarController.bootstrapRefresh`: applies `proxyConfig`, `pacingMargin`, `pacingSchedule`, `refreshIntervalSeconds`, `notifTogglesProvider` to a `UsageStore`. `StatusBarController` passes it to `ProfileStore.bootstrap(configure:)`; the settings observers (`pacing.$margin`, schedule publishers, `$refreshInterval`) iterate `profileStore.usageStores.values`.

### 4.4 `SettingsStore`

- `SettingsSection` gains `case accounts` (between `general` and `pacing`), label key `sidebar.accounts`, icon `person.2.crop.square.stack.fill`. `NavigationTarget.parse("settings.accounts")` works through `rawValue`.
- Observes `.profilesBecameMultiple` for the one-shot popover insertion (§4.1).
- `credentialsTokenExists()` stays on the legacy provider (only used by the old Re-detect button, which moves to the Accounts section).

---

## 5. UI

### 5.1 App wiring (`TokenEaterApp/App`)

- `TokenEaterApp.init`: construct `ProfileStore` instead of `UsageStore`; `AppDelegate.profileStore`. `ProfileStore.ensureDefaultProfileIfNeeded()` runs in `init` (needs `hasCompletedOnboarding`, read straight from `UserDefaults` to avoid store ordering issues).
- `StatusBarController(profileStore:…)`: `usageStore` call sites → `profileStore.activeUsageStore`; `observeStoreChanges` merges `profileStore.objectWillChange` (covers every child store) and `profileStore.$activeProfileID`; `bootstrapRefresh` → `profileStore.bootstrap(configure:thresholds:)`; token-file monitor built from `profileStore.watchedCredentialFiles` and rebuilt on `$profiles` change; wake handler → `refreshIfStaleAll`; onboarding completion → `ensureDefaultProfileIfNeeded()` then bootstrap.
- New `ActiveProfileHost<Content>` view (`TokenEaterApp/App/ActiveProfileHost.swift`): reads `@EnvironmentObject profileStore` and re-injects `.environmentObject(profileStore.activeUsageStore).id(profileStore.activeProfileID)`. Used in `installPopoverContent` and `showDashboard`, so every existing `@EnvironmentObject var usageStore: UsageStore` keeps working unchanged (35 call sites in `MonitoringView` untouched). Also inject `profileStore` itself at both roots.
- Context menu: new "Account" submenu (radio items for enabled profiles → `setActive`), shown only when `isMultiProfile`; "Refresh now" → `refreshAll(force: true)`.
- `DiagnosticReporter.makeReport(profileStore:settingsStore:)` adds a `**Profiles**` section: per profile `name (redacted to initial + count), source kind, backing, renewal policy, credential state, expiresAt (relative), error state, speed, retry-after`. No tokens, emails or paths beyond the config dir's last path component.
- `MenuBarRenderDataBuilder.live(...)` takes the active store plus `profileLabel`/`profileColorHex` (nil when not multi-profile).

### 5.2 Settings → Accounts (`TokenEaterApp/Settings/AccountsSectionView.swift`)

Follows `SettingsSectionView` idioms (`sectionTitle`, `glassCard`, `cardLabel`, `darkToggle`, `DS` tokens, `.plain` buttons, `@State` + `.onChange` instead of computed bindings).

- Header: title `sidebar.accounts`, subtitle `sidebar.accounts.subtitle`.
- One `ProfileCard` per profile (`@ObservedObject var usage: UsageStore` child view): colour dot + name (double-click or pencil → inline `TextField` with `@State` draft), source line (`Claude Code · ~/.claude`, `Claude Code · ~/.claude-work`, `Captured login`), identity line (email · plan badge via `PlanType.badgeColor`), status chip from `credentialState`/`errorState` (Connected / Expiring / Waiting for Claude Code / Re-auth needed / Rate limited / Disabled), mini values `5h 42% · 7d 65%`, colour picker row (8 preset swatches), toggles: *Enabled*, *Renew token automatically* (linked only, with hint `accounts.renew.hint` explaining the write-back), buttons: *Set active* (hidden when active), *Refresh*, *Remove* (confirmation alert; disabled for the last profile).
- Add card with two actions:
  - *Link a Claude Code config directory…* → `NSOpenPanel` (directories only, `~` default) + a "Detected" list of candidates (`~/.claude`, `~/.claude-*`, `~/.config/claude*` that contain `.claude.json` or a keychain item) → name field → `addLinkedProfile`.
  - *Capture the current login…* → sheet with 3 steps copy (`accounts.capture.step1/2/3`: log in with the other account in a terminal, click Capture, log back in), name field → `captureCurrentLogin`.
  - Errors from `ProfileStoreError` rendered inline (`accounts.error.duplicate`, `.noRefreshToken`, `.notFound`, `.cannotRemoveLast`, `.identityFailed`).
- `SettingsSectionView` Connection card is replaced by a compact summary row ("N accounts · active: <name>") with a button that posts `.navigateToSection` `settings.accounts`.

### 5.3 Monitoring overview strip (`TokenEaterApp/Windows/Monitoring/ProfilesOverviewStrip.swift`)

Rendered by `MonitoringView` right under `header` when `profileStore.isMultiProfile`. Horizontal `HStack` of `ProfileOverviewCard(profile:usage:)` cards (`@ObservedObject usage`): colour dot + name, small `RingGauge` (44 pt) with 5h %, `7d 65%` text, state glyph (`clock.arrow.circlepath` waiting, `exclamationmark.triangle.fill` re-auth, `icloud.slash` rate limited), highlighted border in the profile colour when active. Tap → `profileStore.setActive`. Colours for the ring go through `GaugeColorResolver` with the profile's usage data so they match the tiles. Uses `dsGlass`, `DS.Motion.springSnap`, `CardPressStyle`.

### 5.4 Popover switcher element

- `PopoverElementKind.profileSwitcher` (family `.utility`, `allowedStyles: [.utilityRow]`, full width only, not chrome). Presence gate in `PopoverMetricResolver.isAvailable`: needs `ProfileStore.isMultiProfile` → the resolver gains an optional `profiles: ProfileStore?` parameter; `PopoverGrid` passes its environment object. Editor label `popoverElement.profileSwitcher`, symbol `person.2.crop.square.stack.fill`.
- `PopoverProfileSwitcherCell` (`TokenEaterApp/Popover/PopoverCells.swift`): capsule chips (dot + name + 5h %), active chip filled with the profile colour at 0.22 opacity; tap → `setActive`. Because the popover root is `ActiveProfileHost` keyed by the active id, the rest of the popover re-renders with the new store.
- `PopoverCompositionModelsTests` matrix updated; `PopoverConfigMigrator` untouched (new kind never comes from legacy blobs).

### 5.5 Menu bar profile label segment

- `MenuBarSegmentKind.profileLabel` (family `.status`, styles `[.text, .pill]`, `isPresenceGated == true`, symbol `person.crop.circle`), rendered by `MenuBarRenderer` as the profile's short name (first 8 chars) in `.text`, or a capsule tinted with `profileColorHex` in `.pill`. `RenderData` gains `profileLabel: String?`, `profileColorHex: String?`; the segment draws nothing when `profileLabel == nil` (single profile). Editor labels `menuBarSegment.profileLabel`.

### 5.6 Widgets (`TokenEaterWidget`)

- `UsageEntry` gains `profileName: String?`, `profileColorHex: String?`.
- New `TokenEaterWidget/ProfileSelectionIntent.swift`: `struct ProfileEntity: AppEntity` (id, name, colorHex; `defaultQuery = ProfileEntityQuery`) whose query lists `SharedFileService().profileSnapshots`; `struct SelectProfileIntent: WidgetConfigurationIntent` with `@Parameter(title: "Account") var profile: ProfileEntity?`.
- `ProfileTimelineProvider: AppIntentTimelineProvider` (same logic as `StaticProvider.fetchEntry`, but resolves `configuration.profile?.id` → that snapshot's `cachedUsage`; nil → active/legacy `cachedUsage`).
- `TokenEaterWidget` (Overview), `SessionRingWidget`, `PacingWidget` switch to `AppIntentConfiguration(kind:intent:provider:)`; the other kinds keep `StaticProvider` (active profile). Placed widgets keep working: a nil parameter means "active".
- `WidgetHeader` accessory shows the profile name (uppercase micro font, tinted dot) when `entry.profileName != nil`.
- `WidgetReloader` reloads all six kinds (add the four missing kinds to `scheduleReload`).
- Cannot be rendered on the dev Mac: validated by the CI Release build plus a manual pass on a machine with Xcode (§7.3).

### 5.7 Onboarding

No visual change. `OnboardingViewModel` keeps testing the default store. Completion → `StatusBarController.observeOnboardingForRefresh` → `profileStore.ensureDefaultProfileIfNeeded()` → bootstrap.

### 5.8 Localization

Every lane appends its keys to **both** `Shared/en.lproj/Localizable.strings` and `Shared/fr.lproj/Localizable.strings` inside a delimited block:

```
/* === multi-profile: <lane> === */
…
/* === end multi-profile: <lane> === */
```
Key families: `sidebar.accounts`, `sidebar.accounts.subtitle`, `accounts.*` (cards, actions, capture steps, errors, hints), `profile.state.*` (ok, expiring, awaiting, reauth, missing, disabled), `popoverElement.profileSwitcher`, `menuBarSegment.profileLabel`, `contextmenu.account`, `error.banner.reauthRequired`, `error.banner.reauthRequired.action`, `widget.profile.title`, `widget.profile.param`, `dashboard.profiles.overview`, `notif.prefix.profile` (unused if the `[Name]` prefix is composed in code).

---

## 6. Work breakdown

Branching: integration branch `feat/multi-profile` on the fork (`gerar2/TokenEater`), created from `main` (`4b3869b`). Each lane works in its own git worktree on `feat/mp-<lane>` branched from the integration branch **after Phase 0 lands**; lanes are merged back into `feat/multi-profile` by the integrator, who then opens a single PR to `main`.

Conflict policy: lanes own disjoint files (listed below). Shared touch points are `Localizable.strings` (delimited blocks, trivial merges), `MockSharedFileService` / `MockTokenProvider` (Phase 0 adds every new member up-front so lanes only *use* them), and `project.yml` (no change needed: sources are directory-based).

### Phase 0 — Foundation (sequential, integrator)

`feat/mp-foundation`: everything in §2, the protocols in §3 (`ClaudeKeychainServiceName`, `ClaudeCodeCredentialStoreProtocol`, `ProfileCredentialVaultProtocol`, `OAuthTokenRefresherProtocol`, `TokenProviderProtocol` extension defaults, `SharedFileServiceProtocol` additions with stub implementations in `SharedFileService` and `MockSharedFileService`), `ProfileCredentialState`, `AppErrorState.reauthRequired` (+ exhaustive switch fixes), a compilable `ProfileStore` skeleton exposing the full public API of §4.1 with `fatalError`-free placeholder bodies, `UsageStore(profileID:)` + `credentialState` + `initialDelay` signature only, `SettingsSection.accounts` case + placeholder `AccountsSectionView` ("coming soon" label), `MenuBarSegmentKind.profileLabel` + `PopoverElementKind.profileSwitcher` cases with rendering that draws nothing, mocks (`MockClaudeCodeCredentialStore`, `InMemoryProfileCredentialVault`, `MockOAuthTokenRefresher`, `InMemoryProfilePersistence`), and model tests (`AccountProfileTests`, `OAuthCredentialsTests`, `ClaudeKeychainServiceNameTests`). Must pass `swift test` + both typechecks before lanes start.

### Phase 1 — parallel lanes (agents, worktrees)

| Lane | Branch | Scope (sections) | Owns files | Tests |
|------|--------|------------------|-----------|-------|
| **L1 Credentials** | `feat/mp-credentials` | §3.1–3.5 implementations: `SecurityCLIReader.readPayload`, `CredentialsFileReader.readPayload`, `ClaudeCodeCredentialStore`, `ProfileCredentialVault`, `URLSessionFactory`, `OAuthTokenRefresher`, `ProfileTokenProvider` | `Shared/Services/{ClaudeCodeCredentialStore,ProfileCredentialVault,OAuthTokenRefresher,ProfileTokenProvider,URLSessionFactory,SecurityCLIReader,CredentialsFileReader,APIClient}.swift`, matching mocks | `ClaudeCredentialsPayloadTests` (merge keeps unknown keys, ms round-trip), `OAuthTokenRefresherTests` (200 with/without rotated RT, 400/401 → invalidGrant, 500, network), `ProfileTokenProviderTests` (matrix of §3.5: adopt newer live, managed self-refresh, linked awaiting, linked auto-renew + write-back, dedupe same chain, invalidGrant → reauth, transient error keeps cache, `refreshTokenIfChanged` semantics), `ClaudeCodeCredentialStoreTests` (reader fallback order, write-back to file with 0600, keychain arg building via injected process runner) |
| **L2 Stores** | `feat/mp-stores` | §4.1 `ProfileStore` full implementation, §4.2 `UsageStore` refresh flow, §3.6 `UsageRepository` per-profile writes, §3.8 `TokenFileMonitor(watchedFiles:)`, `UsageStoreConfigurator` | `Shared/Stores/{ProfileStore,UsageStore}.swift`, `Shared/Repositories/UsageRepository.swift`, `Shared/Services/TokenFileMonitor.swift`, `TokenEaterApp/App/UsageStoreConfigurator.swift`, persistence types | `ProfileStoreTests` (migration default profile, add linked / capture flows with mocks, duplicate rejection, remove last, active switch writes legacy snapshot, relay of child changes, staggered bootstrap, one-shot notification), `UsageStoreTests` additions (readiness mapping, 401 → forced refresh retry, reauth state, namespaced samples key), `UsageRepositoryTests` additions, `TokenFileMonitorTests` (watched list) |
| **L3 SharedFile + Widget** | `feat/mp-widget` | §3.6 `SharedFileService` profiles + `init(rootDirectory:)`, §5.6 widgets, `WidgetReloader` kinds | `Shared/Services/SharedFileService.swift`, `Shared/Helpers/WidgetReloader.swift`, `TokenEaterWidget/*` | `SharedFileServiceTests` (temp root: catalog/usage/remove round-trip, legacy `cachedUsage` untouched by profile writes, older-schema decode), `UsageEntryTests` (profile fields), widget typecheck |
| **L4 Notifications** | `feat/mp-notifications` | §3.7 scope | `Shared/Services/NotificationService.swift`, `Protocols/NotificationServiceProtocol.swift`, `Protocols/NotificationStateStore.swift`, mocks | `NotificationServiceScopeTests` (legacy keys unchanged with `.legacy`, suffixed keys/ids per profile, prefixed titles, reminders removal per scope) |
| **L5 Popover + Menu bar** | `feat/mp-surfaces` | §5.4 switcher cell + resolver gate + editor labels, §5.5 renderer segment + `RenderData` fields + editor | `TokenEaterApp/Popover/{PopoverCells,PopoverMetricResolver,PopoverSectionView,ComposablePopoverView}.swift`, `Shared/Helpers/MenuBarRenderer.swift`, `Shared/Models/{PopoverCompositionModels,MenuBarCompositionModels}.swift`, `TokenEaterApp/Studio/MenuBarEditorView.swift`, `TokenEaterApp/App/MenuBarRenderDataBuilder.swift` | `MenuBarRendererTests` (segment hidden when nil label, pill tint), `PopoverCompositionModelsTests` / `MenuBarCompositionModelsTests` matrix updates, `PopoverRowPackerTests` unchanged |
| **L6 Accounts settings UI** | `feat/mp-settings-ui` | §5.2 | `TokenEaterApp/Settings/{AccountsSectionView,SettingsSectionView,SettingsRootView}.swift`, `Shared/Models/AppSection.swift` labels | `AppSectionTests` (`settings.accounts` parse), typecheck |
| **L7 App wiring + dashboard** | `feat/mp-app` | §5.1, §5.3, `DiagnosticReporter`, `PopoverErrorBanner` reauth copy, context menu | `TokenEaterApp/App/{TokenEaterApp,StatusBarController,ActiveProfileHost}.swift`, `TokenEaterApp/Windows/Monitoring/{MonitoringView,ProfilesOverviewStrip}.swift`, `TokenEaterApp/Windows/MainAppView.swift`, `TokenEaterApp/Popover/PopoverShared.swift`, `Shared/Helpers/DiagnosticReporter.swift`, `TokenEaterApp/Onboarding/OnboardingViewModel.swift` (if needed) | `DiagnosticReporterTests` additions, typecheck |

Dependencies: L2 depends on the *protocols* only (uses mocks) — it does not wait for L1. L5/L6/L7 build against the Phase 0 `ProfileStore` API. All lanes run `swift test` + `typecheck.sh` before reporting done.

### Phase 2 — Integration (integrator)

1. Merge lanes into `feat/multi-profile` in the order L1, L4, L3, L2, L5, L6, L7; resolve `Localizable.strings` blocks and mock files; run `run-tests.sh` + `typecheck.sh all`.
2. Wire the last seams that cross lanes: production `usageStoreFactory` in `ProfileStore` (uses L1's `ProfileTokenProvider`, L4's scoped `NotificationService`, L3's repository writes), `PopoverMetricResolver` gate reading `ProfileStore`, `MenuBarRenderDataBuilder` profile fields.
3. Push, open PR `feat/multi-profile → main` on the fork, let `ci.yml` build Release + run the suite on `macos-15`; fix until green.
4. Docs: `AGENTS.md` (8 stores, new services, profile data flow, migration note), `README.md` feature bullet + security note (vault item, refresh grant, write-back opt-in), `docs/multi-profile-plan.md` marked as implemented with deviations.
5. Manual QA on a Mac with Xcode (checklist §7.3). Version bump is the maintainer's call (suggested `5.14.0`).

### Phase 3 — optional follow-ups (not in scope unless time allows)

- Sessions/History across linked config dirs: `SessionMonitorService` and `SessionHistoryService` take a list of projects/sessions dirs (union of `ProfileStore.enabledProfiles` config dirs); watcher tiles show the profile colour; History gets a profile filter.
- Per-profile `MonitoringInsightsStore` sparkline data in `shared.json`.
- "All profiles" menu bar mode (composition repeated per profile with a coloured initial).

---

## 7. Validation

### 7.1 Local (works without Xcode)

Scripts (session scratchpad `tools/`, recreate from this description if missing):

- `make-harness.sh <repo-root>` — builds `<repo-root>/.spm-harness` (gitignored by adding `.spm-harness/` to `.gitignore` in Phase 0): a SwiftPM test target of symlinks to `Shared/`, `TokenEaterTests/` and `TokenEaterApp/Onboarding/OnboardingViewModel.swift`, dependency `swiftlang/swift-testing` (the CLT toolchain lacks `Testing`), plus `stub/lib_TestingInterop.a` defining `_swift_testing_getFallbackEventHandler`.
- `run-tests.sh <repo-root> [--filter Suite]` — `swift test -Xlinker -L<harness>/stub`. Baseline on `main`: **647 tests / 67 suites pass**.
- `typecheck.sh <repo-root> [app|widget|all]` — `swiftc -typecheck -sdk $(xcrun --show-sdk-path) -target arm64-apple-macos14.0 -swift-version 5 -parse-as-library` over `Shared + TokenEaterApp` and `Shared + TokenEaterWidget`. Baseline: both OK.

Definition of done for every lane: `run-tests.sh` green (no test removed or weakened), `typecheck.sh all` green, new code covered by tests listed in §6.

### 7.2 CI (fork)

`ci.yml` runs on PRs to `main` and pushes to `main` (Release build + Debug tests on `macos-15`). GitHub Actions is enabled on the fork but no workflow was registered yet; if a PR shows no checks, enable workflows once in the fork's Actions tab. `test-build.yml` (`gh workflow run test-build.yml -f branch=feat/multi-profile`) produces a signed-free DMG for manual testing.

### 7.3 Manual QA checklist (machine with Xcode, Release build per AGENTS.md)

1. Upgrade path: install over an existing 5.13 config → one profile "Claude Code" active, menu bar/popover/widgets identical, `sessionPacingSamples` preserved.
2. Add linked profile with `CLAUDE_CONFIG_DIR=~/.claude-work` (`claude /login` there first) → appears in Accounts with email/plan, overview strip shows both, both refresh (check "Updated" timestamps), popover switcher and context menu switch the active one, menu bar `profileLabel` segment shows the name.
3. Capture flow: `claude /login` with account B, Capture, `claude /login` back to A → profile B keeps refreshing for > token lifetime (self-renew), A unaffected; Claude Code sessions for A keep working.
4. Linked profile with *Renew automatically* on: expire its token (wait or edit `expiresAt`), confirm TokenEater renews and Claude Code keeps working in that config dir afterwards (`claude auth status` still logged in).
5. Linked profile with the default policy: expired token shows "Waiting for Claude Code"; running `claude` in that dir recovers it.
6. Rate limit isolation: force 429 on one profile (rapid refreshes) → only that card shows rate-limited backoff.
7. Notifications: two profiles crossing thresholds produce distinct, prefixed notifications.
8. Widgets: pin the Overview widget to profile B via the widget config sheet; unpinned widgets follow the active profile; remove profile B → its widget falls back to active.
9. Remove / disable / reorder / rename / recolour profiles; last profile cannot be removed.
10. Diagnostic report contains the Profiles section with no secrets.

---

## 8. Risks and mitigations

| Risk | Mitigation |
|------|-----------|
| Refresh-token rotation makes Claude Code's copy stale when TokenEater renews a linked profile | Write-back to the same backing store (Claude Code reloads on change); feature is opt-in per profile with an explanatory hint; owner-precedence adoption before every renew. |
| Captured profile and Claude Code both hold the same chain right after capture | Managed providers adopt newer same-chain credentials from the default store before renewing; renew happens only when expired. |
| Keychain ACL prompts on local ad-hoc builds for the vault item | Documented; Developer ID builds have a stable identity. Items are created by TokenEater so no `/usr/bin/security` ACL dance is needed. |
| `security` shell-out blocking (#217) now runs once per profile | Keep the 3 s watchdog, run providers off the main thread inside `Task`, stagger loops. |
| N× API calls | Per-token rate limits are independent; loops are staggered; interval setting applies per profile. |
| `StaticConfiguration` → `AppIntentConfiguration` migration for placed widgets | Nil parameter = active profile; verified in QA step 8. |
| Shared `Localizable.strings` merge conflicts | Delimited per-lane blocks. |
| SwiftUI hard rules (`@Observable`, computed bindings, `@StateObject` in `App`) | All new stores are `ObservableObject` + `@Published`; UI uses `@State` + `.onChange`; `ActiveProfileHost` swaps stores by `.id`, never by binding. |

---

## 9. Implementation status (2026-09-05)

All seven lanes landed on `feat/multi-profile` (PR #1 on the fork). Deviations from the spec above, recorded so the doc stays truthful:

- **`ProfileTokenProvider.invalidateToken()` never forces a renewal.** The spec's "force flag" would loop: a linked `.tokenEater` renewal writes back to `<dir>/.credentials.json`, the file watcher fires `handleTokenChange`, which invalidates and would renew again. `UsageStore` passes `force: true` explicitly on a 401 instead; a file change only re-reads the live store. `ProfileStore.handleTokenChange` also skips managed profiles (nothing of theirs lives in a watched file).
- **Adoption rule tightened** (§3.5 step 3): a managed profile never adopts credentials without a same-chain baseline (a lost vault item shows "No credentials" instead of attaching whichever account is signed in to `~/.claude`), and a linked profile adopts only when the live store changed since its previous read, so the stale token left by a failed write-back is not re-adopted.
- **Notification scope for the default profile** keeps the legacy unsuffixed keys but still gets the `[Name]` title prefix while several profiles exist (names come from a lock-guarded `ProfileNameRegistry`, resolved at fire time). `NotificationServiceProtocol.cancelPendingReminders()` was added (default no-op) so `ProfileStore.remove` drops a profile's pending reminders.
- **`project.yml`** gained `TokenEaterWidget/UsageEntry.swift` in the `TokenEaterTests` sources (single-file entry, like `OnboardingViewModel.swift`) for `UsageEntryTests`.
- **`ProfileStore.init` creates the default profile unconditionally** (the UI always needs one), so no `legacyHasCompletedOnboarding` parameter exists. `UsageStore.cachedUsage` reads the store's own per-profile snapshot (the default profile falls back to the legacy top-level one).
- `UsageStore.isLoading` flips before the readiness check so two callers cannot double an API call; the popover switcher gates on `profiles.count > 1` per spec (a paused second profile still shows the element).

Validation on the integration branch: `swiftc -typecheck` OK for the App and Widget targets; 844 Swift Testing cases in 81 suites (up from 647 / 67 on `main`), all green except three pre-existing `ElectronDecryptionServiceTests` cases that fail only while the Mac's screen is locked (`.completeFileProtection` writes return EPERM). Not yet done: the CI Release build (the fork's workflows must be enabled once in the Actions tab) and the manual QA checklist in §7.3, which needs a machine with Xcode.
