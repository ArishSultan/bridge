//! Input translation: gpui keystrokes and modifiers -> libghostty's key model.

use gpui::{Keystroke, Modifiers};
use libghostty_vt::key::{Key, Mods};

use crate::terminal::KeyInput;

/// Convert gpui modifiers into libghostty's modifier mask.
pub fn mods(modifiers: &Modifiers) -> Mods {
    let mut mods = Mods::empty();
    mods.set(Mods::SHIFT, modifiers.shift);
    mods.set(Mods::CTRL, modifiers.control);
    mods.set(Mods::ALT, modifiers.alt);
    mods.set(Mods::SUPER, modifiers.platform);
    mods
}

/// Map a keystroke that the terminal must encode itself.
///
/// Returns `None` for plain printable input: that text is delivered through the platform input
/// handler instead, so dead keys and IME composition keep working. With `option_as_alt`, Option
/// chords are encoded here (as Alt) instead of producing composed characters.
pub fn key_input(keystroke: &Keystroke, repeat: bool, option_as_alt: bool) -> Option<KeyInput> {
    let modifiers = &keystroke.modifiers;
    let named = named_key(&keystroke.key);
    let chord = modifiers.control || (option_as_alt && modifiers.alt);
    if named.is_none() && !chord {
        return None;
    }
    let mut chars = keystroke.key.chars();
    let single = match (chars.next(), chars.next()) {
        (Some(ch), None) => Some(ch),
        _ => None,
    };
    let key = named.or_else(|| single.and_then(character_key))?;

    // libghostty wants the layout text without Ctrl/Alt transformations and never control chars.
    // For Option chords `key_char` holds the composed character (e.g. "å"), so use the key itself.
    let composed = modifiers.alt && option_as_alt;
    let text = if composed {
        named.is_none().then(|| keystroke.key.clone())
    } else {
        keystroke
            .key_char
            .clone()
            .filter(|text| !text.chars().any(char::is_control))
            .or_else(|| named.is_none().then(|| keystroke.key.clone()))
    }
    .filter(|text| !text.is_empty() && !text.chars().any(char::is_control));
    let unshifted = single.or(match key {
        Key::Space => Some(' '),
        _ => None,
    });

    Some(KeyInput {
        key,
        mods: mods(modifiers),
        text,
        unshifted,
        repeat,
    })
}

/// What a key should do while a shell prompt (not a full-screen app) has the keyboard.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PromptKey {
    /// Encode and send this key.
    Send(KeyInput),
    /// Send these bytes (readline/zle editing commands).
    Bytes(&'static [u8]),
    /// Scroll the viewport by a page.
    ScrollPage { up: bool },
    /// Swallow the key: shells would print its escape sequence as junk characters.
    Ignore,
}

/// Make a key safe for line editors.
///
/// Shells only understand a handful of modified keys; the rest of their escape sequences end up
/// on the command line as stray characters (e.g. `;2D` for Shift+Left). At the prompt, modifiers
/// on navigation keys are therefore dropped, Home/End become line start/end, Page Up/Down scroll
/// the history, and function keys are ignored.
pub fn prompt_key(mut input: KeyInput) -> PromptKey {
    let edit_mods = Mods::SHIFT | Mods::ALT | Mods::CTRL | Mods::SUPER;
    match input.key {
        Key::Home => PromptKey::Bytes(b"\x01"),
        Key::End => PromptKey::Bytes(b"\x05"),
        Key::PageUp => PromptKey::ScrollPage { up: true },
        Key::PageDown => PromptKey::ScrollPage { up: false },
        Key::Insert
        | Key::F1
        | Key::F2
        | Key::F3
        | Key::F4
        | Key::F5
        | Key::F6
        | Key::F7
        | Key::F8
        | Key::F9
        | Key::F10
        | Key::F11
        | Key::F12 => PromptKey::Ignore,
        Key::ArrowUp
        | Key::ArrowDown
        | Key::ArrowLeft
        | Key::ArrowRight
        | Key::Enter
        | Key::Backspace
        | Key::Delete
        | Key::Escape => {
            input.mods.remove(edit_mods);
            PromptKey::Send(input)
        }
        // Shift+Tab (reverse completion) and everything else pass through unchanged.
        _ => PromptKey::Send(input),
    }
}

/// Keys identified by gpui's name rather than by the character they produce.
fn named_key(name: &str) -> Option<Key> {
    Some(match name {
        "enter" => Key::Enter,
        "tab" => Key::Tab,
        "backspace" => Key::Backspace,
        "escape" => Key::Escape,
        "space" => Key::Space,
        "up" => Key::ArrowUp,
        "down" => Key::ArrowDown,
        "left" => Key::ArrowLeft,
        "right" => Key::ArrowRight,
        "home" => Key::Home,
        "end" => Key::End,
        "pageup" => Key::PageUp,
        "pagedown" => Key::PageDown,
        "insert" => Key::Insert,
        "delete" => Key::Delete,
        "f1" => Key::F1,
        "f2" => Key::F2,
        "f3" => Key::F3,
        "f4" => Key::F4,
        "f5" => Key::F5,
        "f6" => Key::F6,
        "f7" => Key::F7,
        "f8" => Key::F8,
        "f9" => Key::F9,
        "f10" => Key::F10,
        "f11" => Key::F11,
        "f12" => Key::F12,
        _ => return None,
    })
}

/// Physical (W3C `code`) key for a character on a US layout.
fn character_key(ch: char) -> Option<Key> {
    const LETTERS: [Key; 26] = [
        Key::A,
        Key::B,
        Key::C,
        Key::D,
        Key::E,
        Key::F,
        Key::G,
        Key::H,
        Key::I,
        Key::J,
        Key::K,
        Key::L,
        Key::M,
        Key::N,
        Key::O,
        Key::P,
        Key::Q,
        Key::R,
        Key::S,
        Key::T,
        Key::U,
        Key::V,
        Key::W,
        Key::X,
        Key::Y,
        Key::Z,
    ];
    const DIGITS: [Key; 10] = [
        Key::Digit0,
        Key::Digit1,
        Key::Digit2,
        Key::Digit3,
        Key::Digit4,
        Key::Digit5,
        Key::Digit6,
        Key::Digit7,
        Key::Digit8,
        Key::Digit9,
    ];
    let lower = ch.to_ascii_lowercase();
    Some(match lower {
        'a'..='z' => LETTERS[(lower as u8 - b'a') as usize],
        '0'..='9' => DIGITS[(lower as u8 - b'0') as usize],
        '`' | '~' => Key::Backquote,
        '\\' | '|' => Key::Backslash,
        '[' | '{' => Key::BracketLeft,
        ']' | '}' => Key::BracketRight,
        ',' | '<' => Key::Comma,
        '=' | '+' => Key::Equal,
        '-' | '_' => Key::Minus,
        '.' | '>' => Key::Period,
        '\'' | '"' => Key::Quote,
        ';' | ':' => Key::Semicolon,
        '/' | '?' => Key::Slash,
        ' ' => Key::Space,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keystroke(key: &str, key_char: Option<&str>, modifiers: Modifiers) -> Keystroke {
        Keystroke {
            modifiers,
            key: key.into(),
            key_char: key_char.map(Into::into),
        }
    }

    #[test]
    fn printable_keys_are_left_to_the_input_handler() {
        assert!(
            key_input(
                &keystroke("a", Some("a"), Modifiers::default()),
                false,
                false
            )
            .is_none()
        );
        let shifted = Modifiers {
            shift: true,
            ..Default::default()
        };
        assert!(key_input(&keystroke("1", Some("!"), shifted), false, false).is_none());
    }

    #[test]
    fn maps_named_keys() {
        let input = key_input(
            &keystroke("enter", Some("\n"), Modifiers::default()),
            false,
            false,
        )
        .unwrap();
        assert_eq!(input.key, Key::Enter);
        assert_eq!(input.text, None);

        let input = key_input(&keystroke("up", None, Modifiers::default()), true, false).unwrap();
        assert_eq!(input.key, Key::ArrowUp);
        assert!(input.repeat);
    }

    #[test]
    fn maps_control_chords() {
        let ctrl = Modifiers {
            control: true,
            ..Default::default()
        };
        let input = key_input(&keystroke("c", None, ctrl), false, false).unwrap();
        assert_eq!(input.key, Key::C);
        assert_eq!(input.mods, Mods::CTRL);
        assert_eq!(input.text.as_deref(), Some("c"));
        assert_eq!(input.unshifted, Some('c'));
    }

    #[test]
    fn prompt_keys_never_produce_junk() {
        let modified = |key: Key, mods: Mods| KeyInput {
            mods,
            ..KeyInput::named(key)
        };
        assert_eq!(
            prompt_key(modified(Key::ArrowUp, Mods::CTRL)),
            PromptKey::Send(KeyInput::named(Key::ArrowUp))
        );
        assert_eq!(
            prompt_key(modified(Key::Enter, Mods::SHIFT)),
            PromptKey::Send(KeyInput::named(Key::Enter))
        );
        assert_eq!(
            prompt_key(KeyInput::named(Key::Home)),
            PromptKey::Bytes(b"\x01")
        );
        assert_eq!(
            prompt_key(KeyInput::named(Key::PageUp)),
            PromptKey::ScrollPage { up: true }
        );
        assert_eq!(prompt_key(KeyInput::named(Key::F5)), PromptKey::Ignore);
        let shift_tab = modified(Key::Tab, Mods::SHIFT);
        assert_eq!(prompt_key(shift_tab.clone()), PromptKey::Send(shift_tab));
    }

    #[test]
    fn option_chords_depend_on_option_as_alt() {
        let alt = Modifiers {
            alt: true,
            ..Default::default()
        };
        let stroke = keystroke("a", Some("å"), alt);
        assert!(
            key_input(&stroke, false, false).is_none(),
            "composed text goes to the IME"
        );
        let input = key_input(&stroke, false, true).unwrap();
        assert_eq!(input.key, Key::A);
        assert_eq!(input.mods, Mods::ALT);
        assert_eq!(input.text.as_deref(), Some("a"));
    }
}
