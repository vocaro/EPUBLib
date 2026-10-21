"""Contain renderer panics inside Rust; never unwind across the C ABI.

Method, for this script and resvg-panic-boundary.rs:
https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/document-parsing.md#native-renderer-containment-needs-more-than-a-byte-limit
"""
from pathlib import Path
import re


def patch(root: Path, text: str):
    # Keep a stable opaque handle, but dispose of the actual immutable tree on a panic.
    # The per-tree lock protects disposal against another thread currently drawing it.
    old = "pub struct resvg_render_tree(pub usvg::Tree);"
    assert text.count(old) == 1
    helper = Path(__file__).with_name("resvg-panic-boundary.rs").read_text()
    text = text.replace(old, helper)
    text = text.replace("Box::new(resvg_render_tree(utree))", "Box::new(resvg_render_tree::new(utree))")
    # All tree consumers are behind the same lock and unwind boundary. Inner functions
    # use the original tuple structure and Rust ABI: catch_unwind cannot catch a panic
    # escaping from an extern C inner function, whose ABI aborts before it gets there.
    defaults = {
        "resvg_is_image_empty": "true",
        "resvg_get_image_size": "resvg_size { width: 0.0, height: 0.0 }",
        "resvg_get_object_bbox": "false",
        "resvg_get_image_bbox": "false",
        "resvg_node_exists": "false",
        "resvg_get_node_transform": "false",
        "resvg_get_node_bbox": "false",
        "resvg_get_node_stroke_bbox": "false",
        "resvg_render": "false",
        "resvg_render_node": "false",
    }
    # get_node_bbox is a private helper shared by two wrapped getters.
    text = text.replace("fn get_node_bbox(\n    tree: *const resvg_render_tree,", "fn get_node_bbox(\n    tree: *const resvg_tree_data,")
    for name, default in defaults.items():
        start = text.index('pub extern "C" fn ' + name + '(')
        body_start = text.index('{', start)
        signature = text[start:body_start]
        end = body_start + 1
        depth = 1
        while depth:
            if text[end] == '{': depth += 1
            if text[end] == '}': depth -= 1
            end += 1
        body = text[body_start:end]
        arguments = re.findall(r"(\w+):", signature.split(')')[0])
        assert arguments[0] == "tree", name
        checked_name = "resvg_render_checked" if name == "resvg_render" else name
        checked_signature = signature.replace(name, checked_name, 1)
        if name == "resvg_render":
            checked_signature = checked_signature.rstrip() + " -> bool "
            body = body[:-1].rstrip() + ";\n    true\n}"
        inner_signature = checked_signature.replace('pub extern "C" fn ' + checked_name, 'fn ' + name + '_inner', 1)
        inner_signature = inner_signature.replace("*const resvg_render_tree", "*const resvg_tree_data")
        wrapper = checked_signature + "{\n    with_tree(tree, " + default + ", |data| " + name + "_inner(data, " + ", ".join(arguments[1:]) + "))\n}"
        # A getter with no additional parameters has no trailing comma requirement.
        wrapper = wrapper.replace("_inner(data, )", "_inner(data)")
        if name == "resvg_render":
            wrapper = signature + "{\n    let _ = resvg_render_checked(" + ", ".join(arguments) + ");\n}\n\n/// @brief Renders, returning false after a caught panic or a previously invalidated tree.\n#[unsafe(no_mangle)]\n" + wrapper
        text = text[:start] + wrapper + "\n\n" + inner_signature + body + text[end:]
    for name in ["resvg_parse_tree_from_data", "resvg_parse_tree_from_file"]:
        start = text.index('pub extern "C" fn ' + name + '(')
        body_start = text.index('{', start)
        signature = text[start:body_start]
        arguments = re.findall(r"(\w+):", signature.split(')')[0])
        wrapper = signature + "{\n    if tree.is_null() { return resvg_error::PARSING_FAILED as i32; }\n    unsafe { *tree = std::ptr::null_mut(); }\n    panic_boundary(|| " + name + "_inner(" + ", ".join(arguments) + ")).unwrap_or(resvg_error::PARSING_FAILED as i32)\n}\n\n"
        inner_signature = signature.replace('pub extern "C" fn ' + name, 'fn ' + name + '_inner', 1)
        text = text[:start] + wrapper + inner_signature + text[body_start:]
    (root / "crates/c-api/lib.rs").write_text(text)
    header = root / "crates/c-api/resvg.h"
    h = header.read_text()
    declaration = re.search(r"void resvg_render\([^;]+;", h).group(0)
    assert "resvg_render_checked" not in h
    h = h.replace(declaration, declaration + "\n\n/* EPUBLib: false means the drawing panicked; the tree is invalidated. */\n" + declaration.replace("void resvg_render(", "bool resvg_render_checked("))
    header.write_text(h)
    profile = root / "Cargo.toml"
    cargo = profile.read_text()
    assert '[profile.production]' in cargo and 'panic = "abort"' not in cargo
    cargo = cargo.replace('[profile.production]', '[profile.production]\npanic = "unwind"')
    profile.write_text(cargo)
