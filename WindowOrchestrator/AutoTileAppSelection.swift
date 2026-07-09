//
//  AutoTileAppSelection.swift
//  WindowBuddy
//
//  Created by Codex on 02/06/2026.
//

import AppKit
import Foundation

struct AutoTileAppSelection: Identifiable, Hashable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    let bundleURL: URL?

    var id: String {
        bundleIdentifier
    }

    var icon: NSImage? {
        guard let bundleURL else {
            return nil
        }

        return NSWorkspace.shared.icon(forFile: bundleURL.path)
    }

    static func resolved(bundleIdentifier: String) -> AutoTileAppSelection {
        let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        let displayName = bundleURL.map(displayName(for:)) ?? bundleIdentifier

        return AutoTileAppSelection(bundleIdentifier: bundleIdentifier,
                                    displayName: displayName,
                                    bundleURL: bundleURL)
    }

    static func app(at bundleURL: URL) -> AutoTileAppSelection? {
        guard let bundle = Bundle(url: bundleURL),
              let bundleIdentifier = bundle.bundleIdentifier else {
            return nil
        }

        return AutoTileAppSelection(bundleIdentifier: bundleIdentifier,
                                    displayName: displayName(for: bundleURL),
                                    bundleURL: bundleURL)
    }

    static func installedApplications() -> [AutoTileAppSelection] {
        var urls = Set<URL>()

        let runningApplicationURLs = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
        urls.formUnion(runningApplicationURLs)

        for directoryURL in applicationDirectoryURLs() {
            guard let enumerator = FileManager.default.enumerator(at: directoryURL,
                                                                  includingPropertiesForKeys: [.isApplicationKey, .isDirectoryKey],
                                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                continue
            }

            for case let url as URL in enumerator {
                guard url.pathExtension == "app" else {
                    continue
                }

                urls.insert(url)
                enumerator.skipDescendants()
            }
        }

        return urls
            .compactMap(app(at:))
            .uniqueByBundleIdentifier()
            .sortedByDisplayName()
    }

    private static func displayName(for bundleURL: URL) -> String {
        let bundle = Bundle(url: bundleURL)

        if let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }

        if let name = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty {
            return name
        }

        return FileManager.default.displayName(atPath: bundleURL.path)
    }

    private static func applicationDirectoryURLs() -> [URL] {
        let fileManager = FileManager.default
        var urls = fileManager.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])

        if let systemApplicationsURL = fileManager.urls(for: .applicationDirectory, in: .systemDomainMask).first {
            urls.append(systemApplicationsURL)
        }

        var seenURLs = Set<URL>()
        return urls.filter { url in
            seenURLs.insert(url.standardizedFileURL).inserted
        }
    }
}

extension Array where Element == AutoTileAppSelection {
    func uniqueByBundleIdentifier() -> [AutoTileAppSelection] {
        var seenBundleIdentifiers = Set<String>()

        return filter { app in
            seenBundleIdentifiers.insert(app.bundleIdentifier).inserted
        }
    }

    func sortedByDisplayName() -> [AutoTileAppSelection] {
        sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)

            if comparison == .orderedSame {
                return $0.bundleIdentifier < $1.bundleIdentifier
            }

            return comparison == .orderedAscending
        }
    }
}

struct AutoTileAppGroup: Identifiable, Hashable {
    let index: Int
    let apps: [AutoTileAppSelection]
    let mainAppBundleIdentifiers: [String]
    let screenLayoutMode: AutoTileScreenLayoutMode
    let maximumColumnCount: Int
    let tileDirection: AutoTileDirection
    let fillsFirstWindow: Bool
    let ignoresSecondAppInList: Bool
    let ignoredSecondWindowStartMode: AutoTileIgnoredSecondWindowStartMode

    var id: Int {
        index
    }

    var title: String {
        "Group \(index + 1)"
    }

    func isMainApp(_ app: AutoTileAppSelection) -> Bool {
        mainAppBundleIdentifiers.contains(app.bundleIdentifier)
    }

    var availableScreenLayoutModes: [AutoTileScreenLayoutMode] {
        AutoTileScreenLayoutMode.standardCases
    }
}
