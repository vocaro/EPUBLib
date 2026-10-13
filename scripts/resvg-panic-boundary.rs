/// @brief A stable opaque handle; a panicking tree is dropped before another call can use it.
pub struct resvg_render_tree {
    state: std::sync::Mutex<Option<resvg_tree_data>>,
}

struct resvg_tree_data(pub usvg::Tree);

impl resvg_render_tree {
    fn new(tree: usvg::Tree) -> Self {
        Self { state: std::sync::Mutex::new(Some(resvg_tree_data(tree))) }
    }
}

// Keep the host's panic hook unchanged. A caught renderer panic still writes its
// normal diagnostic to stderr; callers get failure and can show their own fallback.
fn panic_boundary<T>(action: impl FnOnce() -> T) -> Result<T, Box<dyn std::any::Any + Send>> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(action))
}

fn with_tree<T>(tree: *const resvg_render_tree, fallback: T, action: impl FnOnce(*const resvg_tree_data) -> T) -> T {
    if tree.is_null() { return fallback; }
    let handle = unsafe { &*tree };
    // No unwind crosses this guard, so a caught panic never poisons the mutex.
    let Ok(mut state) = handle.state.lock() else { return fallback; };
    let Some(data) = state.as_ref() else { return fallback; };
    match panic_boundary(|| action(data)) {
        Ok(result) => result,
        Err(_) => {
            // Dispose of all parser/renderer state while holding exclusive access.
            *state = None;
            fallback
        }
    }
}
