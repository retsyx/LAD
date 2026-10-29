import Foundation

/// The default is consulted only when a design does not already have a file.
enum ProjectSaveLocation {
    static let preferenceKey = "projectSaveDirectory"

    static func cloudDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/LAD", isDirectory: true)
    }

    static func documentsDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Documents/LAD", isDirectory: true)
    }

    static func isCloudAvailable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: cloudDirectory(home: home).deletingLastPathComponent().path,
                                             isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func displayName(for directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let location = directory.standardizedFileURL.resolvingSymlinksInPath()
        let cloud = cloudDirectory(home: home).resolvingSymlinksInPath()
        let cloudRoot = cloud.deletingLastPathComponent()
        if location.path == cloud.path || location.path == cloudRoot.path { return "iCloud Drive" }
        if location.path == documentsDirectory(home: home).resolvingSymlinksInPath().path { return "Documents/LAD" }
        if location.pathComponents.starts(with: cloudRoot.pathComponents) {
            return "iCloud Drive/" + location.pathComponents.dropFirst(cloudRoot.pathComponents.count).joined(separator: "/")
        }
        return (directory.path as NSString).abbreviatingWithTildeInPath
    }

    static func directory(defaults: UserDefaults = .standard,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let path = defaults.string(forKey: preferenceKey), path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return isCloudAvailable(home: home) ? cloudDirectory(home: home) : documentsDirectory(home: home)
    }
}
