import Combine
import Foundation

/// The File menu's recent designs are separate from last-session restoration.
/// Callers record successful opens and saves, not ordinary autosave updates.
@MainActor
final class RecentProjects: ObservableObject {
    static let defaultsKey = "recentProjectPaths"
    @Published private(set) var urls: [URL]

    private let defaults: UserDefaults
    private let maximumCount: Int

    init(defaults: UserDefaults = .standard, initialURL: URL? = nil, maximumCount: Int = 15) {
        self.defaults = defaults
        self.maximumCount = max(0, maximumCount)
        let hasSavedList = defaults.object(forKey: Self.defaultsKey) != nil
        let stored = defaults.array(forKey: Self.defaultsKey)?.compactMap { $0 as? String } ?? []
        var candidates = stored.compactMap { path -> URL? in
            guard path.hasPrefix("/") else { return nil }
            return Self.canonicalURL(URL(fileURLWithPath: path))
        }
        if !hasSavedList, let initialURL = initialURL.flatMap(Self.canonicalURL) {
            candidates.insert(initialURL, at: 0)
        }
        var seen = Set<URL>()
        urls = Array(candidates.filter { seen.insert($0).inserted }.prefix(self.maximumCount))
        persist()
    }

    func record(_ url: URL, replacing previousURL: URL? = nil) {
        guard let canonical = Self.canonicalURL(url) else { return }
        let previous = previousURL.flatMap(Self.canonicalURL)
        let updated = Array(([canonical] + urls.filter { $0 != canonical && $0 != previous }).prefix(maximumCount))
        guard updated != urls else { return }
        urls = updated
        persist()
    }

    func clear() {
        if !urls.isEmpty { urls = [] }
        persist()
    }

    private func persist() {
        defaults.set(urls.map(\.path), forKey: Self.defaultsKey)
    }

    private static func canonicalURL(_ url: URL) -> URL? {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.pathExtension.lowercased() == "lad" else { return nil }
        // Resolve path aliases without opening or inspecting design contents.
        // Reconstructing a file URL also drops irrelevant query/fragment text.
        let canonical = URL(fileURLWithPath: url.path).standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.pathExtension.lowercased() == "lad" else { return nil }
        return canonical
    }
}
