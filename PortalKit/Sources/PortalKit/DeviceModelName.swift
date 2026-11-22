import Foundation

/// The model's own short name ("iPad mini"), the default for a device's name; no UIKit, so it is tested on the Mac
/// -> .claude/portalkit.md § wire-network
public enum DeviceModelName {
    /// Hardware identifier to Apple's public marketing name, without the generation.
    static let table: [String: String] = {
        var t: [String: String] = [:]
        func add(_ name: String, _ ids: String...) { for id in ids { t[id] = name } }
        add("iPhone 11", "iPhone12,1")
        add("iPhone 11 Pro", "iPhone12,3")
        add("iPhone 11 Pro Max", "iPhone12,5")
        add("iPhone SE", "iPhone12,8", "iPhone14,6", "iPhone8,4")
        add("iPhone 12 mini", "iPhone13,1")
        add("iPhone 12", "iPhone13,2")
        add("iPhone 12 Pro", "iPhone13,3")
        add("iPhone 12 Pro Max", "iPhone13,4")
        add("iPhone 13 mini", "iPhone14,4")
        add("iPhone 13", "iPhone14,5")
        add("iPhone 13 Pro", "iPhone14,2")
        add("iPhone 13 Pro Max", "iPhone14,3")
        add("iPhone 14", "iPhone14,7")
        add("iPhone 14 Plus", "iPhone14,8")
        add("iPhone 14 Pro", "iPhone15,2")
        add("iPhone 14 Pro Max", "iPhone15,3")
        add("iPhone 15", "iPhone15,4")
        add("iPhone 15 Plus", "iPhone15,5")
        add("iPhone 15 Pro", "iPhone16,1")
        add("iPhone 15 Pro Max", "iPhone16,2")
        add("iPhone 16 Pro", "iPhone17,1")
        add("iPhone 16 Pro Max", "iPhone17,2")
        add("iPhone 16", "iPhone17,3")
        add("iPhone 16 Plus", "iPhone17,4")
        add("iPhone 16e", "iPhone17,5")
        add("iPhone 17 Pro", "iPhone18,1")
        add("iPhone 17 Pro Max", "iPhone18,2")
        add("iPhone 17", "iPhone18,3")
        add("iPhone Air", "iPhone18,4")
        add("iPad", "iPad11,6", "iPad11,7", "iPad12,1", "iPad12,2", "iPad13,18", "iPad13,19", "iPad15,7", "iPad15,8")
        add("iPad mini", "iPad11,1", "iPad11,2", "iPad14,1", "iPad14,2", "iPad16,1", "iPad16,2")
        add("iPad Air", "iPad11,3", "iPad11,4", "iPad13,1", "iPad13,2", "iPad13,16", "iPad13,17")
        add("iPad Air 11-inch", "iPad14,8", "iPad14,9", "iPad15,3", "iPad15,4")
        add("iPad Air 13-inch", "iPad14,10", "iPad14,11", "iPad15,5", "iPad15,6")
        add("iPad Pro 11-inch", "iPad8,1", "iPad8,2", "iPad8,3", "iPad8,4", "iPad8,9", "iPad8,10",
            "iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7", "iPad14,3", "iPad14,4", "iPad16,3", "iPad16,4",
            "iPad17,1", "iPad17,2")
        add("iPad Pro 12.9-inch", "iPad8,5", "iPad8,6", "iPad8,7", "iPad8,8", "iPad8,11", "iPad8,12",
            "iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11", "iPad14,5", "iPad14,6")
        add("iPad Pro 13-inch", "iPad16,5", "iPad16,6", "iPad17,3", "iPad17,4")
        add("Apple TV HD", "AppleTV5,3")
        add("Apple TV 4K", "AppleTV6,2", "AppleTV11,1", "AppleTV14,1")
        return t
    }()

    /// The table's name, else the family from the identifier's prefix; "Device" when it names no family.
    public static func name(machine: String) -> String {
        if let known = table[machine] { return known }
        if machine.hasPrefix("iPhone") { return "iPhone" }
        if machine.hasPrefix("iPad") { return "iPad" }
        if machine.hasPrefix("AppleTV") { return "Apple TV" }
        return DeviceName.fallback
    }

    /// This device's hardware identifier: the simulator's from its environment value, else `uname`'s.
    public static func machineIdentifier(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let sim = environment["SIMULATOR_MODEL_IDENTIFIER"], !sim.isEmpty { return sim }
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        name(machine: machineIdentifier(environment: environment))
    }
}
