import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt

/// Waking the other Mac. If Universal Display Magnet there is reachable (display asleep,
/// Mac awake) a `.wake` message turns its screen on. If the whole Mac is
/// asleep nothing of ours runs, so a Wake-on-LAN "magic packet" is sent to
/// its network cards; that needs System Settings › Energy › "Wake for
/// network access" on that Mac (most reliable over Ethernet).
enum WakeService {
    /// Hardware addresses of this Mac's Ethernet / Wi-Fi interfaces ("aa:bb:…").
    /// Read from IOKit: `getifaddrs` returns a 02:00:00:00:00:00 placeholder
    /// on recent macOS.
    static func macAddresses() -> [String] {
        var result: [String] = []
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOEthernetInterface"), &iterator)
            == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let bsd = IORegistryEntryCreateCFProperty(service, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard bsd?.hasPrefix("en") == true,
                let data = IORegistryEntrySearchCFProperty(
                    service, kIOServicePlane, "IOMACAddress" as CFString, kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? Data,
                data.count == 6,
                data[data.startIndex] & 0x02 == 0  // skip virtual (locally administered) adapters
            else { continue }
            let mac = data.map { String(format: "%02x", $0) }.joined(separator: ":")
            if !result.contains(mac) { result.append(mac) }
        }
        return result
    }

    /// Broadcast a magic packet for each address on every local network.
    static func sendMagicPacket(to macs: [String]) {
        for mac in macs {
            let bytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
            guard bytes.count == 6 else { continue }
            var packet = [UInt8](repeating: 0xFF, count: 6)
            for _ in 0..<16 { packet += bytes }
            for target in broadcastAddresses() + ["255.255.255.255"] {
                for port: UInt16 in [9, 7] { send(packet, to: target, port: port) }
            }
        }
    }

    private static func broadcastAddresses() -> [String] {
        var result: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                (ifa.ifa_flags & UInt32(IFF_BROADCAST)) != 0, let b = ifa.ifa_dstaddr
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(b, socklen_t(b.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(cString: host)
                if !result.contains(s) { result.append(s) }
            }
        }
        return result
    }

    private static func send(_ packet: [UInt8], to host: String, port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// Turn this Mac's display on, exactly as touching the keyboard would.
    static func wakeDisplay() {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Universal Display Magnet: woken by your other Mac" as CFString, kIOPMUserActiveLocal, &id)
    }
}
