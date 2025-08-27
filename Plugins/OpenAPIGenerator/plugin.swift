// swift-tools-version:6.1
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftOpenAPIGenerator open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftOpenAPIGenerator project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftOpenAPIGenerator project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import PackagePlugin
import Foundation

@main struct SwiftOpenAPIGeneratorPlugin {
    /// Attempt to locate the tool in DerivedData Build/Products when the provided path contains unexpanded variables
    /// or points to a non-existent configuration directory.
    private func searchDerivedDataForBinary(_ binaryName: String, anchor: URL?) -> URL? {
        let fm = FileManager.default
        func buildProductsDirs(from root: URL) -> [URL] {
            let products = root.appendingPathComponent("Build", isDirectory: true)
                .appendingPathComponent("Products", isDirectory: true)
            var dirs: [URL] = []
            if fm.fileExists(atPath: products.path) { dirs.append(products) }
            return dirs
        }
        var candidates: [URL] = []
        if let anchor = anchor {
            let comps = anchor.path.split(separator: "/").map(String.init)
            if let ddIndex = comps.firstIndex(of: "DerivedData"), ddIndex + 1 < comps.count {
                let projectComponent = comps[ddIndex + 1]
                let derivedDataRoot = URL(fileURLWithPath: "/" + comps.prefix(ddIndex + 2).joined(separator: "/"), isDirectory: true)
                candidates.append(contentsOf: buildProductsDirs(from: derivedDataRoot.appendingPathComponent(projectComponent, isDirectory: true)))
            }
        }
        if candidates.isEmpty {
            let dd = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
            if let contents = try? fm.contentsOfDirectory(at: dd, includingPropertiesForKeys: nil) {
                for child in contents where child.hasDirectoryPath {
                    candidates.append(contentsOf: buildProductsDirs(from: child))
                }
            }
        }
        let preferredSuffixes = ["-maccatalyst"]
        for dir in candidates {
            if let subs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                let ordered = subs.sorted { a, b in
                    preferredSuffixes.contains(where: { a.lastPathComponent.hasSuffix($0) }) && !preferredSuffixes.contains(where: { b.lastPathComponent.hasSuffix($0) })
                }
                for sub in ordered where sub.hasDirectoryPath {
                    let candidate = sub.appendingPathComponent(binaryName, isDirectory: false)
                    if fm.isExecutableFile(atPath: candidate.path) { return candidate }
                }
            }
        }
        return nil
    }
    /// Workaround for SwiftPM returning a tool URL under `Debug/` or `Release/`
    /// while the actual binary is emitted under `Debug-maccatalyst/` or `Release-maccatalyst/`.
    private func resolveToolURLForMacCatalyst(_ url: URL, anchor: URL?) -> URL {
        let fileManager = FileManager.default
        if fileManager.isExecutableFile(atPath: url.path) { return url }
        let configDirURL = url.deletingLastPathComponent()
        let parentDirURL = configDirURL.deletingLastPathComponent()
        let configName = configDirURL.lastPathComponent
        let binaryName = url.lastPathComponent
        let candidateNames: [String]
        if configName.hasSuffix("-maccatalyst") {
            candidateNames = [configName]
        } else {
            candidateNames = ["\(configName)-maccatalyst"]
        }
        for candidate in candidateNames {
            let candidateURL = parentDirURL.appendingPathComponent(candidate, isDirectory: true)
                .appendingPathComponent(binaryName, isDirectory: false)
            if fileManager.isExecutableFile(atPath: candidateURL.path) { return candidateURL }
        }
        if let found = searchDerivedDataForBinary(binaryName, anchor: anchor) { return found }
        return url
    }
    func createBuildCommands(
        pluginWorkDirectoryURL: URL,
        tool: URL,
        sourceFiles: FileList,
        targetName: String
    ) throws -> [Command] {
        let inputs = try PluginUtils.validateInputs(
            workingDirectoryURL: pluginWorkDirectoryURL,
            tool: tool,
            sourceFiles: sourceFiles,
            targetName: targetName,
            pluginSource: .build
        )

        let outputFiles: [URL] = GeneratorMode.allCases.map { inputs.genSourcesDirURL.appendingPathComponent($0.outputFileName) }
        return [
            .buildCommand(
                displayName: "Running swift-openapi-generator",
                executable: inputs.tool,
                arguments: inputs.arguments,
                environment: [:],
                inputFiles: [inputs.configURL, inputs.docURL],
                outputFiles: outputFiles
            )
        ]
    }
}

extension SwiftOpenAPIGeneratorPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let tool = resolveToolURLForMacCatalyst(try context.tool(named: "swift-openapi-generator").url, anchor: context.pluginWorkDirectoryURL)
        guard let swiftTarget = target as? SwiftSourceModuleTarget else {
            throw PluginError.incompatibleTarget(name: target.name)
        }
        return try createBuildCommands(
            pluginWorkDirectoryURL: context.pluginWorkDirectoryURL,
            tool: tool,
            sourceFiles: swiftTarget.sourceFiles,
            targetName: target.name
        )
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin
import CoreLocation

extension SwiftOpenAPIGeneratorPlugin: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        let tool = resolveToolURLForMacCatalyst(try context.tool(named: "swift-openapi-generator").url, anchor: context.pluginWorkDirectoryURL)
        return try createBuildCommands(
            pluginWorkDirectoryURL: context.pluginWorkDirectoryURL,
            tool: tool,
            sourceFiles: target.inputFiles,
            targetName: target.displayName
        )
    }
}
#endif
