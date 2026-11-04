import Foundation

struct PythonEnv {
    var path: String? = nil
    var fridaVersion: String? = nil
    var pymobiledevice3: Bool = false
    var installing: Bool = false
    var installLog: [String] = []

    var ready: Bool { path != nil && fridaVersion != nil }
}

@MainActor
final class Env: ObservableObject {
    static let shared = Env()

    @Published var py = PythonEnv()
    @Published var brewMissing: [String] = Tool.missingRequired()
    @Published var clientFridaVersion: String? = nil

    private var probeTask: Task<Void, Never>?

    var settings = AppSettings.shared

    func reprobe() {
        probeTask?.cancel()
        probeTask = Task { await scan() }
    }

    /// Prefer the app-managed venv, then any python3 that can import frida.
    func scan() async {
        brewMissing = Tool.missingRequired()
        var cands: [String] = []
        if !settings.pythonOverride.isEmpty { cands.append(settings.pythonOverride) }
        if FileManager.default.isExecutableFile(atPath: Paths.venvPython.path) {
            cands.append(Paths.venvPython.path)
        }
        for p in settings.extraPythons { cands.append(p) }
        if let h = Tool.which("python3") { cands.append(h) }
        if let h = Tool.which("/usr/bin/python3") { cands.append(h) }
        cands.append("/opt/homebrew/bin/python3")
        cands.append("/usr/bin/python3")

        var found: PythonEnv?
        for c in cands where FileManager.default.isExecutableFile(atPath: c) {
            let r = await Runner.run([c, "-c",
                "import frida,sys;print(frida.__version__)",
            ], timeout: 25)
            guard r.ok else { continue }
            let v = r.out.trimmed
            guard !v.isEmpty, v.contains(".") else { continue }
            let p3 = await Runner.run([c, "-c",
                "import importlib.util;print(bool(importlib.util.find_spec('pymobiledevice3')))",
            ], timeout: 25)
            var e = PythonEnv(path: c, fridaVersion: v,
                              pymobiledevice3: p3.out.trimmed == "True")
            if e.path == Paths.venvPython.path { e.installing = false }
            found = e
            break
        }
        py = found ?? PythonEnv()
        clientFridaVersion = py.fridaVersion
    }

    func createVenv() {
        guard !py.installing else { return }
        py.installing = true
        let index = settings.pipIndexURL.trimmed
        py.installLog = ["$ python3 -m venv \(Paths.venv.path)"]
        Task.detached { [weak self] in
            guard let self else { return }
            let boot = Tool.which("python3") ?? "/usr/bin/python3"
            let mk = [boot, "-m", "venv", Paths.venv.path]
            var pk = [Paths.venvPython.path, "-m", "pip", "install", "--quiet",
                      "--timeout", "60", "--retries", "5", "--upgrade", "pip"]
            if !index.isEmpty {
                // pip's own hash pinning still applies; the mirror only replaces the host.
                pk += ["--index-url", index]
            }
            pk += ["frida-tools", "pymobiledevice3"]
            if !index.isEmpty {
                await MainActor.run { self.py.installLog.append("使用镜像 \(index)") }
            }
            for argv in [mk, pk] {
                await Runner.stream(argv,
                    onLine: { line in
                        Task { @MainActor in
                            self.py.installLog.append(line)
                            if self.py.installLog.count > 400 {
                                self.py.installLog.removeFirst(self.py.installLog.count - 400)
                            }
                        }
                    },
                    onFinish: { _ in })
            }
            await self.scan()
            Task { @MainActor in self.py.installing = false }
        }
    }
}
