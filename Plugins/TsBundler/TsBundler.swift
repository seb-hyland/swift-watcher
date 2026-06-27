import Foundation
import PackagePlugin

@main
struct WebBundlePlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let target = target.sourceModule else { return [] }

        let generator = try context.tool(named: "TsBundleGen")
        let webDir = target.directoryURL.appending(path: "Web")
        let entry = webDir.appending(path: "main.ts")
        let output = context.pluginWorkDirectoryURL.appending(path: "WebBundle.swift")

        // Declare ALL web sources as inputs so edits to imported modules
        // re-trigger the bundle, not just changes to main.ts.
        let fm = FileManager.default
        let inputs: [URL] =
            (fm.enumerator(at: webDir, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { ["ts", "tsx", "js", "jsx", "css", "json"].contains($0.pathExtension) })
            ?? [entry]

        return [
            .buildCommand(
                displayName: "Bundling web assets with esbuild",
                executable: generator.url,
                arguments: [entry.path(), output.path()],
                inputFiles: inputs,
                outputFiles: [output]
            )
        ]
    }
}
