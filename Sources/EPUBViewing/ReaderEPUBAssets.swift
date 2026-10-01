import Foundation

enum ReaderEPUBAssets {
    static let upstreamRepository = "https://github.com/johnfactotum/foliate-js"
    static let upstreamCommit = "78914aef4466eb960965702401634c2cb348e9b1"

    static let resourceDirectory = "epub-reader"
    static let libraryDirectory = "lib"

    struct Vendored: Equatable, Sendable {
        let path: String
        let blobSHA1: String
        let staticImports: [String]
        let dynamicImports: [String]
    }

    static let vendored: [Vendored] = [
        Vendored(
            path: "view.js",
            blobSHA1: "9bdaf022e29f8b491cddfa601a643a2b9df1e990",
            staticImports: ["epubcfi.js", "progress.js", "overlayer.js", "text-walker.js"],
            dynamicImports: [
                "epub.js", "paginator.js", "fixed-layout.js", "search.js", "tts.js",
                "vendor/zip.js", "comic-book.js", "fb2.js", "pdf.js", "mobi.js",
                "vendor/fflate.js"
            ]),
        Vendored(
            path: "epub.js",
            blobSHA1: "e8bd70333accb9f9f6fb7389cb434b6805156da0",
            staticImports: ["epubcfi.js"], dynamicImports: []),
        Vendored(
            path: "epubcfi.js",
            blobSHA1: "712ead5359b3d30e4a3dbf18de4ca0b9eb37a597",
            staticImports: [], dynamicImports: []),
        Vendored(
            path: "progress.js",
            blobSHA1: "f01c512c77c6eea45ce9b7745eafd44283b8bb26",
            staticImports: [], dynamicImports: []),
        Vendored(
            path: "overlayer.js",
            blobSHA1: "6fd03ab58505a7a3f196c570ce6a47ae437b747c",
            staticImports: [], dynamicImports: []),
        Vendored(
            path: "text-walker.js",
            blobSHA1: "c1249b79c6beca30e8f4d27e96cd05fa869ef67b",
            staticImports: [], dynamicImports: []),
        Vendored(
            path: "paginator.js",
            blobSHA1: "7980c20297049e38b5e5a1d44a9eee11b1fbd68e",
            staticImports: [], dynamicImports: []),
        Vendored(
            path: "fixed-layout.js",
            blobSHA1: "c582abad1496874a9265cad1ab69e12a475c684d",
            staticImports: [], dynamicImports: []),
        Vendored(
            path: "search.js",
            blobSHA1: "a6f176ff7c2f8fbec7401120ae917d119257995f",
            staticImports: [], dynamicImports: []),
        Vendored(
            path: "vendor/zip.js",
            blobSHA1: "564d9ec409d71467877ccd9f564442095f4cf8e4",
            staticImports: [], dynamicImports: []),
        Vendored(
            path: "LICENSE",
            blobSHA1: "5930571b73151702a913179ef5f96313ad7d25d3",
            staticImports: [], dynamicImports: []),
        Vendored(
            path: "vendor/zip.js.LICENSE.txt",
            blobSHA1: "c4fd485e3d1084008e5dbdd540a05384525c9858",
            staticImports: [], dynamicImports: []),
    ]

    struct Excluded: Equatable, Sendable {
        let path: String
        let reason: String
    }

    static let excluded: [Excluded] = [
        Excluded(path: "mobi.js", reason: "makeBook() only; the prototype never calls makeBook"),
        Excluded(
            path: "vendor/fflate.js",
            reason: "exports unzlibSync for the MOBI branch of makeBook() only"),
        Excluded(
            path: "pdf.js",
            reason: "the experimental PDF adapter; makeBook() only. PDFKit renders PDFs here"),
        Excluded(
            path: "comic-book.js", reason: "CBZ; makeBook() only"),
        Excluded(path: "fb2.js", reason: "FictionBook; makeBook() only"),
        Excluded(path: "tts.js", reason: "view.initTTS() only, which the prototype never calls"),
    ]

    static var servableLibraryPaths: Set<String> {
        Set(vendored.map(\.path))
    }

    static let bootstrapStaticImports = ["view.js", "epub.js", "vendor/zip.js"]

    static var unsatisfiedStaticImports: [String] {
        let present = servableLibraryPaths
        let edges = bootstrapStaticImports
            + vendored.flatMap { file in file.staticImports.map { resolve($0, from: file.path) } }
        return edges.filter { !present.contains($0) }.sorted()
    }

    static func resolve(_ importPath: String, from source: String) -> String {
        let directory = source.contains("/")
            ? String(source[source.startIndex..<source.lastIndex(of: "/")!]) + "/"
            : ""
        return directory.isEmpty ? importPath : directory + importPath
    }

    static func missingFiles(
        under libraryRoot: URL, fileManager: FileManager = .default
    ) -> [String] {
        vendored
            .map(\.path)
            .filter { !fileManager.fileExists(atPath: libraryRoot.appending(path: $0).path) }
            .sorted()
    }
}

extension ReaderEPUBAssets {
    static var bundle: Bundle { .module }
}
