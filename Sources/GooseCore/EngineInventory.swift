import Foundation

struct EngineLayout: Sendable {
    let root: URL

    init(root: URL? = nil, environment: [String: String]) {
        if let root {
            self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        } else if let path = environment["GOOSE_ENGINES_ROOT"], !path.isEmpty {
            self.root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        } else {
            self.root = (Bundle.main.resourceURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"))
                .appendingPathComponent("Engines", isDirectory: true)
        }
    }

    func wineRoot(_ architecture: BottleArchitecture) -> URL {
        root.appendingPathComponent(architecture == .arm64ec ? "Wine" : "WineX64", isDirectory: true)
    }

    func wine(_ architecture: BottleArchitecture) -> URL {
        wineRoot(architecture).appendingPathComponent("bin/wine")
    }

    func wineserver(_ architecture: BottleArchitecture) -> URL {
        wineRoot(architecture).appendingPathComponent("bin/wineserver")
    }

    func dllRoot(_ architecture: BottleArchitecture) -> URL {
        wineRoot(architecture).appendingPathComponent("lib/wine", isDirectory: true)
    }

    var legacyOpenGL: URL { root.appendingPathComponent("LegacyOpenGL", isDirectory: true) }

    var hasLegacyOpenGL: Bool {
        ["i386-windows/opengl32.dll", "aarch64-unix/opengl32.so"].allSatisfy {
            FileManager.default.isReadableFile(atPath: legacyOpenGL.appendingPathComponent($0).path)
        }
    }

    func dxmtDirectory(_ architecture: String) -> URL {
        root.appendingPathComponent("DXMT/\(architecture)", isDirectory: true)
    }

    /// The loader manifest of MoltenVK, the Vulkan driver behind Wine's Vulkan and Direct3D 12.
    var vulkanDriver: URL { root.appendingPathComponent("Vulkan/icd.d/MoltenVK_icd.json") }

    func requireWine(_ architecture: BottleArchitecture) throws {
        guard FileManager.default.isExecutableFile(atPath: wine(architecture).path),
              FileManager.default.isExecutableFile(atPath: wineserver(architecture).path) else {
            throw HubError.engineUnavailable(architecture == .arm64ec
                ? "Open GooseHUB and complete the engine source installation."
                : "No separate x86_64 Wine engine is bundled in Engines/WineX64.")
        }
        // wineboot repeatedly retries a missing INF source, so detect incomplete
        // staging before reserving a bottle or starting any Wine processes.
        let data = wineRoot(architecture).appendingPathComponent("share/wine", isDirectory: true)
        let inf = data.appendingPathComponent("wine.inf")
        guard let contents = try? String(contentsOf: inf, encoding: .utf8) else {
            throw HubError.engineUnavailable("Wine bootstrap data is missing: \(inf.path)")
        }
        let sourceDirectories = ["WinmdFiles": "winmd", "NlsFiles": "nls", "SortFiles": "nls"]
        var section = ""
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }
            guard let directory = sourceDirectories[section], !line.isEmpty, !line.hasPrefix(";") else { continue }
            let filename = line.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
            guard !filename.isEmpty, filename == URL(fileURLWithPath: filename).lastPathComponent,
                  !filename.contains(".."),
                  FileManager.default.fileExists(atPath: data.appendingPathComponent(directory).appendingPathComponent(filename).path) else {
                throw HubError.engineUnavailable("Wine bootstrap source is missing or malformed: \(directory)/\(filename)")
            }
        }
    }

    func dxmtReady(_ architecture: BottleArchitecture) -> Bool {
        let primary = architecture == .arm64ec ? "arm64ec" : "x64"
        let unixArch = architecture == .arm64ec ? "aarch64-unix" : "x86_64-unix"
        // Wine provides d3d10/d3d10_1 entry wrappers; DXMT provides d3d10core.
        let required = DXMTDeployment.libraries
        return [primary, "x86"].allSatisfy { arch in
            required.allSatisfy { FileManager.default.fileExists(atPath: dxmtDirectory(arch).appendingPathComponent($0).path) }
        } && FileManager.default.fileExists(atPath: dllRoot(architecture)
            .appendingPathComponent("\(unixArch)/winemetal.so").path)
    }

    func status() -> EngineStatus {
        let fm = FileManager.default
        let wineAvailable = (try? requireWine(.arm64ec)) != nil
        let x64Available = (try? requireWine(.x64)) != nil
        let dxmtAvailable = dxmtReady(.arm64ec)
        let metalGooseCandidates = [
            root.appendingPathComponent("MetalGoose/bin/metalgoose-backend"),
            root.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("MacOS/metalgoose-backend")
        ]
        let metalGooseAvailable = metalGooseCandidates.contains { fm.isExecutableFile(atPath: $0.path) }
        let fexAvailable = ["aarch64-windows/xtajit64.dll", "aarch64-windows/xtajit.dll",
                            "aarch64-unix/libarm64ecfex.so", "aarch64-unix/libwow64fex.so"].allSatisfy {
            fm.fileExists(atPath: dllRoot(.arm64ec).appendingPathComponent($0).path)
        }
        let vulkanAvailable = fm.fileExists(atPath: vulkanDriver.path)
            && fm.fileExists(atPath: root.appendingPathComponent("Dependencies/arm64/libMoltenVK.dylib").path)
        var issues: [String] = []
        if !wineAvailable { issues.append("Wine Adrenalin Edition has not been installed.") }
        if !dxmtAvailable { issues.append("DXMT needs ARM64EC and x86 DLLs plus Wine’s native winemetal bridge.") }
        if !fexAvailable { issues.append("FEX guest translation modules are missing; x86/x64 support is unavailable.") }
        if !metalGooseAvailable { issues.append("MetalGoose has not been built.") }
        if !vulkanAvailable { issues.append("MoltenVK is missing; Vulkan programs find no device.") }
        let manifest = (try? Data(contentsOf: root.appendingPathComponent("manifest.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if manifest?["installationComplete"] as? Bool != true {
            issues.append("Complete the engine source installation before launching applications.")
        }
        return EngineStatus(rootPath: root.path, wineAvailable: wineAvailable,
                            wineX64Available: x64Available, dxmtAvailable: dxmtAvailable,
                            metalGooseAvailable: metalGooseAvailable, fexAvailable: fexAvailable,
                            vulkanAvailable: vulkanAvailable,
                            issues: issues, summary: wineAvailable ? "Native Wine engine detected" : "Runtime payload is missing",
                            versions: EngineVersions.read(from: root.appendingPathComponent("manifest.json")))
    }
}

struct RuntimeEnvironment {
    static func build(bottle: Bottle, prefix: URL, engines: EngineLayout,
                      inherited: [String: String], initialize: Bool = false) -> [String: String] {
        // An explicit allowlist prevents an existing Wine/CrossOver/Proton session
        // from changing this bottle or injecting a library into its host process.
        let allowed = ["LANG", "LC_ALL", "LC_CTYPE", "TZ", "TMPDIR", "USER", "LOGNAME",
                       "__CF_USER_TEXT_ENCODING", "DISPLAY"]
        var result = inherited.filter { allowed.contains($0.key) }
        result["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        result["PATH"] = engines.wineRoot(bottle.architecture).appendingPathComponent("bin").path
            + ":/usr/bin:/bin:/usr/sbin:/sbin"
        result["WINEPREFIX"] = prefix.path
        // Wine's ARM64 host also uses win64. There is no WINEARCH=arm64ec value.
        result["WINEARCH"] = "win64"
        result["WINESERVER"] = engines.wineserver(bottle.architecture).path
        result["WINEDLLPATH"] = engines.dllRoot(bottle.architecture).path
        result["WINEDEBUG"] = bottle.debugLogging ? "err+all,warn+all,fixme-all" : "err+all,fixme-all"
        result["WINEMSYNC"] = bottle.synchronization == .msync ? "1" : "0"
        result["GST_PLUGIN_SYSTEM_PATH_1_0"] = engines.root.appendingPathComponent("Media/gstreamer-1.0").path
        result["GST_PLUGIN_PATH_1_0"] = ""
        result["GST_PLUGIN_SCANNER"] = engines.root.appendingPathComponent("Media/bin/gst-plugin-scanner").path
        result["GST_REGISTRY_1_0"] = prefix.appendingPathComponent(".goose-gstreamer-registry.bin").path
        // Only the bundled driver: the loader would otherwise also take whatever Vulkan drivers
        // this Mac has installed, Homebrew's among them.
        if FileManager.default.fileExists(atPath: engines.vulkanDriver.path) {
            result["VK_DRIVER_FILES"] = engines.vulkanDriver.path
        }
        if bottle.renderer == .dxmt && !initialize {
            result["WINEDLLOVERRIDES"] = "d3d8,d3d9,d3d10core,d3d11,d3d12,dxgi=n,b;winemetal=b"
            result["MTL_HUD_ENABLED"] = bottle.dxmt.metalHUD ? "1" : "0"
            let configuration = engines.root.appendingPathComponent("Config/dxmt.conf")
            if FileManager.default.fileExists(atPath: configuration.path) {
                result["DXMT_CONFIG_FILE"] = configuration.path
            }
            result["DXMT_SHADER_CACHE"] = bottle.dxmt.shaderCache ? "1" : "0"
            var overrides = ["d3d11.asyncPipelineCompilation=\(bottle.dxmt.asyncPipelineCompilation ? "True" : "False")"]
            if let rate = bottle.dxmt.maximumFrameRate { overrides.append("d3d11.preferredMaxFrameRate=\(rate)") }
            result["DXMT_CONFIG"] = overrides.joined(separator: ";")
        } else {
            result["WINEDLLOVERRIDES"] = "d3d8,d3d9,d3d10core,d3d11,d3d12,dxgi=b;winemetal=b"
        }
        return result
    }
}

struct ProcessInvocation: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL

    static func application(bottle: Bottle, prefix: URL, executable: URL, arguments: [String],
                            engines: EngineLayout, inherited: [String: String],
                            settings: RuntimeSettings = RuntimeSettings()) -> ProcessInvocation {
        let wineArguments = executable.pathExtension.lowercased() == "msi"
            ? ["msiexec", "/i", executable.path] + arguments
            : [executable.path] + arguments
        var environment = RuntimeEnvironment.build(bottle: bottle, prefix: prefix, engines: engines, inherited: inherited)
        if bottle.architecture == .arm64ec {
            // Installer bootstraps can use extended arithmetic to reconstruct
            // file paths; reducing it to double precision changes characters.
            let fastX87 = settings.reducedX87Precision && !InstallerCompatibility.requiresFullX87Precision(executable)
            environment["FEX_X87REDUCEDPRECISION"] = fastX87 ? "1" : "0"
            if settings.legacyOpenGLBatching && engines.hasLegacyOpenGL {
                environment["WINE_GL_BATCHING_PATH"] = engines.legacyOpenGL.path
                environment["WINE_GL_BATCHING"] = "1"
            }
        }
        return ProcessInvocation(executable: engines.wine(bottle.architecture), arguments: wineArguments,
                                 environment: environment,
                                 workingDirectory: executable.deletingLastPathComponent())
    }
}
