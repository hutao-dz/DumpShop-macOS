import Foundation

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first!
        let dir = base.appendingPathComponent("DumpShop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let venv = support.appendingPathComponent("venv", isDirectory: true)
    static var venvPython: URL { venv.appendingPathComponent("bin/python3") }
    static let dumps = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
        .first!.appendingPathComponent("DecryptedIPAs", isDirectory: true)
    static let scratch = support.appendingPathComponent("scratch", isDirectory: true)
    /// Where a downloaded ipatool is cached when the bundle does not carry one.
    static let bin = support.appendingPathComponent("bin", isDirectory: true)
    static var cachedIpatool: URL { bin.appendingPathComponent("ipatool") }
    /// Reusable FairPlay enrollment models recovered by UnfairPlay. These are
    /// account/device secrets, so they stay in Application Support with the rest
    /// of the app's private state and are never written beside an output IPA.
    static let unfairplayModels = support.appendingPathComponent("unfairplay-models",
                                                                 isDirectory: true)
    static let unfairplayReports = support.appendingPathComponent("unfairplay-reports",
                                                                  isDirectory: true)
    /// Reusable 16-byte account credentials recovered by fairplay-decrypt.
    /// Each credential is account-specific private state, never a public key.
    static let fairplayCredentials = support.appendingPathComponent(
        "fairplay-credentials", isDirectory: true)
    static let fairplayStaging = support.appendingPathComponent(
        "fairplay-staging", isDirectory: true)

    /// ipatool shipped inside the .app, if build_app.sh vendored one.
    ///
    /// The bundle may hold one binary per Mac architecture; the running one picks
    /// its own, so a single distributed .app still works on an Intel Mac.
    static var bundledIpatool: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let fm = FileManager.default
        for name in ["ipatool-\(Machine.arch)", "ipatool"] {
            let u = res.appendingPathComponent("bin/" + name)
            if fm.isExecutableFile(atPath: u.path) { return u }
        }
        return nil
    }

    /// Multi-region ipatool build. It is only used for non-CN profiles, so the
    /// historical CN keychain item keeps its original trusted binary identity.
    static var bundledIpatoolProfile: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let fm = FileManager.default
        for name in ["ipatool-profile-\(Machine.arch)", "ipatool-profile"] {
            let u = res.appendingPathComponent("bin/" + name)
            if fm.isExecutableFile(atPath: u.path) { return u }
        }
        return nil
    }

    /// UnfairPlay ships only a macOS arm64 binary. A developer running the bare
    /// Swift executable can still use the vendored copy from the repository.
    static func unfairplayTool() -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["DUMPSHOP_UNFAIRPLAY"],
           fm.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        if let res = Bundle.main.resourceURL {
            for name in ["unfairplay-arm64", "unfairplay"] {
                let u = res.appendingPathComponent("bin/" + name)
                if fm.isExecutableFile(atPath: u.path) { return u }
            }
        }
        let cached = bin.appendingPathComponent("unfairplay")
        if fm.isExecutableFile(atPath: cached.path) { return cached }
        if let external = Tool.which("unfairplay") {
            return URL(fileURLWithPath: external)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for dir in [cwd.appendingPathComponent("vendor"),
                    cwd.appendingPathComponent("dumpshop/vendor")] {
            for name in ["unfairplay-v0.2.0-macos-arm64", "unfairplay"] {
                let u = dir.appendingPathComponent(name)
                if fm.isExecutableFile(atPath: u.path) { return u }
            }
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        for up in ["../../../dumpshop/vendor", "../../dumpshop/vendor",
                   "../../../../dumpshop/vendor"] {
            let dir = exe.deletingLastPathComponent().appendingPathComponent(up)
            for name in ["unfairplay-v0.2.0-macos-arm64", "unfairplay"] {
                let u = dir.appendingPathComponent(name)
                if fm.isExecutableFile(atPath: u.path) { return u }
            }
        }
        return nil
    }

    /// Standalone helper built from fairplay-decrypt. It embeds Python and
    /// cryptography so a copied .app does not depend on the build machine.
    static func fairplayHelper() -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["DUMPSHOP_FAIRPLAY_HELPER"],
           fm.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        if let res = Bundle.main.resourceURL {
            for name in ["fairplay-decrypt-helper-arm64", "fairplay-decrypt-helper"] {
                let url = res.appendingPathComponent("bin/" + name)
                if fm.isExecutableFile(atPath: url.path) { return url }
            }
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for dir in [cwd.appendingPathComponent("vendor"),
                    cwd.appendingPathComponent("dumpshop/vendor")] {
            for name in ["fairplay-decrypt-helper-macos-arm64",
                         "fairplay-decrypt-helper"] {
                let url = dir.appendingPathComponent(name)
                if fm.isExecutableFile(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// Device-side native bundle used only during the one-time credential
    /// recovery. Normal IPA decryption never touches these files or the phone.
    static func fairplayDeviceBundle() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent(
                "fairplay-decrypt/device-bundle", isDirectory: true))
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for dir in [cwd.appendingPathComponent("vendor/fairplay-decrypt"),
                    cwd.appendingPathComponent("dumpshop/vendor/fairplay-decrypt")] {
            candidates.append(dir.appendingPathComponent(
                "credential-retrieval/build/bundle", isDirectory: true))
        }
        for dir in [cwd.appendingPathComponent("vendor"),
                    cwd.appendingPathComponent("dumpshop/vendor")] {
            candidates.append(dir.appendingPathComponent(
                "fairplay-device-bundle", isDirectory: true))
        }
        return candidates.first {
            fm.fileExists(atPath: $0.appendingPathComponent("credential.ios").path)
        }
    }

    /// Repository script fallback for developers running the bare Swift binary.
    static func fairplayScript() -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("engine/fairplay_helper.py"))
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("engine/fairplay_helper.py"))
        candidates.append(cwd.appendingPathComponent("dumpshop/engine/fairplay_helper.py"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func fairplaySource() -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent(
                "fairplay-decrypt/source", isDirectory: true))
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("vendor/fairplay-decrypt"))
        candidates.append(cwd.appendingPathComponent("dumpshop/vendor/fairplay-decrypt"))
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("decrypt.py").path)
        }
    }

    static func fairplayPython() -> String? {
        if let runtime = Bundle.main.resourceURL?.appendingPathComponent("bin/engine-runtime"),
           FileManager.default.isExecutableFile(atPath: runtime.path) {
            return runtime.path
        }
        if FileManager.default.isExecutableFile(atPath: venvPython.path) {
            return venvPython.path
        }
        return Tool.which("python3")
    }

    /// Where dumper.py / probe.py / applist.py live.
    static func engineDir(source: String?) -> URL? {
        var cands: [URL] = []
        if let source, !source.isEmpty { cands.append(URL(fileURLWithPath: source)) }
        if let res = Bundle.main.resourceURL {
            cands.append(res.appendingPathComponent("engine", isDirectory: true))
        }
        // `swift build` runs the bare binary, so allow pointing back at the repo.
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        for up in ["../../../dumpshop/engine", "../../dumpshop/engine",
                   "../../../../dumpshop/engine"] {
            cands.append(exe.deletingLastPathComponent().appendingPathComponent(up))
        }
        cands.append(support.appendingPathComponent("engine", isDirectory: true))
        return cands.first { FileManager.default.fileExists(
            atPath: $0.appendingPathComponent("dumper.py").path) }
    }
}
