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
                guard let logFilePath = event.logFilePath(in: self.buildDir) else {
                    // Lifecycle event; nothing to persist.
                    continue
                }

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
            // A stage finished; `success` says whether it passed.
            case stageResult
            // The whole build finished; `success` says whether it passed.
            case buildResult
        }

        let type: BuildEventType
        let payload: String
        let stage: UInt32
        // Only set for `stageResult` / `buildResult`.
        let success: Bool?

        init(type: BuildEventType, payload: String, stage: UInt32, success: Bool? = nil) {
            self.type = type
            self.payload = payload
            self.stage = stage
            self.success = success
        }

        // Nil for lifecycle events, which are reconstructed on replay
        func logFilePath(in buildDir: URL) -> URL? {
            let fileName: String
            switch self.type {
                case .message: fileName = ".watcher_log_\(self.stage)"
                case .error: fileName = ".watcher_err_\(self.stage)"
                case .stageResult, .buildResult: return nil
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

        // Replay a finished build from its on-disk logs, reconstructing results
        Task {
            let thisBuildDir = self.buildDir.appending(path: id.description)
            var sawError = false
            var lastStageWithOutput = -1

            for stageIdx in 0..<self.config.buildStages.count {
                let stage = UInt32(stageIdx)

                let msgPath = thisBuildDir.appending(path: ".watcher_log_\(stage)")
                let errPath = thisBuildDir.appending(path: ".watcher_err_\(stage)")

                let msgData = try? Data(contentsOf: msgPath)
                let errData = try? Data(contentsOf: errPath)

                // Drop the trailing newline so replay matches the live stream
                func trimTrailingNewline(_ s: String) -> String {
                    s.hasSuffix("\n") ? String(s.dropLast()) : s
                }

                if let msgData, !msgData.isEmpty {
                    continuation.yield(
                        BuildEvent(
                            type: .message,
                            payload: trimTrailingNewline(String(decoding: msgData, as: UTF8.self)),
                            stage: stage
                        )
                    )
                    lastStageWithOutput = stageIdx
                }

                if let errData, !errData.isEmpty {
                    continuation.yield(
                        BuildEvent(
                            type: .error,
                            payload: trimTrailingNewline(String(decoding: errData, as: UTF8.self)),
                            stage: stage
                        )
                    )
                    continuation.yield(
                        BuildEvent(type: .stageResult, payload: "", stage: stage, success: false))
                    sawError = true
                    lastStageWithOutput = stageIdx
                    // The build stops at the first failing stage.
                    break
                } else if msgData != nil {
                    continuation.yield(
                        BuildEvent(type: .stageResult, payload: "", stage: stage, success: true))
                }
            }

            // Only assert a verdict if something was found on disk
            if sawError || lastStageWithOutput >= 0 {
                continuation.yield(
                    BuildEvent(
                        type: .buildResult,
                        payload: "",
                        stage: UInt32(max(0, lastStageWithOutput)),
                        success: !sawError
                    )
                )
            }
            continuation.finish()
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
            // Stages run here; must exist before the first stage spawns
            try FileManager.default.createDirectory(
                at: workDir, withIntermediateDirectories: true)
        }
        if case .failure(let err) = createDirRes {
            currentBuild.broadcast(
                event:
                    BuildEvent(
                        type: .error,
                        payload:
                            "Failed to create build directories: \(err)",
                        stage: 0)
            )
            currentBuild.broadcast(
                event: BuildEvent(type: .buildResult, payload: "", stage: 0, success: false))
            return
        }

        for (stageIdx, stage) in self.config.buildStages.enumerated() {
            switch await self.driveStage(
                UInt32(stageIdx), of: currentBuild, in: workDir, stage: stage)
            {
                // Terminate immediately on failure
                case .failed:
                    currentBuild.broadcast(
                        event: BuildEvent(
                            type: .buildResult, payload: "", stage: UInt32(stageIdx),
                            success: false))
                    return
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
            currentBuild.broadcast(
                event: BuildEvent(
                    type: .buildResult, payload: "", stage: lastStageIdx, success: false))
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
            currentBuild.broadcast(
                event: BuildEvent(
                    type: .buildResult, payload: "", stage: lastStageIdx, success: false))
            return
        }

        // Only on success
        self.last = CompletedBuild(id: currentBuild.id, timestamp: Date(), dir: dstArtifact)
        currentBuild.broadcast(
            event: BuildEvent(type: .buildResult, payload: "", stage: lastStageIdx, success: true))
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
        func fail(_ message: String) -> StageResult {
            currentBuild.broadcast(
                event: BuildEvent(type: .error, payload: message, stage: stageIdx))
            currentBuild.broadcast(
                event: BuildEvent(type: .stageResult, payload: "", stage: stageIdx, success: false))
            return .failed
        }

        // A pipe keeps tools in non-interactive mode; `lines()` streams output
        // as it arrives so the dashboard updates line-by-line.
        let result = await Result {
            try await run(
                .name("sh"),
                arguments: Arguments(["-c", stage.script]),
                workingDirectory: FilePath(workingDir.path),
                error: .combinedWithOutput
            ) { _, stdout in
                for try await line in stdout.lines() {
                    currentBuild.broadcast(
                        event: BuildEvent(type: .message, payload: line, stage: stageIdx))
                }
            }
        }

        switch result {
            case .failure(let err):
                return fail("Failed to run stage \"\(stage.name)\": \(err)")
            case .success(let outcome) where !outcome.terminationStatus.isSuccess:
                return fail("Stage failed with code \(outcome.terminationStatus)")
            case .success: ()
        }

        currentBuild.broadcast(
            event: BuildEvent(type: .stageResult, payload: "", stage: stageIdx, success: true))
        return .succeeded
    }
}
