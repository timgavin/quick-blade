import Foundation

/// Builds a throwaway Laravel-shaped project tree (a directory containing an
/// `artisan` file) so TemplateResolver tests can exercise real file resolution.
final class FixtureProject {
    let root: URL

    /// A sibling directory OUTSIDE the project root, reachable from `<root>/public`
    /// only by climbing `../..`. Path-traversal tests plant canaries here; nothing
    /// the resolver reads legitimately should ever land in it.
    let outside: URL

    /// Last path component of `outside`, for composing traversal payloads.
    var outsideName: String { outside.lastPathComponent }

    init() throws {
        let id = UUID().uuidString
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickblade-tests-\(id)")
        outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickblade-outside-\(id)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("artisan"))
    }

    /// Writes a file into `outside`, i.e. beyond the project boundary.
    @discardableResult
    func writeOutside(_ name: String, _ contents: String) throws -> URL {
        let url = outside.appendingPathComponent(name)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    /// Writes a UTF-8 text file at a path relative to the project root,
    /// creating intermediate directories. Returns the file URL.
    @discardableResult
    func write(_ relativePath: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    /// Creates a symlink at `relativePath` (inside the project) pointing at
    /// `destination`, which may be relative to the link's own directory.
    /// Laravel's `artisan storage:link` makes exactly one of these.
    @discardableResult
    func symlink(_ relativePath: String, to destination: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: url.path, withDestinationPath: destination)
        return url
    }

    /// Binary variant for image fixtures.
    @discardableResult
    func write(_ relativePath: String, data: Data) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
}
