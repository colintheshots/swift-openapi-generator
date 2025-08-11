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
import Foundation

enum PluginUtils {
    private static var supportedConfigFiles: Set<String> {
        Set(["yaml", "yml"].map { "openapi-generator-config." + $0 })
    }
    private static var supportedDocFiles: Set<String> { Set(["yaml", "yml", "json"].map { "openapi." + $0 }) }

    /// Validated values to run a plugin with.
    struct ValidatedInputs {
        let docURL: URL
        let configURL: URL
        let genSourcesDirURL: URL
        let arguments: [String]
        let tool: URL
    }

    /// Validates the inputs and returns the necessary values to run a plugin.
    static func validateInputs(
        workingDirectoryURL: URL,
        tool: URL,
        sourceFiles: FileList,
        targetName: String,
        pluginSource: PluginSource
    ) throws -> ValidatedInputs {
        let (configURL, docURL) = try findFiles(inputFiles: sourceFiles, targetName: targetName)
        let genSourcesDirURL = workingDirectoryURL.appendingPathComponent("GeneratedSources")

        let arguments = [
            "generate", docURL.path, "--config", configURL.path, "--output-directory", genSourcesDirURL.path, "--plugin-source",
            pluginSource.rawValue,
        ]

        return ValidatedInputs(docURL: docURL, configURL: configURL, genSourcesDirURL: genSourcesDirURL, arguments: arguments, tool: tool)
    }

    /// Finds the OpenAPI config and document files or throws an error including both possible
    /// previous errors from the process of finding the config and document files.
    private static func findFiles(inputFiles: FileList, targetName: String) throws -> (config: URL, doc: URL) {
        let config = findConfig(inputFiles: inputFiles, targetName: targetName)
        let doc = findDocument(inputFiles: inputFiles, targetName: targetName)
        switch (config, doc) {
        case (.failure(let error1), .failure(let error2)): throw PluginError.fileErrors([error1, error2])
        case (_, .failure(let error)): throw PluginError.fileErrors([error])
        case (.failure(let error), _): throw PluginError.fileErrors([error])
        case (.success(let config), .success(let doc)): return (config, doc)
        }
    }

    /// Find the config file.
    private static func findConfig(inputFiles: FileList, targetName: String) -> Result<URL, FileError> {
        let matchedConfigs = inputFiles.filter { supportedConfigFiles.contains($0.url.lastPathComponent) }
            .map(\.url)
        guard matchedConfigs.count > 0 else {
            return .failure(FileError(targetName: targetName, fileKind: .config, issue: .noFilesFound))
        }
        guard matchedConfigs.count == 1 else {
            return .failure(
                FileError(
                    targetName: targetName,
                    fileKind: .config,
                    issue: .multipleFilesFound(files: matchedConfigs.map { $0.path })
                )
            )
        }
        return .success(matchedConfigs[0])
    }

    /// Find the document file.
    private static func findDocument(inputFiles: FileList, targetName: String) -> Result<URL, FileError> {
        let matchedDocs = inputFiles.filter { supportedDocFiles.contains($0.url.lastPathComponent) }.map(\.url)
        guard matchedDocs.count > 0 else {
            return .failure(FileError(targetName: targetName, fileKind: .document, issue: .noFilesFound))
        }
        guard matchedDocs.count == 1 else {
            return .failure(
                FileError(
                    targetName: targetName,
                    fileKind: .document,
                    issue: .multipleFilesFound(files: matchedDocs.map { $0.path })
                )
            )
        }
        return .success(matchedDocs[0])
    }
}

extension Array where Element == String {
    func joined(separator: String, lastSeparator: String) -> String {
        guard count > 1 else { return self.joined(separator: separator) }
        return "\(self.dropLast().joined(separator: separator))\(lastSeparator)\(self.last!)"
    }
}

extension PackagePlugin.Path {
    /// Workaround for the ``lastComponent`` property being broken on Windows
    /// due to hardcoded assumptions about the path separator being forward slash.
    @available(_PackageDescription, deprecated: 6.0, message: "Use `URL` type instead of `Path`.") public
        var lastComponent_fixed: String
    {
        #if !os(Windows)
        lastComponent
        #else
        // Find the last path separator.
        guard let idx = string.lastIndex(where: { $0 == "/" || $0 == "\\" }) else {
            // No path separators, so the basename is the whole string.
            return self.string
        }
        // Otherwise, it's the string from (but not including) the last path
        // separator.
        return String(self.string.suffix(from: self.string.index(after: idx)))
        #endif
    }
}
