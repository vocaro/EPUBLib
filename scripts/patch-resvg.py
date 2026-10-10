#!/usr/bin/env python3
"""Apply the small, auditable EPUBLib resource policy to pinned resvg 0.48.1."""
from pathlib import Path
import sys

source = Path(sys.argv[1]) / 'crates/c-api/lib.rs'
text = source.read_text()
old = '''    Box::into_raw(Box::new(resvg_options {
        options: usvg::Options::default(),
    }))'''
new = '''    let mut options = usvg::Options::default();
    // The host provides all archive image bytes; SVG can never open files.
    options.image_href_resolver.resolve_string = Box::new(|_, _| None);
    let data_resolver = usvg::ImageHrefResolver::default_data_resolver();
    options.image_href_resolver.resolve_data = Box::new(move |mime, data, options| {
        // Never recursively parse SVG/SVGZ, or sniff a disguised nested document.
        if matches!(mime, "image/png" | "image/jpeg" | "image/gif" | "image/webp") {
            data_resolver(mime, data, options)
        } else { None }
    });
    Box::into_raw(Box::new(resvg_options { options }))'''
assert text.count(old) == 1, 'Unexpected resvg source: options policy patch does not apply'
text = text.replace(old, new)
# Upstream's C API incorrectly gates filesystem font methods on `text` alone.
# Disable these methods entirely with our build's system-fonts feature off.
start = text.index('pub extern "C" fn resvg_options_load_font_file(')
end = text.index('/// @brief Destroys the #resvg_options.', start)
part = text[start:end].replace('#[cfg(feature = "text")]', '#[cfg(all(feature = "text", feature = "system-fonts"))]')
part = part.replace('#[cfg(not(feature = "text"))]', '#[cfg(not(all(feature = "text", feature = "system-fonts")))]')
text = text[:start] + part + text[end:]
source.write_text(text)
