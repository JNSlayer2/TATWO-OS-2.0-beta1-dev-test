import Foundation

/// SHA-1 is used only for RFC 6238 compatibility and HIBP's k-anonymous lookup.
/// Not a password-storage hash. No third-party crypto package, logging or transport.
enum CustodySHA1 {
    static func digest(_ bytes: [UInt8]) -> [UInt8] {
        var input = bytes
        let bitCount = UInt64(input.count) &* 8
        input.append(0x80)
        while input.count % 64 != 56 { input.append(0) }
        input += (0..<8).reversed().map { UInt8(truncatingIfNeeded: bitCount >> ($0 * 8)) }
        var hash: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0]
        func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
        for start in stride(from: 0, to: input.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let p = start + i * 4
                w[i] = (UInt32(input[p]) << 24) | (UInt32(input[p + 1]) << 16) |
                    (UInt32(input[p + 2]) << 8) | UInt32(input[p + 3])
            }
            for i in 16..<80 { w[i] = rotate(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1) }
            var a = hash[0], b = hash[1], c = hash[2], d = hash[3], e = hash[4]
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5a827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ed9eba1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc
                default: f = b ^ c ^ d; k = 0xca62c1d6
                }
                let next = rotate(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = rotate(b, 30); b = a; a = next
            }
            for (i, value) in [a,b,c,d,e].enumerated() { hash[i] = hash[i] &+ value }
        }
        return hash.flatMap { word in (0..<4).reversed().map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } }
    }

    static func hex(_ value: String) -> String {
        digest(Array(value.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    static func hmac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var key = key.count > 64 ? digest(key) : key
        key += [UInt8](repeating: 0, count: 64 - key.count)
        return digest(key.map { $0 ^ 0x5c } + digest(key.map { $0 ^ 0x36 } + message))
    }
}

enum TOTP {
    enum Failure: Error { case invalidSecret, unsupportedParameters, invalidTime }
    static func decodeBase32(_ raw: String) throws -> [UInt8] {
        let text = raw.uppercased().filter { !$0.isWhitespace }
        guard !text.isEmpty, text.utf8.count <= 1024 else { throw Failure.invalidSecret }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var buffer: UInt32 = 0, bits = 0, output: [UInt8] = []
        var padded = false, symbols = 0, padding = 0
        for char in text.utf8 {
            if char == 61 { padded = true; padding += 1; continue }
            guard !padded, let value = alphabet.firstIndex(of: char) else { throw Failure.invalidSecret }
            symbols += 1
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8(truncatingIfNeeded: buffer >> bits))
            }
        }
        guard [0,2,4,5,7].contains(symbols % 8),
              padding == 0 || (symbols + padding) % 8 == 0 && padding < 8,
              bits == 0 || (buffer & ((1 << bits) - 1)) == 0, output.count >= 10 else {
            throw Failure.invalidSecret
        }
        return output
    }

    /// Only parameters implemented by this six-digit UI are accepted, never silently downgraded.
    static func secret(from raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret: String
        if trimmed.lowercased().hasPrefix("otpauth:") {
            guard let url = URLComponents(string: trimmed), url.scheme?.lowercased() == "otpauth",
                  url.host?.lowercased() == "totp", url.user == nil, url.password == nil,
                  url.port == nil, url.fragment == nil else { throw Failure.unsupportedParameters }
            let items = url.queryItems ?? []
            let names = items.map { $0.name.lowercased() }
            guard Set(names).count == names.count else { throw Failure.unsupportedParameters }
            let params = Dictionary(uniqueKeysWithValues: zip(names, items.map { $0.value ?? "" }))
            guard (params["algorithm"] ?? "SHA1").uppercased() == "SHA1",
                  (params["digits"] ?? "6") == "6", (params["period"] ?? "30") == "30",
                  params["counter"] == nil, let value = params["secret"] else { throw Failure.unsupportedParameters }
            secret = value
        } else {
            secret = trimmed
        }
        _ = try decodeBase32(secret)
        return secret.uppercased().filter { !$0.isWhitespace && $0 != "=" }
    }

    static func code(secret: String, at time: TimeInterval = Date().timeIntervalSince1970,
                     digits: Int = 6) throws -> String {
        guard time.isFinite, time >= 0, time / 30 < Double(UInt64.max),
              digits == 6 || digits == 8 else { throw Failure.invalidTime }
        let counter = UInt64(time / 30)
        let message = (0..<8).reversed().map { UInt8(truncatingIfNeeded: counter >> ($0 * 8)) }
        let mac = CustodySHA1.hmac(key: try decodeBase32(secret), message: message)
        let p = Int(mac.last! & 0x0f)
        let value = (UInt32(mac[p] & 0x7f) << 24) | (UInt32(mac[p+1]) << 16) |
            (UInt32(mac[p+2]) << 8) | UInt32(mac[p+3])
        return String(format: "%0*u", digits, value % (digits == 6 ? 1_000_000 : 100_000_000))
    }
}
