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
    /// Create a small launcher script that resolves the actual tool path at build time,
    /// leveraging Xcode-provided environment variables (e.g. BUILT_PRODUCTS_DIR), which
    /// are not available inside the plugin process itself.
    private func makeToolLauncher(in directory: URL, toolURL: URL) throws -> URL {
        let binaryName = toolURL.lastPathComponent
        let launcherURL = directory.appendingPathComponent("swift-openapi-generator-launcher.sh", isDirectory: false)
        let script = #"""
        #!/bin/sh
        BIN_ORIG="\#(toolURL.path)"
        BIN_OVERRIDE="${SWIFT_OPENAPI_GENERATOR_TOOL_OVERRIDE}"
        if [ -n "$BIN_OVERRIDE" ] && [ -x "$BIN_OVERRIDE" ]; then exec "$BIN_OVERRIDE" "$@"; fi
        if [ -x "$BIN_ORIG" ]; then exec "$BIN_ORIG" "$@"; fi
        BIN_CAND="$BIN_ORIG"
        BIN_CAND="${BIN_CAND/\/Debug\//\/Debug-maccatalyst\/}"
        BIN_CAND="${BIN_CAND/\/Staging\//\/Staging-maccatalyst\/}"
        BIN_CAND="${BIN_CAND/\/Release\//\/Release-maccatalyst\/}"
        if [ -x "$BIN_CAND" ]; then exec "$BIN_CAND" "$@"; fi
        if [ -n "${BUILT_PRODUCTS_DIR}" ] && [ -x "${BUILT_PRODUCTS_DIR}/\#(binaryName)" ]; then exec "${BUILT_PRODUCTS_DIR}/\#(binaryName)" "$@"; fi
        if [ -n "${TARGET_BUILD_DIR}" ] && [ -x "${TARGET_BUILD_DIR}/\#(binaryName)" ]; then exec "${TARGET_BUILD_DIR}/\#(binaryName)" "$@"; fi
        echo "swift-openapi-generator not found at expected paths" 1>&2
        echo "Tried:" 1>&2
        echo "  $BIN_OVERRIDE" 1>&2
        echo "  $BIN_ORIG" 1>&2
        echo "  $BIN_CAND" 1>&2
        if [ -n "${BUILT_PRODUCTS_DIR}" ]; then echo "  ${BUILT_PRODUCTS_DIR}/\#(binaryName)" 1>&2; fi
        if [ -n "${TARGET_BUILD_DIR}" ]; then echo "  ${TARGET_BUILD_DIR}/\#(binaryName)" 1>&2; fi
        exit 127
        """#
        try Data(script.utf8).write(to: launcherURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherURL.path)
        return launcherURL
    }
    // (obsolete: path rewriting and DerivedData scanning were superseded by the launcher)
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
        let launcher = try makeToolLauncher(in: pluginWorkDirectoryURL, toolURL: inputs.tool)
        return [
            .buildCommand(
                displayName: "Running swift-openapi-generator",
                executable: launcher,
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
        let tool = try context.tool(named: "swift-openapi-generator").url
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
        let tool = try context.tool(named: "swift-openapi-generator").url
        return try createBuildCommands(
            pluginWorkDirectoryURL: context.pluginWorkDirectoryURL,
            tool: tool,
            sourceFiles: target.inputFiles,
            targetName: target.displayName
        )
    }
}
#endif
