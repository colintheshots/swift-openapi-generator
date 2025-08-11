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
    func createBuildCommands(
        pluginWorkDirectoryURL: URL,
        tool: PluginContext.Tool,
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
                executable: inputs.tool.url,
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
        guard let swiftTarget = target as? SwiftSourceModuleTarget else {
            throw PluginError.incompatibleTarget(name: target.name)
        }
        return try createBuildCommands(
            pluginWorkDirectoryURL: context.pluginWorkDirectoryURL,
            tool: try context.tool(named: "OpenAPIGenerator"),
            sourceFiles: swiftTarget.sourceFiles,
            targetName: target.name
        )
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension SwiftOpenAPIGeneratorPlugin: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        try createBuildCommands(
            pluginWorkDirectoryURL: context.pluginWorkDirectoryURL,
            tool: try context.tool(named: "OpenAPIGenerator"),
            sourceFiles: target.inputFiles,
            targetName: target.displayName
        )
    }
}
#endif
