import Foundation
import Subprocess

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(
        Data("Usage: TsBundleGen <input.ts> <output.swift>\n".utf8))
    exit(1)
}
let input = args[1]
let outputSwift = args[2]

let workDir = outputSwift.deletingLastPathComponent
let bundleJS = workDir.appendingPathComponent("bundle.js")

let proc = try await run(
    .name("esbuild"),
    arguments: Arguments([
        input,
        "--bundle",
        "--platform=browser",
        "--format=iife",
        "--outfile=\(bundleJS)"
    ]),
    output: .discarded
)

guard proc.terminationStatus.isSuccess else {
    FileHandle.standardError.write(Data("esbuild failed with (\(proc.terminationStatus))\n".utf8))
    if case .exited(let exitCode) = proc.terminationStatus {
        exit(exitCode)
    } else {
        exit(1)
    }
}

let js = try Data(contentsOf: URL(fileURLWithPath: bundleJS))
let b64 = js.base64EncodedString()

let source = """
    import Foundation

    public enum WebResources {
        public static let javascript: String = {
            guard let d = Data(base64Encoded: "\(b64)"), let s = String(data: d, encoding: .utf8) else {
                  fatalError("WebResources: failed to decode embedded bundle")
            }
            return s
        }()
    }
    """
try source.write(toFile: outputSwift, atomically: true, encoding: .utf8)
