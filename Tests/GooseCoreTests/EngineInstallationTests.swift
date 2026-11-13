import Foundation
import XCTest
@testable import GooseCore

final class EngineInstallationTests: XCTestCase {
    func testIncompleteInstallationDoesNotCreateABottle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = directory.appendingPathComponent("data")
        let service = HubService(dataRoot: data, enginesRoot: directory.appendingPathComponent("Engines"), environment: [:])
        do {
            _ = try await service.createBottle(name: "Games")
            XCTFail("An incomplete engine installation must not create a bottle")
        } catch HubError.engineUnavailable(let reason) {
            XCTAssertTrue(reason.contains("installation"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("Bottles").path))
    }
}
