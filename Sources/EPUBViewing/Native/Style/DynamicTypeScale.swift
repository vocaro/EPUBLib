import CoreGraphics
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// How the system text size scales the reader's chosen size (`EPUBReaderStyle.followsDynamicType`,
/// doc/native-viewer.md, "Commands and events").
extension NativeTypography {
    /// The body text style's size at the default text size, Large, which `EPUBReaderStyle`'s
    /// font size defaults to.
    static let defaultBodySize: CGFloat = 17

    /// What `size` multiplies the chosen size by: the body style's size there over its size at
    /// Large, so that book text at the default size is as large as the system's body text at every
    /// size. On iPhone and iPad UIKit's preferred body font gives both. `UIFontMetrics`, which
    /// scales a custom size along a curve of its own, gives less: 48 points for 17 at the largest
    /// accessibility size, where body text is 53 (iOS 27.0). AppKit has no Dynamic Type metrics,
    /// and a Mac view's `dynamicTypeSize` is Large unless its host sets another: such a size scales
    /// as it does on iPhone and iPad.
    static func dynamicTypeScale(for size: DynamicTypeSize) -> CGFloat {
        #if os(iOS)
        func body(_ category: UIContentSizeCategory) -> CGFloat {
            UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: category)).pointSize
        }
        return body(UIContentSizeCategory(size)) / body(.large)
        #else
        return bodySize(at: size) / defaultBodySize
        #endif
    }

    /// The body text style's size at each Dynamic Type size on iPhone and iPad, as Apple's Human
    /// Interface Guidelines list it ("Typography", "Specifications").
    static func bodySize(at size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 14
        case .small: 15
        case .medium: 16
        case .large: 17
        case .xLarge: 19
        case .xxLarge: 21
        case .xxxLarge: 23
        case .accessibility1: 28
        case .accessibility2: 33
        case .accessibility3: 40
        case .accessibility4: 47
        case .accessibility5: 53
        @unknown default: defaultBodySize
        }
    }
}
