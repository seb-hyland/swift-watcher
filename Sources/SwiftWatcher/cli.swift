import Foundation
import TOMLDecoder

@main
struct SwiftWatcher {
    static let CONFIG_FILE_NAME = "config.toml"

    static func main() async {
        let initArgs = CommandLine.arguments
        let serveDir = initArgs[safe: 1] ?? FileManager.default.currentDirectoryPath
        if !FileManager.default.fileExists(atPath: serveDir) {
            fatalError("Configured serve directory at \(serveDir) does not exist!")
        }
        let serveDirPath = URL(fileURLWithPath: serveDir)

        let configFilePath = serveDirPath.appending(path: self.CONFIG_FILE_NAME)
        let configData: Data =
            switch Result(catching: { try Data(contentsOf: configFilePath) }) {
                case .success(let data): data
                case .failure(let err):
                    fatalError(
                        "Failed to open config file at \(configFilePath) due to error \(err)"
                    )
            }
        let configParseResult = Result {
            try TOMLDecoder().decode(WatcherConfig.self, from: configData)
        }
        let config: WatcherConfig =
            switch configParseResult {
                case .success(let config): config
                case .failure(let err):
                    fatalError(
                        "Failed to parse config file at \(configFilePath) due to error \(err)"
                    )
            }

        let server = Server(in: serveDirPath, withConfig: config)
        await server.run()
    }
}
