import Foundation

/// A license or notice file that an app built with EPUBLib shows in its acknowledgments, under the
/// name its project gave it (#699).
///
/// The package holds EPUBLib's license and those of the code its products contain: ZIPFoundation,
/// the foliate-js code the viewer ports, MathMLLayout with the MathCAT and Speech Rule Engine
/// material it adapts, and StaticSVG with resvg, the Rust crates it depends on and the Rust
/// standard library. They are in EPUBCore's resource bundle, so every product reaches them.
public struct EPUBLicense: Sendable, Hashable, Identifiable {
    /// The project the text belongs to: `EPUBLib`, `foliate-js`, `MathMLLayout`, `StaticSVG` or
    /// `ZIPFoundation`.
    public let component: String
    /// The file's path in the component's folder, such as `LICENSE` or
    /// `Licenses/resvg-0.48.1/LICENSE-MIT`.
    public let path: String
    /// The file in EPUBCore's resource bundle.
    public let url: URL

    /// The component and path, `StaticSVG/Licenses/resvg-0.48.1/LICENSE-MIT`.
    public var id: String { "\(component)/\(path)" }

    /// The file's UTF-8 text. One is HTML: the Rust standard library's
    /// `StaticSVG/Licenses/rust-1.95.0/COPYRIGHT-library.html`.
    public func text() throws -> String { try String(contentsOf: url, encoding: .utf8) }

    /// Every license and notice of EPUBLib and of the code its products contain: EPUBLib's first,
    /// then the others by component and path, ignoring case.
    public static func all() throws -> [EPUBLicense] {
        guard let folder = Bundle.module.url(forResource: "Licenses", withExtension: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let files = FileManager.default
        let licenses = try files.subpathsOfDirectory(atPath: folder.path).compactMap { subpath -> EPUBLicense? in
            let names = subpath.split(separator: "/").map(String.init)
            let url = folder.appending(path: subpath)
            var directory: ObjCBool = false
            guard names.count > 1, !names.contains(where: { $0.hasPrefix(".") }),
                  files.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else { return nil }
            return EPUBLicense(component: names[0], path: names.dropFirst().joined(separator: "/"), url: url)
        }
        func order(_ license: EPUBLicense) -> (Int, String) {
            (license.component == "EPUBLib" ? 0 : 1, license.id.lowercased())
        }
        return licenses.sorted { order($0) < order($1) }
    }
}
