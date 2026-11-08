import Foundation
import Darwin

/// 本机网络接口信息 (Android: pojo/network/NetInfo.java + utils/NetWorkUtil.java)
struct NetInfo {
    var name: String
    var ip: String
    var brodIp: String
    var mask: String
    var interfaceName: String
    var isIPV6: Bool

    /// 掩码前缀长度，例如 255.255.255.0 -> 24
    var maskBits: Int {
        NetUtils.maskMapLength(mask)
    }
}

enum NetUtils {
    static func ipv4ToInt(_ ip: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else { return nil }
        // in_addr 存的是网络字节序
        return UInt32(addr.s_addr.littleEndian)
    }

    static func intToIpv4(_ value: UInt32) -> String {
        var addr = in_addr()
        addr.s_addr = value.bigEndian
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count)) != nil else { return "0.0.0.0" }
        return String(cString: buffer)
    }

    static func maskMapLength(_ mask: String) -> Int {
        guard let m = ipv4ToInt(mask) else { return 32 }
        var bits = 0
        var v = m
        while v != 0 {
            bits += Int(v & 1)
            v >>= 1
        }
        return bits
    }

    static func maskMap(_ bits: Int) -> String {
        let mask: UInt32 = bits == 0 ? 0 : UInt32(0xFFFFFFFF) << (32 - UInt32(bits))
        return intToIpv4(mask)
    }

    /// 同网段判断 (Android: NetWorkUtil.subNet)
    static func subNet(_ ip1: String, _ ip2: String, _ maskBits: Int) -> Bool {
        guard let a = ipv4ToInt(ip1), let b = ipv4ToInt(ip2) else { return false }
        let mask: UInt32 = maskBits == 0 ? 0 : UInt32(0xFFFFFFFF) << (32 - UInt32(maskBits))
        return (a & mask) == (b & mask)
    }

    static func subNet(_ ip1: String, _ ip2: String, _ mask: String) -> Bool {
        subNet(ip1, ip2, maskMapLength(mask))
    }

    /// 广播地址 = ip | ~mask (Android: NetWorkUtil.getBroadcastAddress)
    static func broadcastAddress(ip: String, mask: String) -> String {
        guard let i = ipv4ToInt(ip), let m = ipv4ToInt(mask) else { return "255.255.255.255" }
        return intToIpv4(i | (~m))
    }

    /// 枚举本机 IPv4 接口（等价于 Android getNetInfoList：跳过回环、要求 up）
    static func netInfoList() -> [NetInfo] {
        var result: [NetInfo] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let flags = Int32(cur.pointee.ifa_flags)
            if let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 {
                let name = String(cString: cur.pointee.ifa_name)
                let ip = hostString(addr) ?? ""
                var maskStr = "255.255.255.0"
                if let nm = cur.pointee.ifa_netmask { maskStr = hostString(nm) ?? maskStr }
                var brod = ""
                if let dst = cur.pointee.ifa_dstaddr, (flags & IFF_BROADCAST) == IFF_BROADCAST {
                    brod = hostString(dst) ?? ""
                }
                if brod.isEmpty { brod = broadcastAddress(ip: ip, mask: maskStr) }
                if !ip.isEmpty {
                    result.append(NetInfo(name: name, ip: ip, brodIp: brod, mask: maskStr,
                                          interfaceName: name, isIPV6: false))
                }
            }
            ptr = cur.pointee.ifa_next
        }
        return result
    }

    /// 本机所有 IPv4 地址（自过滤广播包 + 二维码展示用）
    static func localIPv4s() -> [String] {
        netInfoList().map(\.ip)
    }

    /// 本机全局 IPv6 地址 (Android: NetWorkUtil.getOpenIpv6)
    static func localIPv6s() -> [String] {
        var result: [String] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let flags = Int32(cur.pointee.ifa_flags)
            if let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET6),
               (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0,
               let ip = hostString(addr), !ip.hasPrefix("fe80"), !ip.hasPrefix("::1") {
                result.append(ip)
            }
            ptr = cur.pointee.ifa_next
        }
        return result
    }

    private static func hostString(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = Int32(sa.pointee.sa_family)
        switch family {
        case AF_INET:
            return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                var addr = sin.pointee.sin_addr
                guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count)) != nil else { return nil }
                return String(cString: buffer)
            }
        case AF_INET6:
            return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                var addr = sin6.pointee.sin6_addr
                guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count)) != nil else { return nil }
                return String(cString: buffer)
            }
        default:
            return nil
        }
    }
}
