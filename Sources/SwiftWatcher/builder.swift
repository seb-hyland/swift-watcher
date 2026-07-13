import Foundation
import Subprocess
import SystemPackage

actor Builder {
    private let serveDir: URL
    private let config: WatcherConfig
    private var buildDir: URL {
        self.serveDir.appending(path: self.config.buildDir)
    }
    private var workDir: URL {
        self.serveDir.appending(path: self.config.workDir)
    }

    private var current: OngoingBuild?
    var last: CompletedBuild?
    var currentId: BuildId? { self.current?.id }

    private class OngoingBuild {
        let baseBuildDir: URL
        let id: BuildId
        var buildDir: URL {
            self.baseBuildDir.appending(path: self.id.description)
        }

        var history: [BuildEvent]
        var continuations: [EventStream.Continuation]

        init(id: BuildId, in baseBuildDir: URL) {
            self.id = id
            self.baseBuildDir = baseBuildDir

            self.history = []
            self.continuations = []
        }

        deinit {
            for cont in self.continuations {
                // Close all streams
                cont.finish()
            }
        }

        func broadcast(event: BuildEvent) {
            self.history.append(event)
            for cont in self.continuations {
                cont.yield(event)
            }
        }

        func subscribe() -> BuildLog {
            let (stream, continuation) = EventStream.makeStream()
            self.continuations.append(continuation)
            return BuildLog(history: self.history, stream: stream)
        }

        func dumpLogs() {
            let fm = FileManager.default
            for event in self.history {
                let logFilePath = event.logFilePath(in: self.buildDir)

                do {
                    if !fm.fileExists(atPath: logFilePath.path) {
                        _ = fm.createFile(atPath: logFilePath.path, contents: nil)
                    }
                    let handle = try FileHandle(forWritingTo: logFilePath)

                    // Append to file
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(event.payload.utf8))
                    try handle.write(contentsOf: Data("\n".utf8))
                } catch {
                    // If an error occurs, just continue
                    continue
                }
            }

        }
    }

    struct CompletedBuild {
        let id: BuildId
        let timestamp: Date
        let dir: URL
    }

    init(in serveDir: URL, with config: WatcherConfig) {
        self.serveDir = serveDir
        self.config = config

        self.current = nil
        self.last = nil
    }

    typealias EventStream = AsyncStream<BuildEvent>
    struct BuildEvent: Codable {
        enum BuildEventType: String, Codable {
            case message
            case error
        }

        let type: BuildEventType
        let payload: String
        let stage: UInt32

        func logFilePath(in buildDir: URL) -> URL {
            let fileName =
                switch self.type {
                    case .message: ".watcher_log_\(self.stage)"
                    case .error: ".watcher_err_\(self.stage)"
                }
            return buildDir.appending(path: fileName)
        }
    }

    struct BuildLog {
        let history: [BuildEvent]
        let stream: EventStream
    }

    func subscribe() -> (id: BuildId, log: BuildLog)? {
        if let curBuild = self.current {
            return (id: curBuild.id, log: curBuild.subscribe())
        } else {
            return nil
        }
    }

    func subscribeCompleted(id: BuildId) -> BuildLog {
        precondition(
            self.current?.id != id, "subscribeCompleted called with ongoing build id \(id)"
        )

        let (stream, continuation) = EventStream.makeStream()

        // Stream as a continuation that loads background files asynchronously
        Task {
            let thisBuildDir = self.buildDir.appending(path: id.description)

            for stageIdx in 0..<self.config.buildStages.count {
                let stageIdx = UInt32(stageIdx)

                let msgEvent = BuildEvent(type: .message, payload: "", stage: stageIdx)
                let errEvent = BuildEvent(type: .error, payload: "", stage: stageIdx)

                let msgLogsPath = msgEvent.logFilePath(in: thisBuildDir)
                let errLogsPath = errEvent.logFilePath(in: thisBuildDir)

                if let msgLogs = try? Data(contentsOf: msgLogsPath) {
                    continuation.yield(
                        BuildEvent(
                            type: .message,
                            payload: String(buffer: .init(data: msgLogs)),
                            stage: stageIdx
                        )
                    )
                }
                if let errLogs = try? Data(contentsOf: errLogsPath) {
                    continuation.yield(
                        BuildEvent(
                            type: .error,
                            payload: String(buffer: .init(data: errLogs)),
                            stage: stageIdx
                        )
                    )
                }
            }
        }

        return BuildLog(history: [], stream: stream)
    }

    /// Triggers a rebuild or subscribes to the ongoing rebuild
    func tryRebuild() -> BuildId {
        if let currentBuild = self.current {
            return currentBuild.id
        }

        let newBuildId = BuildId()
        let newBuild = OngoingBuild(id: newBuildId, in: self.buildDir)
        self.current = newBuild

        // Start the build task, but do not await it within this actor
        Task { await self.driveBuild(ongoing: newBuild) }

        return newBuildId
    }

    /// Build directories that must never be reclaimed during cleanup:
    func preservedBuildIds() -> Set<String> {
        Set([self.current?.id.description, self.last?.id.description].compactMap { $0 })
    }

    private func driveBuild(ongoing currentBuild: OngoingBuild) async {
        defer {
            currentBuild.dumpLogs()
            self.current = nil
        }

        // Holds logs and (on success) output artifact
        let curBuildDir = self.buildDir.appending(path: currentBuild.id.description)
        let workDir = self.workDir

        let createDirRes = Result {
            try FileManager.default.createDirectory(
                at: curBuildDir, withIntermediateDirectories: true)
        }
        if case .failure(let err) = createDirRes {
            currentBuild.broadcast(
                event:
                    BuildEvent(
                        type: .error,
                        payload:
                            "Failed to create build output directory at \(curBuildDir): \(err)",
                        stage: 0)
            )
            return
        }

        for (stageIdx, stage) in self.config.buildStages.enumerated() {
            switch await self.driveStage(
                UInt32(stageIdx), of: currentBuild, in: workDir, stage: stage)
            {
                // Terminate immediately on failure
                case .failed: return
                case .succeeded: ()
            }
        }

        let lastStageIdx = UInt32(self.config.buildStages.count).saturatingSub(1)

        // Copy build artifact to build output dir
        let srcArtifact = workDir.appending(path: self.config.artifactPath)
        let dstArtifact = curBuildDir.appending(path: self.config.artifactPath)

        if !FileManager.default.fileExists(atPath: srcArtifact.path) {
            currentBuild.broadcast(
                event: BuildEvent(
                    type: .error,
                    payload: "Expected build output at \(srcArtifact) was not created",
                    stage: lastStageIdx
                )
            )
            return
        }

        let copyRes = Result {
            try FileManager.default.createDirectory(
                at: dstArtifact.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: srcArtifact, to: dstArtifact)
        }
        if case .failure(let err) = copyRes {
            currentBuild.broadcast(
                event: BuildEvent(
                    type: .error,
                    payload:
                        "Failed to copy artifact from \(srcArtifact) to \(dstArtifact): \(err)",
                    stage: lastStageIdx
                )
            )
            return
        }

        // Only on success
        self.last = CompletedBuild(id: currentBuild.id, timestamp: Date(), dir: dstArtifact)
    }

    enum StageResult {
        case succeeded
        case failed
    }

    private func driveStage(
        _ stageIdx: UInt32,
        of currentBuild: OngoingBuild,
        in workingDir: URL,
        stage: BuildStage
    ) async -> StageResult {
        let spawnResult = await Result {
            try await run(
                .name("sh"),
                arguments: Arguments(["-c", stage.script]),
                workingDirectory: FilePath(workingDir.path),
                error: .combinedWithOutput
            ) { _, stdout in
                for try await line in stdout.lines() {
                    currentBuild.broadcast(
                        event: BuildEvent(type: .message, payload: line, stage: stageIdx)
                    )
                }
            }
        }

        let exitStatus: ExecutionOutcome<()>
        switch spawnResult {
            case .success(let status): exitStatus = status
            case .failure(let err):
                currentBuild.broadcast(
                    event: BuildEvent(
                        type: .error,
                        payload: "Failed to run stage \"\(stage.name)\": \(err)",
                        stage: stageIdx
                    )
                )
                return .failed
        }

        if !exitStatus.terminationStatus.isSuccess {
            currentBuild.broadcast(
                event: BuildEvent(
                    type: .error,
                    payload: "Build failed with code \(exitStatus.terminationStatus)",
                    stage: stageIdx))
            return .failed
        }

        currentBuild.broadcast(
            event: BuildEvent(
                type: .message,
                payload: "========== Stage completed successfully ==========",
                stage: stageIdx))
        return .succeeded
    }
}
