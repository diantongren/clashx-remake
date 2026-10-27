import Darwin
import Foundation

/// Hands out TCP ports that are not currently in use, preferring the requested one.
public struct PortAllocator: Sendable {
    public typealias Probe = @Sendable (Int) -> Bool

    private var claimed = Set<Int>()
    private let isAvailable: Probe
    public static let validRange = 1024..<65535

    /// - Parameter isAvailable: returns true when a port can be bound. Defaults to a real bind probe.
    public init(isAvailable: @escaping Probe = PortProbe.isAvailable) {
        self.isAvailable = isAvailable
    }

    /// Convenience for tests: treat the given ports as busy, everything else as free.
    public static func simulated(busy: Set<Int>) -> PortAllocator {
        PortAllocator { !busy.contains($0) }
    }

    /// Returns `preferred` when free, otherwise the next free port above it.
    public mutating func claim(preferring preferred: Int) -> Int {
        var candidate = max(preferred, Self.validRange.lowerBound)
        while candidate < Self.validRange.upperBound {
            if !claimed.contains(candidate), isAvailable(candidate) {
                claimed.insert(candidate)
                return candidate
            }
            candidate += 1
        }
        // Wrap around once before giving up on the preferred value.
        candidate = Self.validRange.lowerBound
        while candidate < preferred {
            if !claimed.contains(candidate), isAvailable(candidate) {
                claimed.insert(candidate)
                return candidate
            }
            candidate += 1
        }
        return preferred
    }
}

public enum PortProbe {
    /// True when nothing is listening on `port` for IPv4 loopback *or* any-address.
    @Sendable public static func isAvailable(_ port: Int) -> Bool {
        guard (0...65535).contains(port) else { return false }
        return canBind(port: UInt16(port), address: INADDR_ANY) && canBind(port: UInt16(port), address: INADDR_LOOPBACK)
    }

    private static func canBind(port: UInt16, address: in_addr_t) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: address.bigEndian)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
