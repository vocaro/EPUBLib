#!/usr/bin/env python3
"""Apply EPUBLib resource and unwind-boundary policies to pinned resvg 0.48.1."""
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
# The panic wrappers live separately so their ownership and synchronization are reviewable.
import importlib.util
spec = importlib.util.spec_from_file_location("panic_boundary", Path(__file__).with_name("resvg-panic-boundary.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.patch(Path(sys.argv[1]), text)

# tiny-skia flushes its last antialias row from Drop. When a raster panic left
# that row inconsistent, flushing during unwinding can panic again and abort
# before catch_unwind gets control. Normal Drop must still flush the final row.
root = Path(sys.argv[1])
cleanup = root / 'vendor/tiny-skia/src/scan/path_aa.rs'
text = cleanup.read_text()
old = """impl Drop for SuperBlitter<'_> {
    fn drop(&mut self) {
        self.flush();
    }
}"""
new = """impl Drop for SuperBlitter<'_> {
    fn drop(&mut self) {
        // EPUBLib: discard a row interrupted by a panic; never double-panic in Drop.
        #[cfg(feature = "std")]
        if std::thread::panicking() { return; }
        self.flush();
    }
}"""
assert text.count(old) == 1, 'Unexpected tiny-skia cleanup: unwind guard does not apply'
cleanup.write_text(text.replace(old, new))
manifest = root / 'Cargo.toml'
text = manifest.read_text()
assert '[patch.crates-io]' not in text
manifest.write_text(text + '\n[patch.crates-io]\ntiny-skia = { path = "vendor/tiny-skia" }\n')
lockfile = root / 'Cargo.lock'
text = lockfile.read_text()
old = """name = "tiny-skia"
version = "0.12.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "47ffee5eaaf5527f630fb0e356b90ebdec84d5d18d937c5e440350f88c5a91ea"
"""
assert text.count(old) == 1, 'Unexpected tiny-skia lock entry'
lockfile.write_text(text.replace(old, 'name = "tiny-skia"\nversion = "0.12.0"\n'))
