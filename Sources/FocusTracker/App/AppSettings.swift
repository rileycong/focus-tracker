import Foundation

/// The settings layer for the user-configurable vault location (issue #14,
/// PRD §5.1 "vault anywhere, path configurable"): a thin wrapper over
/// `UserDefaults` storing exactly one value — the vault path string.
///
/// **Injected suite (pinned for testability, issue #14):** the suite name is
/// a required constructor parameter, so tests can use an isolated, disposable
/// `UserDefaults` suite; production passes `AppSettings.defaultSuiteName`.
/// Save→reload across *instances* is part of the contract: a relaunch (or a
/// freshly constructed wrapper over the same suite) reads the same path.
///
/// **The user-facing vault-path contract lives here (binding, issue #14):**
/// - The chosen vault path persists across app relaunches (stored in
///   `UserDefaults`).
/// - The path changes only via the in-app Settings picker; first launch with
///   no stored path shows the onboarding picker (`vaultPath == nil` is the
///   state that flow keys off). The picker UI itself is #15+ — this type
///   exposes exactly the get/set API that flow will call.
/// - If the stored vault folder becomes unavailable (moved/deleted), the
///   stored path is **retained** and a degraded state is surfaced (that
///   handling lives in `AppModel`); this type never clears the value on its
///   own — the choice is never silently cleared (PRD §18: no silent data
///   loss). Only an explicit `vaultPath = nil` removes the stored value.
public struct AppSettings {

    /// The `UserDefaults` key under which the vault path is stored.
    public static let vaultPathKey = "vaultPath"

    /// The `UserDefaults` key of the vault-sync toggle (issue #49). Bool,
    /// DEFAULT FALSE — the shipped-by-default state is sync-off.
    public static let vaultSyncEnabledKey = "vaultSyncEnabled"

    /// The `UserDefaults` key of the vault-sync remote (issue #49). Stored
    /// AS-TYPED; nil/blank resolves to `""` (no remote) at USE time — there
    /// is NO default remote (issue #57).
    public static let vaultSyncRemoteKey = "vaultSyncRemote"

    /// The suite name production uses (the app's bundle identifier). Tests
    /// inject their own unique suite name instead (pinned seam, issue #14).
    public static let defaultSuiteName = "com.chauanhcong.FocusTracker"

    /// Typed init failure (house style: typed outcomes over force-unwraps):
    /// `UserDefaults(suiteName:)` returns nil for an invalid suite name.
    public enum SettingsError: Error, Equatable {
        case suiteUnavailable(String)
    }

    private let defaults: UserDefaults

    /// Creates a settings wrapper over the given suite — the injected-suite
    /// seam that keeps tests isolated from real user preferences.
    public init(suiteName: String) throws {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw SettingsError.suiteUnavailable(suiteName)
        }
        self.defaults = defaults
    }

    /// Creates a settings wrapper over an explicit `UserDefaults` instance —
    /// the fallback for the (practically unreachable) unavailable-suite case
    /// at app startup, and a convenience when a caller already holds one.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The configured vault path, or `nil` when never configured (first
    /// launch). Setting a non-nil value persists it immediately (a new
    /// instance over the same suite reads the same value); setting `nil`
    /// removes the stored value. Nothing else ever clears it — see the type
    /// documentation for the retained-path contract.
    public var vaultPath: String? {
        get { defaults.string(forKey: Self.vaultPathKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.vaultPathKey)
            } else {
                defaults.removeObject(forKey: Self.vaultPathKey)
            }
        }
    }

    /// The vault-sync toggle (issue #49). Persisted IMMEDIATELY on change —
    /// the #15 vaultPath precedent: no Save step, crash-safe. A fresh
    /// suite reads `false` (disabled by default; the shipped-by-default
    /// state, which the sync coordinator makes inert by construction).
    public var vaultSyncEnabled: Bool {
        get { defaults.bool(forKey: Self.vaultSyncEnabledKey) }
        set { defaults.set(newValue, forKey: Self.vaultSyncEnabledKey) }
    }

    /// The vault-sync remote, stored AS-TYPED (issue #49). Setting `nil`
    /// removes the stored value (the vaultPath precedent — the value is
    /// never silently rewritten); a stored blank resolves to `""` (no
    /// remote) only at USE time (see `resolvedVaultSyncRemote`).
    public var vaultSyncRemote: String? {
        get { defaults.string(forKey: Self.vaultSyncRemoteKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.vaultSyncRemoteKey)
            } else {
                defaults.removeObject(forKey: Self.vaultSyncRemoteKey)
            }
        }
    }

    /// The USE-time remote resolution (issues #49, #57): the stored value
    /// as typed, unless nil/blank — then `""` ("no remote"; there is no
    /// default). This is the ONLY resolution the sync engine ever sees; a
    /// blank remote makes the engine's static check fail BEFORE any spawn.
    public func resolvedVaultSyncRemote() -> String {
        if let stored = vaultSyncRemote,
            !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return stored
        }
        return ""
    }
}
