import Foundation

/**
    Periodically reclaims stale build directories under `buildDir`.
    Does not touch the currently served build.
*/
actor Cleaner {
    static let expiry = TimeInterval(60 * 60)
    static let sweep = Duration.seconds(5 * 60)

    private let buildDir: URL
    private let builder: Builder

    init(
        buildDir: URL,
        builder: Builder,
    ) {
        self.buildDir = buildDir
        self.builder = builder
    }

    /// Main entrypoint. Runs until cancelled
    func run() async {
        while !Task.isCancelled {
            await self.sweep()
            do {
                try await Task.sleep(for: Self.sweep)
            } catch {
                // Cancelled
                return
            }
        }
    }

    private func sweep() async {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Self.expiry)
        let preserved = await self.builder.preservedBuildIds()

        guard let entries = try? fm.contentsOfDirectory(
                at: self.buildDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            if preserved.contains(name) { continue }

            let modDate = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modDate, modDate < cutoff else { continue }

            try? fm.removeItem(at: entry)
        }
    }
}
