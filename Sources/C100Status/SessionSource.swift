import Foundation

/// Identifies which underlying product produced an `AgentSession`.
///
/// Only `.codex` is populated in M0. The remaining cases exist so the
/// abstraction (grid layout, navigation dispatch, hook wiring) can be built
/// out now and filled in by later milestones without another refactor.
enum SessionSourceKind: String, Codable, Equatable {
    case codex
    case claudeHerdr = "claude-herdr"
    case claudeTerminal = "claude-terminal"
    case claudeDesktop = "claude-desktop"
}

/// Hints used by `UnifiedLayout` to decide which cwds should share a single
/// grid row. Two sessions merge into the same row when any of their hint
/// values match (union-find over cwd nodes).
///
/// For Codex, `codexProjectID` is set to the *fully resolved* project key
/// (i.e. `CatalogSession.projectKey`, which is either `"project:<id>"` or the
/// shared `"projectless"` bucket) rather than the raw nullable project id.
/// That preserves the existing Codex behavior where all projectless threads
/// -- regardless of cwd -- collapse onto a single shared row.
struct RowGroupingHints: Equatable {
    var codexProjectID: String?
    var herdrWorkspaceID: String?

    static let none = RowGroupingHints(codexProjectID: nil, herdrWorkspaceID: nil)
}

/// Where a key-press on a session's assigned key should navigate.
enum NavigationTarget: Equatable {
    case codexThread(sessionID: String)
    case herdrPane(paneID: String)
    case ghosttyTab(sessionID: String)
    case claudeDesktop
}

/// A single agent session as reported by a `SessionSourceProvider`, in the
/// vocabulary `UnifiedLayout` understands (source-agnostic row/column
/// placement inputs).
struct AgentSession: Equatable {
    let sourceKind: SessionSourceKind
    let sessionID: String
    /// Normalized (standardized) cwd path.
    let cwd: String
    let rowHints: RowGroupingHints
    let recency: Double
    /// Lower sorts earlier. `nil` falls back to recency-descending ordering
    /// after all explicitly ranked rows.
    let rowRank: Int?
    /// Lower sorts earlier within a row. `nil` falls back to
    /// recency-descending ordering after all explicitly ranked columns.
    let columnRank: Int?
    /// Initial status to seed when a session first appears without having
    /// gone through the hook path yet (e.g. herdr `agent_status` in M2).
    /// Unused in M0.
    let seedStatus: AgentStatus?
    let navigation: NavigationTarget
}

/// Verdict returned by `SessionSourceProvider.acceptHook` describing whether
/// a provider claims a given hook event. Used starting in M1 for the
/// hook-authoritative Claude sources; Codex ignores hooks here since its own
/// catalog-authoritative path in `Daemon` handles them directly.
enum HookVerdict: Equatable {
    case ignore
    case handled
}

/// A source of agent sessions to be merged into the unified grid.
protocol SessionSourceProvider {
    var kind: SessionSourceKind { get }
    /// Enumerate all currently known sessions for this source. Called on the
    /// daemon's periodic sync cadence.
    func snapshot() throws -> [AgentSession]
    /// Give the provider a chance to claim a hook event for its own
    /// bookkeeping (M1+). Default implementation ignores every hook.
    func acceptHook(_ hook: HookInput) -> HookVerdict
}

extension SessionSourceProvider {
    func acceptHook(_ hook: HookInput) -> HookVerdict { .ignore }
}

/// Thin adapter exposing the existing, unmodified `CodexCatalog` as a
/// `SessionSourceProvider`. All Codex ordering/grouping decisions (sidebar
/// order, pinned threads, projectless bucketing, fork ancestry, 10-per-row
/// truncation) are already resolved by `CodexCatalog.layout()`; this adapter
/// simply carries those resolved decisions over as rank hints so
/// `UnifiedLayout` reproduces the same placements.
struct CodexSourceProvider: SessionSourceProvider {
    let kind: SessionSourceKind = .codex
    private let homeDirectory: String

    init(homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
    }

    func snapshot() throws -> [AgentSession] {
        let layout = try CodexCatalog.layout(homeDirectory: homeDirectory)
        return layout.placements.map { placement in
            let session = placement.session
            let normalizedCWD = URL(fileURLWithPath: session.cwd).standardizedFileURL.path
            return AgentSession(
                sourceKind: .codex,
                sessionID: session.sessionID,
                cwd: normalizedCWD,
                rowHints: RowGroupingHints(codexProjectID: session.projectKey, herdrWorkspaceID: nil),
                recency: session.recency,
                rowRank: layout.projectRows[session.projectKey],
                columnRank: placement.column,
                seedStatus: nil,
                navigation: .codexThread(sessionID: session.sessionID)
            )
        }
    }
}
