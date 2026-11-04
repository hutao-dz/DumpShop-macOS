import Foundation

/// Just enough Mach-O parsing to answer "is this binary still FairPlay wrapped".
enum MachO {
    static let mhMagic: UInt32 = 0xFEED_FACE
    static let mhCigam: UInt32 = 0xCEFA_EDFE
    static let mhMagic64: UInt32 = 0xFEED_FACF
    static let mhCigam64: UInt32 = 0xCFFA_EDFE
    static let fatMagic: UInt32 = 0xCAFE_BABE
    static let fatMagic64: UInt32 = 0xCAFE_BABF
    static let lcEncryptionInfo: UInt32 = 0x21
    static let lcEncryptionInfo64: UInt32 = 0x2C

    struct View {
        let p: UnsafeRawBufferPointer
        var n: Int { p.count }
        func le32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= n else { return nil }
            return p.loadUnaligned(fromByteOffset: o, as: UInt32.self)
        }
        func be32(_ o: Int) -> UInt32? { le32(o)?.bigEndian }
        func be64(_ o: Int) -> UInt64? {
            guard o >= 0, o + 8 <= n else { return nil }
            return p.loadUnaligned(fromByteOffset: o, as: UInt64.self).bigEndian
        }
    }

    static func with<T>(_ d: Data, _ body: (View) -> T?) -> T? {
        guard d.count >= 4 else { return nil }
        return d.withUnsafeBytes { body(View(p: $0)) }
    }

    /// File offset of each architecture slice.
    static func slices(_ d: Data) -> [Int] {
        with(d) { v in
            guard let be = v.be32(0) else { return [] }
            if be == fatMagic || be == fatMagic64 {
                let is64 = be == fatMagic64
                guard let nfat = v.be32(4) else { return [] }
                let hdr = is64 ? 32 : 20
                var off = 8
                var out: [Int] = []
                for _ in 0..<nfat {
                    guard off + hdr <= v.n else { break }
                    let o: Int? = is64 ? v.be64(off + 8).map(Int.init) : v.be32(off + 8).map(Int.init)
                    guard let o else { break }
                    out.append(o)
                    off += hdr
                }
                return out
            }
            if let le = v.le32(0), [mhMagic, mhMagic64, mhCigam, mhCigam64].contains(le) {
                return [0]
            }
            return []
        } ?? []
    }

    static func isMachO(_ head: Data) -> Bool {
        // Every read must happen inside withUnsafeBytes: View wraps a borrowed
        // buffer pointer, so returning it from the closure would dangle.
        guard head.count >= 4 else { return false }
        return head.withUnsafeBytes { raw in
            let v = MachO.View(p: raw)
            if let be = v.be32(0), be == fatMagic || be == fatMagic64 { return true }
            if let le = v.le32(0), [mhMagic, mhMagic64, mhCigam, mhCigam64].contains(le) { return true }
            return false
        }
    }

    /// cryptid per slice; a non-zero value means the shell is still on.
    static func cryptids(_ d: Data) -> [UInt32]? {
        with(d) { v in
            var found: [UInt32] = []
            for so in slices(d) {
                guard let magic = v.le32(so) else { continue }
                let is64 = magic == mhMagic64 || magic == mhCigam64
                let swap = magic == mhCigam || magic == mhCigam64
                let rd: (Int) -> UInt32? = swap ? { v.be32($0) } : { v.le32($0) }
                guard let ncmds = rd(so + 16) else { continue }
                var off = so + (is64 ? 32 : 28)
                for _ in 0..<ncmds {
                    guard let cmd = rd(off), let size = rd(off + 4),
                          size > 0, size < 0x100_000 else { break }
                    if cmd == lcEncryptionInfo || cmd == lcEncryptionInfo64 {
                        if let ci = rd(off + 16) { found.append(ci) }
                        break
                    }
                    off += Int(size)
                }
            }
            return found.isEmpty ? nil : found
        }
    }

    /// Convenience for a file on disk.
    static func cryptids(at url: URL) -> [UInt32]? {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return cryptids(d)
    }
}
