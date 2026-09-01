import Darwin
import Foundation

/// M5: pure logic for the 4 layer-switch keys (row 9, keys 90-93) and the
/// small on-disk file that makes the active layer survive a daemon restart.
///
/// Layer base colors are deliberately drawn from each product's own brand
/// color rather than arbitrary "distinguishable" hues, per explicit user
/// request. Sources (checked 2026-09-01):
///   - Codex (OpenAI): user-supplied brand screenshot, a blue-violet/indigo
///     around #5B5BF5-#6466F1 (hue ~235-245 degrees, fairly saturated).
///   - herdr: `--accent: #4a9eff` in herdr.dev's own site CSS
///     (`css/style.css`), an azure/dodger blue. `~/.config/herdr/config.toml`
///     documents the *default* UI accent as the string "cyan", which the
///     site's own palette resolves to this same blue family, so the two
///     agree.
///   - Claude CLI (claude-terminal): Anthropic's "Claude orange"
///     (~#D97757), the well-known coral/terracotta used across Claude Code
///     branding.
///   - Claude Desktop: same Claude family, deliberately rotated toward
///     red/burgundy and dimmed relative to the CLI's orange so the two
///     Claude-sourced layers don't look identical at a glance.
///
/// Important overlap this creates (documented rather than papered over):
/// Codex's brand hue (~169 in this app's 0-255 hue scale) lands almost
/// exactly on `AgentStatus.working`'s hue (168) -- both are genuinely "blue"
/// in the colorimetric sense. They're kept apart by saturation/value
/// (Codex's layer key is paler and brighter; `.working` is fully saturated
/// and dim) and by the fact a layer key (row 9) and a grid status key
/// (rows 0-8) never appear adjacent to each other. Similarly, Claude's
/// orange (hue ~10) sits close to `.approval`'s amber (hue 21) and
/// `.error`'s red (hue 0) -- exactly why a non-active layer with an
/// approval/error/done session *blinks* between the layer's base color and
/// that status's real color (see `LayerKeyColorLogic.color`), rather than
/// relying on a static color alone to convey "attention needed".
enum LayerKeyColorLogic {
    /// Physical key index for each layer's switch key: 90=Codex, 91=herdr,
    /// 92=Claude CLI, 93=Claude Desktop. 94-99 are intentionally unused
    /// (left off) per the M5 spec.
    static let keyIndexes: [SessionSourceKind: Int] = [
        .codex: 90,
        .claudeHerdr: 91,
        .claudeTerminal: 92,
        .claudeDesktop: 93,
    ]

    /// Stable iteration order for the 4 layer keys (also the tie-break order
    /// used by tests / logging).
    static let order: [SessionSourceKind] = [.codex, .claudeHerdr, .claudeTerminal, .claudeDesktop]

    struct BrandColor {
        let hue: UInt8
        let saturation: UInt8
        let activeValue: UInt8
        let inactiveValue: UInt8
    }

    private static let brandColors: [SessionSourceKind: BrandColor] = [
        // OpenAI Codex: blue-violet/indigo (~#5B5BF5-#6466F1). Desaturated
        // and brighter than `.working` so the two near-identical hues still
        // read as different colors.
        .codex: BrandColor(hue: 169, saturation: 150, activeValue: 220, inactiveValue: 70),
        // herdr: azure/dodger blue (`--accent: #4a9eff` on herdr.dev).
        .claudeHerdr: BrandColor(hue: 150, saturation: 180, activeValue: 200, inactiveValue: 60),
        // Claude CLI: Anthropic's coral/terracotta "Claude orange" (~#D97757).
        .claudeTerminal: BrandColor(hue: 10, saturation: 255, activeValue: 200, inactiveValue: 60),
        // Claude Desktop: same warm family, rotated toward red/burgundy and
        // dimmer so it doesn't read as the same color as the CLI's orange.
        .claudeDesktop: BrandColor(hue: 248, saturation: 220, activeValue: 150, inactiveValue: 45),
    ]

    /// A layer key's steady (non-blinking) base color: brighter when its
    /// layer is active, dimmer when it isn't.
    static func baseColor(for source: SessionSourceKind, isActive: Bool) -> HSVColor {
        guard let brand = brandColors[source] else {
            return HSVColor(hue: 0, saturation: 0, value: isActive ? 200 : 60)
        }
        return HSVColor(
            hue: brand.hue,
            saturation: brand.saturation,
            value: isActive ? brand.activeValue : brand.inactiveValue
        )
    }

    /// The highest-priority "needs attention" status among a (non-active)
    /// layer's current sessions, per the M5 spec's fixed priority
    /// approval > error > done. `.working`/`.idle` never trigger a blink.
    static func attentionStatus(among statuses: [AgentStatus]) -> AgentStatus? {
        let present = Set(statuses)
        if present.contains(.approval) { return .approval }
        if present.contains(.error) { return .error }
        if present.contains(.done) { return .done }
        return nil
    }

    /// The color a layer key should currently show. Active layers always
    /// show their bright base color. Inactive layers with an
    /// approval/error/done session toggle between that status's real color
    /// and the layer's dim base color every time `blinkPhaseOn` flips
    /// (driven by the daemon's ~600ms main-loop timer); inactive layers with
    /// no attention-worthy session just show their dim base color.
    static func color(
        for source: SessionSourceKind,
        isActive: Bool,
        sessionStatuses: [AgentStatus],
        blinkPhaseOn: Bool
    ) -> HSVColor {
        let base = baseColor(for: source, isActive: isActive)
        guard !isActive, let attention = attentionStatus(among: sessionStatuses) else {
            return base
        }
        return blinkPhaseOn ? attention.color : base
    }
}

/// Persists the user's currently-selected layer across daemon restarts, in a
/// small file separate from `StateStore`'s ephemeral grid JSON (which is
/// intentionally wiped on every daemon start -- see `StatusDaemon.run()` --
/// so it carries no cross-restart compatibility burden). This file is new in
/// M5 and has no legacy format to stay compatible with; any read failure
/// (missing file, corrupt JSON, an unrecognized `SessionSourceKind` raw
/// value from a future/older build) just falls back to the default layer
/// rather than failing the daemon's startup.
final class LayerSelectionStore {
    static let defaultLayer: SessionSourceKind = .claudeHerdr

    private let fileURL: URL

    init(
        uid: uid_t = RuntimePaths.ownerUID,
        runtimeDirectory: URL = URL(fileURLWithPath: "/tmp")
    ) {
        fileURL = runtimeDirectory.appendingPathComponent("keychron-c100-status-\(uid)-layer.json")
    }

    private struct Payload: Codable {
        var activeLayer: SessionSourceKind
    }

    func load() -> SessionSourceKind {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return Self.defaultLayer
        }
        return payload.activeLayer
    }

    func save(_ layer: SessionSourceKind) {
        guard let data = try? JSONEncoder().encode(Payload(activeLayer: layer)) else { return }
        try? data.write(to: fileURL, options: .atomic)
        Darwin.chmod(fileURL.path, S_IRUSR | S_IWUSR)
    }
}
