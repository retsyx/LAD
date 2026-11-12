import Foundation
import XCTest
@testable import LAD

/// The merged asset catalog of a saved package, read from its section files.
func assetCatalog(_ url: URL) throws -> [String: [String: Any]] {
    func object(_ path: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent(path)))
    }
    let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectStore.readArchive(from: url)) as? [String: Any])
    let reference = try XCTUnwrap(manifest["catalog"] as? [String: Any])
    let index = try XCTUnwrap(try object(XCTUnwrap(reference["path"] as? String)) as? [String: Any])
    var catalog = [String: [String: Any]]()
    for case let bucket as [String: Any] in (index["buckets"] as? [String: Any] ?? [:]).values {
        let entries = try XCTUnwrap(try object(XCTUnwrap(bucket["path"] as? String)) as? [String: [String: Any]])
        catalog.merge(entries) { $1 }
    }
    return catalog
}
