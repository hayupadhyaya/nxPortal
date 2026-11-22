import Foundation

/// This machine's own addresses, for tests that reach a local service at one address from another.
public enum LocalAddresses {
    /// The first IPv4 address of an interface that is up and not loopback, as text; nil when there is none.
    public static func nonLoopbackIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let i = cursor {
            defer { cursor = i.pointee.ifa_next }
            let flags = Int32(i.pointee.ifa_flags)
            guard let sa = i.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard inet_ntop(AF_INET, &addr, &text, socklen_t(text.count)) != nil else { continue }
            return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return nil
    }
}
