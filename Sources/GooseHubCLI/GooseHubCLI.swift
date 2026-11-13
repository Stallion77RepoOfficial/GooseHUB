import Darwin
import Foundation
import GooseCore

@main
enum GooseHubCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else { print(usage); return }
            let tail = Array(arguments.dropFirst())
            let service = HubService()
            switch command {
            case "diagnose":
                let status = await service.diagnose()
                if tail.contains("--json") { try printJSON(status) }
                else {
                    print(status.summary)
                    print("Engines: \(status.rootPath)")
                    print("Wine ARM64: \(status.wineAvailable), Wine x64: \(status.wineX64Available), DXMT: \(status.dxmtAvailable), FEX: \(status.fexAvailable), MetalGoose: \(status.metalGooseAvailable)")
                    for issue in status.issues { print("• \(issue)") }
                }
            case "list":
                let bottles = try await service.listBottles()
                if tail.contains("--json") { try printJSON(bottles) }
                else if bottles.isEmpty { print("No Goose HUB bottles yet.") }
                else {
                    for bottle in bottles {
                        print("\(bottle.id.uuidString.lowercased())\t\(bottle.name)\t\(bottle.architecture.rawValue)\t\(bottle.renderer.rawValue)\t\(bottle.state.rawValue)")
                    }
                }
            case "create":
                guard let name = tail.first, !name.hasPrefix("--") else { throw CLIError.usage("create requires NAME") }
                var architecture = BottleArchitecture.arm64ec
                var renderer = Renderer.dxmt
                var synchronization = SynchronizationMode.msync
                var windowsVersion = WindowsVersion.win10
                var json = false
                var index = 1
                while index < tail.count {
                    let option = tail[index]
                    if option == "--json" { json = true; index += 1; continue }
                    guard index + 1 < tail.count else { throw CLIError.usage("Missing value for \(option)") }
                    let value = tail[index + 1]
                    switch option {
                    case "--architecture":
                        guard let parsed = BottleArchitecture(rawValue: value) else { throw CLIError.usage("architecture must be arm64ec or x64") }
                        architecture = parsed
                    case "--renderer":
                        guard let parsed = Renderer(rawValue: value) else { throw CLIError.usage("renderer must be dxmt or wined3d") }
                        renderer = parsed
                    case "--sync":
                        guard let parsed = SynchronizationMode(rawValue: value) else { throw CLIError.usage("sync must be msync or none") }
                        synchronization = parsed
                    case "--windows":
                        guard let parsed = WindowsVersion(rawValue: value) else {
                            throw CLIError.usage("windows must be one of " + WindowsVersion.allCases.map(\.rawValue).joined(separator: ", "))
                        }
                        windowsVersion = parsed
                    default: throw CLIError.usage("Unknown option \(option)")
                    }
                    index += 2
                }
                let bottle = try await service.createBottle(name: name, architecture: architecture, renderer: renderer,
                                                            synchronization: synchronization, windowsVersion: windowsVersion)
                if json { try printJSON(bottle) }
                else { print("\(bottle.id.uuidString.lowercased())\t\(bottle.name)") }
            case "run":
                guard tail.count >= 2 else { throw CLIError.usage("run requires BOTTLE_ID and EXE or MSI") }
                let id = try bottleID(tail[0])
                let launch = try await service.run(bottleID: id, executable: URL(fileURLWithPath: tail[1]),
                                                   arguments: Array(tail.dropFirst(2)))
                print("PID \(launch.processIdentifier) — \(launch.logPath)")
                let completed = try await service.waitForLaunch(launch.id)
                print("\(completed.status.rawValue) (\(completed.exitCode ?? -1))")
                if let code = completed.exitCode, code != 0 { Darwin.exit(code > 0 && code < 126 ? code : 1) }
            case "stop":
                guard tail.count == 1 else { throw CLIError.usage("stop requires BOTTLE_ID") }
                try await service.stop(bottleID: bottleID(tail[0]))
                print("Stopped this bottle’s Wine server.")
            case "tool":
                guard tail.count == 2, let tool = WineTool(rawValue: tail[1]) else {
                    throw CLIError.usage("tool requires BOTTLE_ID and one of " + WineTool.allCases.map(\.rawValue).joined(separator: ", "))
                }
                let launch = try await service.runTool(bottleID: bottleID(tail[0]), tool: tool)
                print("PID \(launch.processIdentifier) — \(launch.logPath)")
                let completed = try await service.waitForLaunch(launch.id)
                print("\(completed.status.rawValue) (\(completed.exitCode ?? -1))")
            case "set":
                guard tail.count >= 3, tail.count % 2 == 1 else { throw CLIError.usage("set requires BOTTLE_ID and OPTION VALUE pairs") }
                let id = try bottleID(tail[0])
                guard var bottle = try await service.listBottles().first(where: { $0.id == id }) else {
                    throw HubError.bottleNotFound(id)
                }
                for index in stride(from: 1, to: tail.count, by: 2) {
                    let value = tail[index + 1]
                    switch tail[index] {
                    case "--windows":
                        guard let parsed = WindowsVersion(rawValue: value) else {
                            throw CLIError.usage("windows must be one of " + WindowsVersion.allCases.map(\.rawValue).joined(separator: ", "))
                        }
                        bottle.windowsVersion = parsed
                    case "--high-resolution":
                        guard ["on", "off"].contains(value) else { throw CLIError.usage("high-resolution must be on or off") }
                        bottle.highResolution = value == "on"
                    case "--renderer":
                        guard let parsed = Renderer(rawValue: value) else { throw CLIError.usage("renderer must be dxmt or wined3d") }
                        bottle.renderer = parsed
                    case "--sync":
                        guard let parsed = SynchronizationMode(rawValue: value) else { throw CLIError.usage("sync must be msync or none") }
                        bottle.synchronization = parsed
                    case "--fps":
                        if value == "unlimited" { bottle.dxmt.maximumFrameRate = nil }
                        else {
                            guard let rate = Int(value), (15...1000).contains(rate) else {
                                throw CLIError.usage("fps must be unlimited or an integer from 15 to 1000")
                            }
                            bottle.dxmt.maximumFrameRate = rate
                        }
                    case "--shader-cache", "--metal-hud":
                        guard ["on", "off"].contains(value) else { throw CLIError.usage("\(tail[index]) must be on or off") }
                        if tail[index] == "--shader-cache" { bottle.dxmt.shaderCache = value == "on" }
                        else { bottle.dxmt.metalHUD = value == "on" }
                    case "--shader-compilation":
                        guard ["complete", "background"].contains(value) else {
                            throw CLIError.usage("shader-compilation must be complete or background")
                        }
                        bottle.dxmt.asyncPipelineCompilation = value == "background"
                    default: throw CLIError.usage("Unknown option \(tail[index])")
                    }
                }
                try await service.updateBottle(bottle)
                try printJSON(try await service.listBottles().first { $0.id == id })
            case "rename":
                guard tail.count == 2 else { throw CLIError.usage("rename requires BOTTLE_ID NAME") }
                try printJSON(try await service.renameBottle(bottleID: bottleID(tail[0]), name: tail[1]))
            case "duplicate":
                guard tail.count == 2 else { throw CLIError.usage("duplicate requires BOTTLE_ID NAME") }
                let copy = try await service.duplicateBottle(bottleID: bottleID(tail[0]), name: tail[1])
                print("\(copy.id.uuidString.lowercased())\t\(copy.name)")
            case "delete":
                guard tail.count == 1 else { throw CLIError.usage("delete requires BOTTLE_ID") }
                try await service.deleteBottle(bottleID: bottleID(tail[0]))
                print("Moved the bottle to the Trash.")
            case "add":
                guard tail.count >= 3 else { throw CLIError.usage("add requires BOTTLE_ID NAME EXE") }
                let bottle = try await service.addApplication(bottleID: bottleID(tail[0]), name: tail[1],
                    executable: URL(fileURLWithPath: tail[2]), arguments: Array(tail.dropFirst(3)))
                try printJSON(bottle)
            case "history":
                guard tail.count == 1 else { throw CLIError.usage("history requires BOTTLE_ID") }
                try printJSON(await service.launchHistory(bottleID: bottleID(tail[0])))
            case "path":
                guard tail.count == 1 else { throw CLIError.usage("path requires BOTTLE_ID") }
                print(try await service.prefixDirectory(bottleID(tail[0])).path)
            case "help", "--help", "-h": print(usage)
            default: throw CLIError.usage("Unknown command: \(command)")
            }
        } catch {
            let message = "goosehub-cli: \(error.localizedDescription)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            Darwin.exit(1)
        }
    }

    private static func bottleID(_ string: String) throws -> UUID {
        guard let id = UUID(uuidString: string) else { throw CLIError.usage("BOTTLE_ID must be a UUID") }
        return id
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        print(String(decoding: data, as: UTF8.self))
    }

    private static let usage = """
    Goose HUB Adrenalin Edition
      goosehub-cli diagnose [--json]
      goosehub-cli list [--json]
      goosehub-cli create NAME [--architecture arm64ec|x64] [--renderer dxmt|wined3d] [--sync msync|none]
                          [--windows win11|win10|win81|win8|win7|winxp64] [--json]
      goosehub-cli run BOTTLE_ID EXE_OR_MSI [arguments...]
      goosehub-cli add BOTTLE_ID NAME EXE [arguments...]
      goosehub-cli stop BOTTLE_ID
      goosehub-cli tool BOTTLE_ID configuration|controlPanel|registryEditor|taskManager|commandPrompt|uninstaller|reboot
      goosehub-cli set BOTTLE_ID [--windows win11|win10|win81|win8|win7|winxp64] [--high-resolution on|off]
                   [--renderer dxmt|wined3d] [--sync msync|none] [--fps unlimited|15...1000]
                   [--shader-cache on|off] [--shader-compilation complete|background] [--metal-hud on|off]
      goosehub-cli rename BOTTLE_ID NAME
      goosehub-cli duplicate BOTTLE_ID NAME
      goosehub-cli delete BOTTLE_ID
      goosehub-cli history BOTTLE_ID
      goosehub-cli path BOTTLE_ID

    GOOSE_ENGINES_ROOT selects a staged Engines directory.
    GOOSE_DATA_ROOT selects isolated Goose HUB storage for testing.
    Native ARM64 Wine is used by default. Guest compatibility must be tested per application.
    """
}

private enum CLIError: Error, LocalizedError {
    case usage(String)
    var errorDescription: String? {
        switch self { case .usage(let message): "\(message). Use goosehub-cli --help." }
    }
}
