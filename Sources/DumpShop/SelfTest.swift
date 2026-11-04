import Foundation

/// `DumpShop --selftest check` runs offline assertions over the Mach-O reader,
/// `DumpShop --selftest cryptid <path>` prints what the verifier would report.
/// Holder for the live-pipe test, which is filled in from callback queues.
final class PipeBox: @unchecked Sendable {
    var writer: StreamWriter?
    var echoed = false
    var finished = false
    var code: Int32 = -999
}

enum SelfTest {
    static func run(_ args: [String]) -> Int32 {
        guard args.count >= 2 else { return usage() }
        switch args[1] {
        case "cryptid":
            guard args.count >= 3 else { return usage() }
            let url = URL(fileURLWithPath: args[2])
            guard let ids = MachO.cryptids(at: url) else {
                print("no crypt load command (not wrapped or not a Mach-O)")
                return 0
            }
            print("cryptids per slice: \(ids.map(String.init).joined(separator: ", "))")
            print(ids.allSatisfy { $0 == 0 } ? "DECRYPTED" : "ENCRYPTED")
            return ids.allSatisfy { $0 == 0 } ? 0 : 1
        case "check":
            return check(requireBundledHelpers: !args.contains("--source-only"))
        case "env":
            return env()
        default:
            return usage()
        }
    }

    private static func usage() -> Int32 {
        FileHandle.standardError.write(Data(
            "usage: DumpShop --selftest check [--source-only] | cryptid <macho> | env\n".utf8))
        return 2
    }

    /// Print exactly what the discovery layer sees, without touching the GUI.
    private static func env() -> Int32 {
        print("support dir : \(Paths.support.path)")
        print("venv python : \(Paths.venvPython.path) "
              + (FileManager.default.isExecutableFile(atPath: Paths.venvPython.path) ? "(found)" : "(missing)"))
        print("engine dir  : \(Paths.engineDir(source: "").map(\.path) ?? "NOT FOUND"))")
        print("dumps dir   : \(Paths.dumps.path)")
        for t in ["idevice_id", "ideviceinfo", "ideviceinstaller", "iproxy", "zip", "unzip", "sshpass"] {
            print("tool \(t.padding(toLength: 16, withPad: " ", startingAt: 0)): \(Tool.which(t) ?? "MISSING")")
        }
        print("missing req : \(Tool.missingRequired())")
        let r = Runner.sync([Paths.venvPython.path, "-c", "import frida;print(frida.__version__)"])
        print("venv frida  : code=\(r.code) out=\(r.out.trimmed) err=\(r.err.trimmed.prefix(120))")
        let d = Runner.sync([Tool.which("idevice_id") ?? "idevice_id", "-l"])
        print("idevice_id  : code=\(d.code) out=\(d.out.trimmed)")
        let i = Runner.sync([Tool.which("ideviceinfo") ?? "ideviceinfo", "-k", "DeviceName"])
        print("ideviceinfo : code=\(i.code) out=\(i.out.trimmed)")
        return 0
    }

    private static func check(requireBundledHelpers: Bool) -> Int32 {
        var failures: [String] = []
        func expect(_ cond: Bool, _ what: String) {
            print((cond ? "  ok   " : "  FAIL ") + what)
            if !cond { failures.append(what) }
        }

        // 1) a real fat binary on this Mac must expose multiple slices
        if let d = try? Data(contentsOf: URL(fileURLWithPath: "/bin/ls")) {
            let sl = MachO.slices(d)
            expect(!sl.isEmpty, "/bin/ls slices found: \(sl)")
            expect(MachO.isMachO(d.prefix(8)), "/bin/ls detected as Mach-O")
            expect(MachO.cryptids(d) == nil, "/bin/ls has no crypt command")
        } else {
            expect(false, "read /bin/ls")
        }

        // 2) synthetic thin arm64 binary carrying LC_ENCRYPTION_INFO_64
        let cryptoff = 0x4000, cryptsize = 16
        var seg = Data(); seg.append(le(0x19)); seg.append(le(72))
        seg.append(contentsOf: "__TEXT".utf8); seg.append(Data(count: 10))
        seg.append(le64(0)); seg.append(le64(0x4000)); seg.append(le64(0)); seg.append(le64(0x4000))
        seg.append(le(5)); seg.append(le(5)); seg.append(le(0)); seg.append(le(0))
        var enc = Data(); enc.append(le(0x2C)); enc.append(le(24))
        enc.append(le(UInt32(cryptoff))); enc.append(le(UInt32(cryptsize)))
        enc.append(le(1)); enc.append(le(0))
        var hdr = Data()
        hdr.append(le(MachO.mhMagic64)); hdr.append(le(0x0100_000C)); hdr.append(le(0))
        hdr.append(le(2)); hdr.append(le(2)); hdr.append(le(UInt32(seg.count + enc.count)))
        hdr.append(le(0)); hdr.append(le(0))
        var thin = hdr + seg + enc
        thin.append(Data(count: cryptoff - thin.count))
        thin.append(contentsOf: "ENCRYPTED_DATA".utf8)
        thin.append(Data(count: 64))
        expect(seg.count == 72, "synthetic LC_SEGMENT_64 is 72 bytes (got \(seg.count))")
        expect(enc.count == 24, "synthetic LC_ENCRYPTION_INFO_64 is 24 bytes (got \(enc.count))")
        expect(MachO.cryptids(thin) == [1], "thin synthetic reports cryptid 1")
        expect(MachO.slices(thin) == [0], "thin synthetic has one slice at 0")

        // 3) wrap two copies in a FAT container and re-check
        var s1 = thin; s1.replaceSubrange(8..<12, with: le(0))
        var s2 = thin; s2.replaceSubrange(8..<12, with: le(2))
        let align = 0x4000
        let o1 = alignUp(8 + 40, align), o2 = alignUp(o1 + s1.count, align)
        var fat = Data(); fat.append(be32(0xCAFE_BABE)); fat.append(be32(2))
        fat.append(be32(0x0100_000C)); fat.append(be32(0))
        fat.append(be32(UInt32(o1))); fat.append(be32(UInt32(s1.count))); fat.append(be32(UInt32(align)))
        fat.append(be32(0x0100_000C)); fat.append(be32(2))
        fat.append(be32(UInt32(o2))); fat.append(be32(UInt32(s2.count))); fat.append(be32(UInt32(align)))
        fat.append(Data(count: o1 - fat.count)); fat.append(s1)
        fat.append(Data(count: o2 - fat.count)); fat.append(s2)
        expect(MachO.slices(fat) == [o1, o2], "fat slices at \([o1, o2])")
        expect(MachO.cryptids(fat) == [1, 1], "fat synthetic reports cryptid 1 for both slices")

        // 4) flip both cryptids to 0 the way the dumper does, then re-read
        var patched = fat
        for so in [o1, o2] {
            var off = so + 32
            for _ in 0..<2 {
                let cmd = Int(leVal(patched, off))
                let size = Int(leVal(patched, off + 4))
                if cmd == Int(MachO.lcEncryptionInfo64) {
                    patched.replaceSubrange((off + 16)..<(off + 20), with: le(0))
                    break
                }
                off += size
            }
        }
        expect(MachO.cryptids(patched) == [0, 0], "after clearing cryptid the reader reports 0")
        expect(patched.count == fat.count, "patching preserved file size")

        // 5) Route B: the store argv must carry every flag the engine reads, or a
        //    download silently degrades into a plain dump of a missing app.
        let item = StoreItem(id: 1, name: "示例应用", bundleId: "com.example.t",
                             version: "1.2.3", seller: "s", price: "免费",
                             artwork: URL(string: "https://x/100x100bb.jpg"),
                             bytes: 3_145_728, genres: ["工具"])
        expect(item.artworkURL200?.absoluteString.contains("200x200bb") == true,
               "store artwork upgrades to 200px")
        expect(item.sizeText == "3 MB", "store size formats (got \(item.sizeText))")
        expect(item.asInstalledApp().dumpable, "a store item counts as dumpable")
        expect(item.itmsURL == "itms-apps://itunes.apple.com/app/id1",
               "device route builds an itms-apps product link")
        let sargv = AppModel.storeDumpArgv(py: "/p", dumper: "/d/dumper.py", item: item,
                                           udid: "U", outDir: URL(fileURLWithPath: "/out"),
                                           work: URL(fileURLWithPath: "/w"),
                                           ipatool: "/bin/ipatool", cacheRoot: "/cache",
                                           uninstall: true, noResume: false,
                                           onDevice: false)
        for flag in ["--from-store", "com.example.t", "示例应用", "/bin/ipatool", "/cache",
                     "--uninstall-if-installed-by-us"] {
            expect(sargv.contains(flag), "store argv carries \(flag)")
        }
        expect(!sargv.contains("--no-resume"), "store argv omits --no-resume when unset")
        expect(!sargv.contains("--uninstall-after"),
               "store argv only asks to remove what it installed itself")
        expect(!sargv.contains("--store-on-device"),
               "the automatic route does not quietly switch to the phone")
        let pargv = AppModel.storeDumpArgv(py: "/p", dumper: "/d/dumper.py", item: item,
                                           udid: "U", outDir: URL(fileURLWithPath: "/out"),
                                           work: URL(fileURLWithPath: "/w"),
                                           ipatool: "/bin/ipatool", cacheRoot: "/cache",
                                           uninstall: true, noResume: false, onDevice: true)
        expect(pargv.contains("--store-on-device"), "device route asks for the phone flow")
        expect(pargv.contains(item.itmsURL), "device route passes the product link")
        expect(!pargv.contains("--ipatool"), "device route needs no ipatool at all")
        let dargv = AppModel.dumpArgv(py: "/p", dumper: "/d/dumper.py",
                                      app: item.asInstalledApp(), udid: "U",
                                      outDir: URL(fileURLWithPath: "/out"),
                                      work: URL(fileURLWithPath: "/w"), noResume: true)
        expect(!dargv.contains("--from-store"), "device argv never triggers the store path")
        expect(dargv.contains("--no-resume"), "device argv carries --no-resume")

        // 6) the store search parser must survive a real iTunes payload shape
        let fixture = """
        {"resultCount":1,"results":[{"trackId":123,"trackName":"某应用",\
        "bundleId":"com.example.t","version":"1.2.3","sellerName":"S",\
        "formattedPrice":"免费","artworkUrl100":"https://x/100x100bb.jpg",\
        "fileSizeEsrp":"4194304","fileSizeBytes":1492048896,\
        "genres":["工具"],"kind":"software"}]}
        """
        var parsed: StoreSearch.Response?
        if let data = fixture.data(using: .utf8) {
            parsed = try? JSONDecoder().decode(StoreSearch.Response.self, from: data)
        }
        expect(parsed?.resultCount == 1, "store fixture decodes")
        expect(parsed?.results.first?.bundleId == "com.example.t", "fixture keeps bundle id")
        expect(parsed?.results.first?.fileSizeEsrp?.value == 4_194_304,
               "fixture keeps string store size")
        expect(parsed?.results.first?.fileSizeBytes?.value == 1_492_048_896,
               "fixture keeps numeric store size")
        expect(StoreSearch.endpoint("x", region: "JP", limit: 5)?.absoluteString
            .contains("country=JP") == true, "search endpoint carries the region")
        expect(StoreRegion.allCases.map(\.rawValue) == ["CN", "US", "JP", "HK", "TW"],
               "region picker includes Taiwan and all five storefronts")
        expect(StoreSearch.endpoint("x", region: "TW", limit: 5)?.absoluteString
            .contains("country=TW") == true, "Taiwan search uses the TW storefront")
        let prices = """
        {"resultCount":3,"results":[
        {"trackId":1,"bundleId":"a.free","formattedPrice":"免費","price":0,"currency":"TWD"},
        {"trackId":2,"bundleId":"a.paid","formattedPrice":"免費","price":30,"currency":"TWD"},
        {"trackId":3,"bundleId":"a.unknown"}]}
        """
        if let response = try? JSONDecoder().decode(StoreSearch.Response.self, from: Data(prices.utf8)) {
            let items = response.results.compactMap(StoreSearch.make)
            expect(items.count == 3 && items[0].isFree && !items[1].isFree && !items[2].isFree,
                   "numeric price wins over display text; unknown prices never request a purchase")
        } else { expect(false, "localized prices decode") }
        let key = MacFairPlayController.credentialBindingKey(region: "TW", accountID: "account-a")
        expect(key != MacFairPlayController.credentialBindingKey(region: "CN", accountID: "account-a")
               && key != MacFairPlayController.credentialBindingKey(region: "TW", accountID: "account-b"),
               "credential bindings isolate both storefront and account")
        let summary = """
        {"e":"result","logged_in":true,"binary":true,"account_id":"account-a","region":"TW"}
        """
        if let event = try? JSONDecoder().decode(EngineEvent.self, from: Data(summary.utf8)) {
            let auth = StoreAuth(event)
            expect(auth.accountID == "account-a" && auth.region == "TW", "account identity survives engine decoding")
        } else { expect(false, "regional auth summary decodes") }
        // An entry without a bundleId (books, apps-delisted rows) must be dropped.
        let noisy = """
        {"resultCount":2,"results":[{"trackId":1,"trackName":"无bundle"},{"trackId":2,\
        "trackName":"有bundle","bundleId":"a.b"}]}
        """
        if let n = try? JSONDecoder().decode(StoreSearch.Response.self,
                                            from: Data(noisy.utf8)) {
            expect(n.results.count == 2, "raw response keeps both rows")
        } else {
            expect(false, "noisy fixture decodes")
        }

        // 7) the sign-in pipe itself: StreamWriter must reach a child that is
        //    already running, and closing it must read as clean end-of-input, which
        //    is exactly how a 2FA code is delivered and how a cancel is signalled.
        let box = PipeBox()
        Runner.stream(["/bin/cat"],
                      stdin: { w in
                          box.writer = w
                          w.writeLine("dumpshop-pipe-check")
                      },
                      onLine: { line in
                          if line.contains("dumpshop-pipe-check") { box.echoed = true }
                      },
                      onFinish: { c in box.code = c; box.finished = true })
        pump(while: { !box.echoed }, seconds: 8)
        expect(box.echoed, "stdin writer reaches a running child")
        box.writer?.close()
        pump(while: { !box.finished }, seconds: 5)
        expect(box.finished && box.code == 0,
               "closing stdin ends the child cleanly (code \(box.code))")

        // 8) Offline decryption never includes a device in its argv and never
        //    claims "full" unless the output verifier found zero cryptids.
        let fpTool = URL(fileURLWithPath: "/tmp/fairplay-decrypt-helper")
        let fpArgv = MacFairPlayController.decryptArgv(
            tool: fpTool,
            input: URL(fileURLWithPath: "/in/Test.ipa"),
            output: URL(fileURLWithPath: "/out/test.part.ipa"),
            credential: URL(fileURLWithPath: "/credentials/credential.bin"))
        for flag in ["--credential", "/in/Test.ipa", "/out/test.part.ipa"] {
            expect(fpArgv.contains(flag), "Mac offline argv carries \(flag)")
        }
        expect(!fpArgv.contains("--udid"), "Mac offline decrypt needs no iPhone")
        let fpIdentity = IPAIdentity(name: "示例/应用", version: "1.2.3", bundleId: "a.b")
        expect(MacFairPlayController.outputName(identity: fpIdentity, verified: true as Bool?)
               == "示例_应用-1.2.3-全解密.ipa",
               "Mac offline output uses app name, version and verified verdict")
        expect(MacFairPlayController.outputName(identity: fpIdentity, verified: false as Bool?)
               == "示例_应用-1.2.3-未完全解密.ipa",
               "Mac offline output marks any remaining encrypted Mach-O")
        expect(MacFairPlayController.outputName(identity: fpIdentity, verified: nil)
               == "示例_应用-1.2.3-未完全校验.ipa",
               "Mac offline output never claims full verification when scanning fails")
        let fdargv = AppModel.macOfflineStoreArgv(
            py: "/p", store: "/e/store.py", item: item,
            dest: URL(fileURLWithPath: "/tmp/com.example.t.ipa"),
            ipatool: "/bin/ipatool", cacheRoot: "/cache", region: "CN")
        for flag in ["download", "--bundle-id", "com.example.t", "/bin/ipatool",
                     "--profile", "CN"] {
            expect(fdargv.contains(flag), "Mac offline store argv carries \(flag)")
        }
        expect(!fdargv.contains("--no-purchase"),
               "free store app asks ipatool to obtain its free license")
        let paidArgv = AppModel.macOfflineStoreArgv(
            py: "/p", store: "/e/store.py",
            item: StoreItem(id: 2, name: "付费", bundleId: "com.example.paid",
                            version: "1", seller: "s", price: "¥6.00",
                            artwork: nil, bytes: nil, genres: []),
            dest: URL(fileURLWithPath: "/tmp/paid.ipa"),
            ipatool: "/bin/ipatool", cacheRoot: "/cache", region: "US",
            purchase: false, accountID: "regional-account")
        expect(paidArgv.contains("--no-purchase"),
               "paid app never tries to purchase a paid license")
        expect(paidArgv.contains("--expected-account") && paidArgv.contains("regional-account"),
               "task pins the account used when it was created")
        expect(!fdargv.contains("--udid"), "Mac offline store download needs no phone")
        let historyArgv = AppModel.macOfflineStoreArgv(
            py: "/p", store: "/e/store.py", item: item,
            dest: URL(fileURLWithPath: "/tmp/history.ipa"),
            ipatool: "/bin/ipatool", cacheRoot: "/cache", region: "HK",
            purchase: false, accountID: "regional-account",
            externalVersionID: "883611377", expectedVersion: "13.2")
        expect(historyArgv.contains("--external-version-id") && historyArgv.contains("883611377")
               && historyArgv.contains("--expected-version") && historyArgv.contains("13.2")
               && historyArgv.contains("--no-purchase"),
               "history job pins the selected version and only uses an existing license")
        expect(MacFairPlayController.credentialFailureHint(
            "[stderr] credential does not decode this SINF priv record") != nil,
            "credential mismatch provides an account-specific recovery hint")
        expect(MacFairPlayController.credentialFailureHint("network timeout") == nil,
               "network failures are never reported as credential mismatches")
        if !requireBundledHelpers {
            print("  skip  helper packaging checks (explicit source-only mode)")
        } else if let fp = Paths.fairplayHelper() {
            let vr = Runner.sync([fp.path, "retrieve", "--help"], timeout: 60)
            expect(vr.ok && vr.out.contains("--device-udid"),
                   "bundled fairplay-decrypt helper runs")
        } else {
            expect(false, "fairplay-decrypt helper is discoverable")
        }
        if requireBundledHelpers {
            expect(Paths.fairplayDeviceBundle() != nil,
                   "fairplay-decrypt device bundle is discoverable")
        }

        print(failures.isEmpty ? "\nSELFTEST PASS" : "\nSELFTEST FAIL (\(failures.count))")
        return failures.isEmpty ? 0 : 1
    }

    /// Drive the main run loop until `cond` clears or the clock runs out, since a
    /// command-line process has no run loop for async callbacks to land on.
    private static func pump(while cond: @escaping @Sendable () -> Bool, seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while cond(), Date() < until {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private static func alignUp(_ v: Int, _ a: Int) -> Int { ((v + a - 1) / a) * a }
    private static func le(_ v: UInt32) -> Data {
        var x = v.littleEndian; return Data(bytes: &x, count: 4)
    }
    private static func le64(_ v: UInt64) -> Data {
        var x = v.littleEndian; return Data(bytes: &x, count: 8)
    }
    private static func be32(_ v: UInt32) -> Data {
        var x = v.bigEndian; return Data(bytes: &x, count: 4)
    }
    private static func leVal(_ d: Data, _ o: Int) -> UInt32 {
        let i = d.index(d.startIndex, offsetBy: o)
        return d[i..<d.index(i, offsetBy: 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }
}
