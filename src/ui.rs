//! Small shared UI pieces.

use gpui::{IntoElement, Keystroke, ParentElement, Styled, div};
use gpui_component::{h_flex, kbd::Kbd};

/// Keycaps for `keys` (gpui keystroke syntax, e.g. `"cmd-enter"`) followed by a label.
pub fn key_hint(keys: &[&str], label: &'static str) -> impl IntoElement {
    h_flex()
        .gap_1()
        .children(
            keys.iter()
                .filter_map(|key| Keystroke::parse(key).ok())
                .map(Kbd::new),
        )
        .child(div().child(label))
}
