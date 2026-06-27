import BetterCodable
import Foundation

struct DefaultIp: DefaultCodableStrategy {
    static var defaultValue: String { return "127.0.0.1" }
}

struct DefaultPort: DefaultCodableStrategy {
    static var defaultValue: Int32 { return 9999 }
}

struct DefaultBuildDir: DefaultCodableStrategy {
    static var defaultValue: String { return "builds/" }
}

// Config is not mutated after load
// @unchecked is required because @DefaultCodable mutates once after load
struct WatcherConfig: Codable, @unchecked Sendable {
    @DefaultCodable<DefaultIp> var ip: String
    @DefaultCodable<DefaultPort> var port: Int32

    @DefaultCodable<DefaultBuildDir> var buildDir: String
    let buildStages: [BuildStage]
    let artifactPath: String
}

struct BuildStage: Codable, Sendable {
    let name: String
    let program: String
    let args: [String]
}
