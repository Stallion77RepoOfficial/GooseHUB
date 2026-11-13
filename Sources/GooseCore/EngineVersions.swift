import Foundation

/// Version labels come from the bundled payload's manifest, never the host's Wine installation.
public struct EngineVersions: Codable, Equatable, Sendable {
    public let wine: String?
    public let dxmt: String?
    public let fex: String?
    public let reviewedAt: String?

    static func read(from url: URL) -> EngineVersions? {
        struct Component: Decodable {
            let version: String?
            let commit: String?
            let upstreamCommit: String?
        }
        struct Manifest: Decodable {
            let wine: Component?
            let dxmt: Component?
            let fex: Component?
            let sourceReviewDate: String?
        }
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        func label(_ component: Component?) -> String? {
            component?.version ?? component?.upstreamCommit.map { String($0.prefix(10)) }
                ?? component?.commit.map { String($0.prefix(10)) }
        }
        return EngineVersions(wine: label(manifest.wine), dxmt: label(manifest.dxmt),
                              fex: label(manifest.fex), reviewedAt: manifest.sourceReviewDate)
    }
}
