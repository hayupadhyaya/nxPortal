#if os(macOS)
import Foundation

/// Variables that are the Host's or the runtime's own and never come from a paired device, a stored choice or a game's list:
/// where the game finds its files, its scripted input, how it is started, what the Host sets (the tap socket, the launcher switch), the
/// environment-override family. By rule where there is one (a prefix or an ending), else by name (the runtime's `path`-class
/// switches, `docs/env_switches.tsv`) -> .claude/host.md § options
/// A second filter at launch: what a device may set is the allow-list `PlayerOptions`.
/// The owner's own `environment.json` is not held to this (the owner may set what they like); only the Host's two are
/// (`HostService.reservedGameVariables`).
enum ReservedVariables {
    /// `DM_STREAM*` (the tap socket, `DM_STREAM_PREPARE`), `DM_LAUNCH*` (the launcher switch, the launch parameter), `DM_ENV_*`
    /// (the environment-override files and their key lists), `DM_KEYS*` (scripted input), `DM_GAMES_*`, `DM_GPU_CAPTURE*`.
    static let prefixes = ["DM_STREAM", "DM_LAUNCH", "DM_ENV_", "DM_KEYS", "DM_GAMES_", "DM_GPU_CAPTURE"]
    /// A name that ends so is a place on disk.
    static let suffixes = ["_DIR", "_FILE", "_PATH", "_OUT"]
    /// The runtime's `path` class, by name.
    static let names: Set<String> = [
        "DM_AOC_DIR", "DM_APP_DM", "DM_CHEATS", "DM_CONTROL_NACP", "DM_EMBED_TAG", "DM_ENTITLEMENTS", "DM_ENV_FILE",
        "DM_EXEC_OUT", "DM_FONT_DIR", "DM_GAMES_DIR", "DM_GLSLC_CAPTURE", "DM_GL_CAPTURE", "DM_GL_RENDERPROGS",
        "DM_GPU_CAPTURE_DIR", "DM_GUEST_FILE_DIR", "DM_HTML", "DM_ICON", "DM_JIT_CAPTURE", "DM_JIT_SERVE",
        "DM_LAUNCH_PARAM", "DM_MEASURE_LOCK", "DM_MSL_DIR", "DM_NRO_DIR", "DM_NVN_BF_WANT", "DM_NVN_DUAL_WANT",
        "DM_NVN_SHMAP", "DM_NVN_VSDUMP", "DM_OBSOLETE", "DM_OODLE_HOST", "DM_OODLE_JOB", "DM_OODLE_MODULES",
        "DM_PROGRAMS", "DM_PSO_ARCHIVE", "DM_PSO_BUNDLE", "DM_PSO_HOST", "DM_PSO_MANIFEST", "DM_PSO_PAIRS",
        "DM_PSO_RECORD", "DM_PSO_USER", "DM_RESOURCE_AOC", "DM_RESOURCE_CHAIN_H", "DM_RESOURCE_MARKER",
        "DM_RESOURCE_MSLDIR", "DM_RESOURCE_PROGRAMS", "DM_RESOURCE_PSO", "DM_RESOURCE_ROMFS", "DM_RESOURCE_SHADERS",
        "DM_ROMFS", "DM_ROMFS_OVERLAY", "DM_ROMFS_PROGRAMS", "DM_ROOT", "DM_SAVE", "DM_SHARED_FONT",
        "DM_SHARED_FONT_EXT", "DM_SYSTEM_DIR", "DM_TEMP", "DM_UE_SHADERS", "DM_VK_CAPTURE", "DM_XCODE_DERIVED_DATA",
        "DM_XCODE_PROJECT_DIR"
    ]

    static func isReserved(_ env: String) -> Bool {
        names.contains(env) || prefixes.contains { env.hasPrefix($0) } || suffixes.contains { env.hasSuffix($0) }
    }
}
#endif
