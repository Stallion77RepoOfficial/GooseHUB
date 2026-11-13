import XCTest
@testable import GooseCore

final class LaunchArgumentsTests: XCTestCase {
    func testCounterStrikeOptionsAreSeparateArguments() {
        XCTAssertEqual(LaunchArguments.parse("-game cstrike"), ["-game", "cstrike"])
        XCTAssertEqual(LaunchArguments.parse("-game\ncstrike\n-windowed\n"), ["-game", "cstrike", "-windowed"])
        XCTAssertEqual(LaunchArguments.parse(" \t \n"), [])
    }

    func testWindowsQuotedPathsAndBackslashes() {
        XCTAssertEqual(LaunchArguments.parse(#"--config "C:\Program Files\Counter Strike\config.cfg" -game cstrike"#),
                       ["--config", #"C:\Program Files\Counter Strike\config.cfg"#, "-game", "cstrike"])
        XCTAssertEqual(LaunchArguments.parse(#""C:\Games\CS 1.6\\" "" "say \"hello\"""#),
                       [#"C:\Games\CS 1.6\"#, "", #"say "hello""#])
        XCTAssertEqual(LaunchArguments.parse(#"a\\\b d"e f"g h"#), [#"a\\\b"#, "de fg", "h"])
        XCTAssertEqual(LaunchArguments.parse(#"a"b"" c d"#), [#"ab" c d"#])
        XCTAssertEqual(LaunchArguments.parse(#"C:\Games\ -game cstrike"#), [#"C:\Games\"#, "-game", "cstrike"])
    }

    func testEditingPreservesEverySavedValue() {
        let saved = ["-game", "cstrike", "", #"C:\Program Files\CS 1.6\"#, "two\nlines", #"say "hello""#,
                     "O'Brien", "Türkçe içerik", "$(touch never-run)", "a;b", "*.cfg"]
        XCTAssertEqual(LaunchArguments.parse(LaunchArguments.format(saved)), saved)
        // A saved single value is never silently split when its editor opens.
        XCTAssertEqual(LaunchArguments.parse(LaunchArguments.format(["-game cstrike"])), ["-game cstrike"])
    }

    func testLaunchInvocationKeepsParsedBoundariesAndGameDirectory() {
        let exe = URL(fileURLWithPath: "/games/Counter Strike/hl.exe")
        let invocation = ProcessInvocation.application(bottle: Bottle(name: "CS"),
            prefix: URL(fileURLWithPath: "/prefix"), executable: exe,
            arguments: LaunchArguments.parse("-game cstrike"),
            engines: EngineLayout(root: URL(fileURLWithPath: "/engines"), environment: [:]), inherited: [:])
        XCTAssertEqual(invocation.arguments, [exe.path, "-game", "cstrike"])
        XCTAssertEqual(invocation.workingDirectory, exe.deletingLastPathComponent())
    }
}
