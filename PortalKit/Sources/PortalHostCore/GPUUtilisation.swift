#if os(macOS)
import Foundation
import IOKit

/// The one non-API read of the load: the accelerator's `PerformanceStatistics` in the I/O registry (no public API gives
/// GPU utilisation). Called only by `MacLoadSampler`; nil when the key is absent (the panel then says "GPU n/a").
/// Deleting this file removes the feature -> .claude/host.md § load
enum GPUUtilisation {
    /// "Device Utilization %" of the busiest accelerator, 0...100; nil when the registry has none.
    static func read() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let raw = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let stats = raw as? [String: Any], let v = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            best = max(best ?? 0, min(max(v, 0), 100))
        }
        return best
    }
}
#endif
