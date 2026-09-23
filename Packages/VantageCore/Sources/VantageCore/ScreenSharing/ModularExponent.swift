import Foundation

/// Just enough big-integer arithmetic for the Diffie-Hellman step of Apple Remote Desktop
/// authentication: `base^exponent mod modulus` for an odd modulus, via Montgomery multiplication
/// on 32-bit limbs. Inputs and output are big-endian byte strings; the output has the modulus's length.
nonisolated enum ModularExponent {
    static func power(base: [UInt8], exponent: [UInt8], modulus: [UInt8]) -> [UInt8]? {
        let n = limbs(modulus)
        guard base.count <= modulus.count, let lowest = n.first, lowest & 1 == 1,
              n.count > 1 || lowest > 1 else { return nil }
        let context = Montgomery(modulus: n)
        var result = context.one
        // Any base below R converts correctly (a·R² < n·R), so it needn't be reduced first.
        let b = context.toMontgomery(limbs(base, count: n.count))
        for byte in exponent {
            for bit in (0..<8).reversed() {
                result = context.multiply(result, result)
                if (byte >> UInt8(bit)) & 1 == 1 { result = context.multiply(result, b) }
            }
        }
        return bytes(context.fromMontgomery(result), length: modulus.count)
    }

    /// Big-endian bytes → little-endian limbs, zero-extended to `count` limbs.
    static func limbs(_ bytes: [UInt8], count: Int? = nil) -> [UInt32] {
        let needed = (bytes.count + 3) / 4
        var out = [UInt32](repeating: 0, count: max(count ?? needed, needed))
        for (index, byte) in bytes.reversed().enumerated() {
            out[index / 4] |= UInt32(byte) << UInt32((index % 4) * 8)
        }
        return out
    }

    static func bytes(_ limbs: [UInt32], length: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        for index in 0..<length {
            let limb = index / 4
            guard limb < limbs.count else { break }
            out[length - 1 - index] = UInt8(truncatingIfNeeded: limbs[limb] >> UInt32((index % 4) * 8))
        }
        return out
    }

    private struct Montgomery {
        let n: [UInt32]
        let nPrime: UInt32
        /// R² mod n, where R = 2^(32·limbs).
        let rSquared: [UInt32]
        /// R mod n (the Montgomery form of 1).
        let one: [UInt32]

        init(modulus: [UInt32]) {
            n = modulus
            var inverse: UInt32 = 1
            for _ in 0..<5 { inverse = inverse &* (2 &- modulus[0] &* inverse) }
            let nPrime = 0 &- inverse
            self.nPrime = nPrime
            let s = modulus.count
            // R mod n: with n's top bit set, R − n < n, so it's just the two's-complement negation.
            var rModN: [UInt32]
            if modulus[s - 1] & 0x8000_0000 != 0 {
                rModN = Self.subtract([UInt32](repeating: 0, count: s), modulus)
            } else {
                rModN = [UInt32](repeating: 0, count: s)
                rModN[0] = 1
                for _ in 0..<(32 * s) { rModN = Self.addMod(rModN, rModN, modulus) }
            }
            one = rModN
            // R² mod n is the Montgomery form of 2^(32s): raise Montgomery(2) to that power.
            let two = Self.addMod(rModN, rModN, modulus)
            var power = rModN
            let bits = 32 * s
            for bit in (0..<(Int.bitWidth - bits.leadingZeroBitCount)).reversed() {
                power = Self.multiply(power, power, modulus, nPrime)
                if (bits >> bit) & 1 == 1 { power = Self.multiply(power, two, modulus, nPrime) }
            }
            rSquared = power
        }

        func toMontgomery(_ a: [UInt32]) -> [UInt32] { multiply(a, rSquared) }

        func fromMontgomery(_ a: [UInt32]) -> [UInt32] {
            var unit = [UInt32](repeating: 0, count: n.count)
            unit[0] = 1
            return multiply(a, unit)
        }

        func multiply(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] { Self.multiply(a, b, n, nPrime) }

        /// CIOS Montgomery multiplication: a·b·R⁻¹ mod n.
        static func multiply(_ a: [UInt32], _ b: [UInt32], _ n: [UInt32], _ nPrime: UInt32) -> [UInt32] {
            let s = n.count
            var t = [UInt32](repeating: 0, count: s + 2)
            t.withUnsafeMutableBufferPointer { t in
                a.withUnsafeBufferPointer { a in
                    b.withUnsafeBufferPointer { b in
                        n.withUnsafeBufferPointer { n in
                            for i in 0..<s {
                                var carry: UInt64 = 0
                                let bi = UInt64(b[i])
                                for j in 0..<s {
                                    let sum = UInt64(t[j]) &+ UInt64(a[j]) &* bi &+ carry
                                    t[j] = UInt32(truncatingIfNeeded: sum)
                                    carry = sum >> 32
                                }
                                var sum = UInt64(t[s]) &+ carry
                                t[s] = UInt32(truncatingIfNeeded: sum)
                                t[s + 1] = UInt32(sum >> 32)

                                let m = UInt64(t[0] &* nPrime)
                                sum = UInt64(t[0]) &+ m &* UInt64(n[0])
                                carry = sum >> 32
                                for j in 1..<s {
                                    sum = UInt64(t[j]) &+ m &* UInt64(n[j]) &+ carry
                                    t[j - 1] = UInt32(truncatingIfNeeded: sum)
                                    carry = sum >> 32
                                }
                                sum = UInt64(t[s]) &+ carry
                                t[s - 1] = UInt32(truncatingIfNeeded: sum)
                                t[s] = t[s + 1] &+ UInt32(sum >> 32)
                            }
                        }
                    }
                }
            }
            var result = Array(t[0..<s])
            if t[s] != 0 || !less(result, n) { result = subtract(result, n) }
            return result
        }

        static func less(_ a: [UInt32], _ b: [UInt32]) -> Bool {
            for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] {
                return a[i] < b[i]
            }
            return false
        }

        static func subtract(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
            var out = a
            var borrow: Int64 = 0
            for i in 0..<a.count {
                var diff = Int64(a[i]) - Int64(b[i]) - borrow
                borrow = diff < 0 ? 1 : 0
                if diff < 0 { diff += 1 << 32 }
                out[i] = UInt32(diff)
            }
            return out
        }

        static func addMod(_ a: [UInt32], _ b: [UInt32], _ n: [UInt32]) -> [UInt32] {
            var out = a
            var carry: UInt64 = 0
            for i in 0..<a.count {
                let sum = UInt64(a[i]) + UInt64(b[i]) + carry
                out[i] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
            }
            if carry != 0 || !less(out, n) { out = subtract(out, n) }
            return out
        }

    }
}
