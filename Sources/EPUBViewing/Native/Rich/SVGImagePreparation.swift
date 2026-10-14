import Foundation

/// One SVG serialization's archive-image work, shared by all recursive image preparations.
/// Successful and intrinsic-failure results are memoized by path, ancestors and font aliases;
/// parent capacity refusals are not cached. Limits are checked before each costly phase.
final class SVGImagePreparation {
    struct Image {
        let data: Data
        let pixels: Int
        let report: SectionReport
    }
    struct Limits {
        var visits = 128
        var sourceBytes = 16 * 1024 * 1024
        var serializedBytes = 16 * 1024 * 1024
        var rasterPixels = 64 * 1024 * 1024
        var cachedBytes = 8 * 1024 * 1024
    }
    private struct Key: Hashable {
        let path: String
        let request: Bool
        let ancestors: Set<String>
        let fonts: Int
    }
    private enum Result { case unavailable, image(Image) }
    private let limits: Limits
    private let cancelled: () -> Bool
    private var cache: [Key: Result] = [:]
    private var fontContexts: [[String: String]] = []

    private func fontContext(_ fonts: [String: String]) -> Int {
        if let index = fontContexts.firstIndex(of: fonts) { return index }
        fontContexts.append(fonts)
        return fontContexts.count - 1
    }
    private var sourceBytes = 0, serializedBytes = 0, rasterPixels = 0, cachedBytes = 0
    private var refusals = 0
    private(set) var visits = 0
    private(set) var cacheHits = 0

    init(limits: Limits = Limits(), cancelled: @escaping () -> Bool = { Task.isCancelled }) {
        self.limits = limits; self.cancelled = cancelled
    }

    @discardableResult func permitsWork() -> Bool {
        guard !cancelled() else { refuse(); return false }
        return true
    }
    func refuse() { refusals += 1 }
    var hasRemainingVisits: Bool { visits < limits.visits }

    /// Cache the designated-chain selection too, so repeated references do not rescan a long
    /// fallback chain. Alias entries share an already-counted immutable image's bytes.
    func request(at path: String, ancestors: Set<String>, fonts: [String: String], maximumBytes: Int,
                 maximumPixels: Int, prepare: () -> Image?) -> Image? {
        guard permitsWork(), ancestors.count < 8, maximumBytes > 0, maximumPixels > 0 else { refuse(); return nil }
        let key = Key(path: path, request: true, ancestors: ancestors,
                      fonts: fontContext(fonts))
        if let known = cache[key] {
            cacheHits += 1
            guard case .image(let image) = known else { return nil }
            return image.data.count <= maximumBytes && image.pixels <= maximumPixels ? image : nil
        }
        guard hasRemainingVisits else { refuse(); return nil }
        visits += 1
        let before = refusals
        guard let image = prepare() else {
            if refusals == before { cache[key] = .unavailable }
            return nil
        }
        guard permitsWork(), image.data.count <= maximumBytes, image.pixels <= maximumPixels else { refuse(); return nil }
        cache[key] = .image(image)
        return image
    }

    /// Logical disclosure counts can grow much faster than prepared bytes in a repeated DAG.
    /// Preserve ordinary counts, with headroom for later section increments and aggregation.
    static let maximumReportCount = Int.max / (1024 * 1024)

    static func replay(_ incoming: SectionReport, into box: SectionReportBox?) {
        guard let box else { return }
        var delta = incoming
        func capped(_ value: Int, _ current: Int) -> Int { min(value, max(0, maximumReportCount - current)) }
        delta.scriptsRefused = capped(delta.scriptsRefused, box.report.scriptsRefused)
        delta.remoteResourcesRefused = capped(delta.remoteResourcesRefused, box.report.remoteResourcesRefused)
        delta.unreadableResources = capped(delta.unreadableResources, box.report.unreadableResources)
        delta.mathFallbacks = capped(delta.mathFallbacks, box.report.mathFallbacks)
        delta.mathApproximations = capped(delta.mathApproximations, box.report.mathApproximations)
        delta.mathReductions = capped(delta.mathReductions, box.report.mathReductions)
        for (name, count) in delta.unsupportedElements { delta.unsupportedElements[name] = capped(count, box.report.unsupportedElements[name] ?? 0) }
        box.report.formUnion(delta)
    }
    func consumeSerializedBytes(_ count: Int) -> Bool {
        guard permitsWork(), count >= 0, count <= limits.serializedBytes - serializedBytes else { refuse(); return false }
        serializedBytes += count; return true
    }
    func reserveRasterPixels(_ count: Int) -> Bool {
        guard permitsWork(), count >= 0, count <= limits.rasterPixels - rasterPixels else { refuse(); return false }
        rasterPixels += count; return true
    }

    func image(at path: String, ancestors: Set<String>, fonts: [String: String],
               maximumBytes: Int, maximumPixels: Int, load: () -> Data?, prepare: (Data) -> Image?) -> Image? {
        guard permitsWork(), ancestors.count < 8, !ancestors.contains(path), maximumBytes > 0, maximumPixels > 0 else {
            refuse(); return nil
        }
        let key = Key(path: path, request: false, ancestors: ancestors, fonts: fontContext(fonts))
        if let known = cache[key] {
            cacheHits += 1
            guard case .image(let image) = known else { return nil }
            return image.data.count <= maximumBytes && image.pixels <= maximumPixels ? image : nil
        }
        guard visits < limits.visits else { refuse(); return nil }
        visits += 1
        guard let bytes = load() else { cache[key] = .unavailable; return nil }
        guard bytes.count <= limits.sourceBytes - sourceBytes else { refuse(); return nil }
        sourceBytes += bytes.count
        let before = refusals
        guard let image = prepare(bytes) else {
            // A tighter parent capacity or exhausted shared budget must not poison a later
            // use with sufficient capacity. Malformed/unsupported bytes can be remembered.
            if refusals == before { cache[key] = .unavailable }
            return nil
        }
        guard permitsWork(), image.data.count <= maximumBytes, image.pixels <= maximumPixels,
              image.data.count <= limits.cachedBytes - cachedBytes else { refuse(); return nil }
        cachedBytes += image.data.count
        cache[key] = .image(image)
        return image
    }
}
