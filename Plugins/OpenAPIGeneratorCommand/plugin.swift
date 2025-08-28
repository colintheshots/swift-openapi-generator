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

    func runCommand(
        targetWorkingDirectoryURL: URL,
        tool: URL,
        sourceFiles: FileList,
        targetName: String
    ) throws {
        let inputs = try PluginUtils.validateInputs(
            workingDirectoryURL: targetWorkingDirectoryURL,
            tool: tool,
            sourceFiles: sourceFiles,
            targetName: targetName,
            pluginSource: .command
        )

        // Use a launcher script so we can resolve to the actual binary at runtime,
        // where Xcode-provided environment variables are available to the subprocess.
        let launcher = try makeToolLauncher(in: targetWorkingDirectoryURL, toolURL: inputs.tool)

        let process = Process()
        process.executableURL = launcher
        process.arguments = inputs.arguments
        process.environment = [:]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PluginError.generatorFailure(targetName: targetName) }
    }
}

extension SwiftOpenAPIGeneratorPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let targetNameArguments = arguments.filter({ $0 != "--target" })
        let targets: [Target]
        if targetNameArguments.isEmpty {
            targets = context.package.targets
            Diagnostics.error(targets.debugDescription)
        } else {
            let matchingTargets = try context.package.targets(named: targetNameArguments)
            let packageTargets = Set(context.package.targets.map(\.id))
            let withLocalDependencies = matchingTargets.flatMap { [$0] + $0.recursiveTargetDependencies }
                .filter { packageTargets.contains($0.id) }
            let enumeratedKeyValues = withLocalDependencies.map(\.id).enumerated()
                .map { (key: $0.element, value: $0.offset) }
            let indexLookupTable = Dictionary(enumeratedKeyValues, uniquingKeysWith: { l, _ in l })
            let groupedByID = Dictionary(grouping: withLocalDependencies, by: \.id)
            let sortedUniqueTargets = groupedByID.map(\.value[0])
                .sorted { indexLookupTable[$0.id, default: 0] < indexLookupTable[$1.id, default: 0] }
            targets = sortedUniqueTargets
        }

        guard !targets.isEmpty else { throw PluginError.noTargetsMatchingTargetNames(targetNameArguments) }

        var hadASuccessfulRun = false

        for target in targets {
            log("Considering target '\(target.name)':")
            guard let swiftTarget = target as? SwiftSourceModuleTarget else {
                log("- Not a swift source module. Can't generate OpenAPI code.")
                continue
            }
            do {
                log("- Trying OpenAPI code generation.")
                let tool = try context.tool(named: "swift-openapi-generator").url
                try runCommand(
                    targetWorkingDirectoryURL: target.directoryURL,
                    tool: tool,
                    sourceFiles: swiftTarget.sourceFiles,
                    targetName: target.name
                )
                log("- ✅ OpenAPI code generation for target '\(target.name)' successfully completed.")
                hadASuccessfulRun = true
            } catch let error as PluginError {
                if case .fileErrors(let errors) = error, Set(errors.map(\.fileKind)) == Set(FileError.Kind.allCases),
                    errors.map(\.issue).allSatisfy({ $0 == FileError.Issue.noFilesFound })
                {
                    // The error is that neither of the required files are present for code generation for this target.
                    // This should only be considered an error if this target was explicitly provided as a target for
                    // code generation with --target.
                    // We may get this error for other targets if:
                    //
                    // 1. The command plugin was run with no --target arguments, in which case the plugin loops over
                    //    all targets; or
                    // 2. This target is a dependency of a target that was requested using --target.
                    //
                    // In either of these cases, we should not consider this an error and skip the target.
                    if !targetNameArguments.contains(target.name) {
                        log("- Skipping because target isn't configured for OpenAPI code generation.")
                        continue
                    }
                }

                if error.isMisconfigurationError {
                    log("- Stopping because target is misconfigured for OpenAPI code generation.")
                    throw error
                } else {
                    log("- OpenAPI code generation failed with error.")
                    throw error
                }
            }
        }

        guard hadASuccessfulRun else { throw PluginError.noTargetsWithExpectedFiles(targetNames: targets.map(\.name)) }
    }
}

private func log(_ message: @autoclosure () -> String) {
    FileHandle.standardError.write(Data(message().appending("\n").utf8))
}
