//! Project icons: an emoji, or a custom SVG imported into the app's config folder (so the project
//! keeps its icon if the original file moves). One-color SVGs — icon sets such as Lucide,
//! Heroicons or Simple Icons — are kept as SVG and drawn in the project's color; multi-color ones
//! (logos) are rasterized once, large enough to stay sharp, and keep their own colors.

use std::{
    fs,
    path::{Path, PathBuf},
};

use crate::settings::TerminalSettings;

/// Stored icons are `file:<name>` in the group's `icon` field; anything else is an emoji.
const FILE_PREFIX: &str = "file:";
/// Pixel size multi-color icons are rasterized at.
const RASTER_SIZE: u32 = 128;

pub enum GroupIcon<'a> {
    Emoji(&'a str),
    /// One color: drawn as a mask in the group's color.
    Svg(PathBuf),
    /// Multi-color, rasterized.
    Image(PathBuf),
}

pub fn parse(icon: &str) -> GroupIcon<'_> {
    match icon.strip_prefix(FILE_PREFIX) {
        Some(name) if name.ends_with(".svg") => GroupIcon::Svg(icons_dir().join(name)),
        Some(name) => GroupIcon::Image(icons_dir().join(name)),
        None => GroupIcon::Emoji(icon),
    }
}

fn icons_dir() -> PathBuf {
    TerminalSettings::path()
        .parent()
        .map_or_else(|| PathBuf::from("icons"), |dir| dir.join("icons"))
}

/// Imported icons, newest first, as values for a group's `icon`.
pub fn imported() -> Vec<String> {
    let Ok(entries) = fs::read_dir(icons_dir()) else {
        return Vec::new();
    };
    let mut icons: Vec<(std::time::SystemTime, String)> = entries
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_str()?.to_owned();
            let modified = entry.metadata().and_then(|meta| meta.modified()).ok()?;
            (name.ends_with(".svg") || name.ends_with(".png"))
                .then(|| (modified, format!("{FILE_PREFIX}{name}")))
        })
        .collect();
    icons.sort_by_key(|(modified, _)| std::cmp::Reverse(*modified));
    icons.into_iter().map(|(_, icon)| icon).collect()
}

/// Copy an SVG into the icons folder; returns the value for a group's `icon`.
pub fn import(path: &Path) -> Result<String, String> {
    let bytes = fs::read(path).map_err(|err| format!("Could not read the file: {err}"))?;
    let tree = resvg::usvg::Tree::from_data(&bytes, &resvg::usvg::Options::default())
        .map_err(|_| "That file is not a valid SVG.".to_owned())?;
    let dir = icons_dir();
    fs::create_dir_all(&dir).map_err(|err| format!("Could not save the icon: {err}"))?;
    let stem = format!("{:016x}", fnv1a(&bytes));

    let name = if is_monochrome(&String::from_utf8_lossy(&bytes)) {
        let name = format!("{stem}.svg");
        fs::write(dir.join(&name), &bytes)
            .map_err(|err| format!("Could not save the icon: {err}"))?;
        name
    } else {
        let name = format!("{stem}.png");
        let png = rasterize(&tree).ok_or("Could not draw that SVG.")?;
        fs::write(dir.join(&name), png).map_err(|err| format!("Could not save the icon: {err}"))?;
        name
    };
    Ok(format!("{FILE_PREFIX}{name}"))
}

/// Whether an SVG uses no color but black, `currentColor` and transparency, so it can be drawn
/// in any one color without losing anything.
pub fn is_monochrome(svg: &str) -> bool {
    const NEUTRAL: &[&str] = &[
        "none",
        "currentcolor",
        "black",
        "#000",
        "#000000",
        "#000f",
        "#000000ff",
        "transparent",
        "inherit",
    ];
    let svg = svg.to_ascii_lowercase();
    ["fill", "stroke", "stop-color", "color", "flood-color"]
        .iter()
        .all(|property| {
            attribute_values(&svg, property).all(|value| {
                let value = value.trim();
                NEUTRAL.contains(&value) || value.starts_with("url(") || value.is_empty()
            })
        })
}

/// Values of `property` set as an attribute (`fill="…"`) or in a style (`fill: …;`).
fn attribute_values<'a>(svg: &'a str, property: &'a str) -> impl Iterator<Item = &'a str> + 'a {
    svg.match_indices(property).filter_map(move |(index, _)| {
        // Skip longer names such as `fill-opacity` or `fill-rule`, and other words ending in it.
        let before = svg[..index].chars().next_back();
        if before.is_some_and(|ch| ch.is_ascii_alphanumeric() || ch == '-') {
            return None;
        }
        let rest = svg[index + property.len()..].trim_start();
        if let Some(rest) = rest.strip_prefix('=') {
            let rest = rest.trim_start();
            let quote = rest.chars().next().filter(|ch| *ch == '"' || *ch == '\'')?;
            let value = &rest[1..];
            Some(&value[..value.find(quote)?])
        } else if let Some(rest) = rest.strip_prefix(':') {
            Some(&rest[..rest.find([';', '"', '\'', '}']).unwrap_or(rest.len())])
        } else {
            None
        }
    })
}

/// Draw the SVG centered in a `RASTER_SIZE` square, as PNG.
fn rasterize(tree: &resvg::usvg::Tree) -> Option<Vec<u8>> {
    let size = tree.size();
    let scale = RASTER_SIZE as f32 / size.width().max(size.height());
    let (dx, dy) = (
        (RASTER_SIZE as f32 - size.width() * scale) / 2.,
        (RASTER_SIZE as f32 - size.height() * scale) / 2.,
    );
    let mut pixmap = resvg::tiny_skia::Pixmap::new(RASTER_SIZE, RASTER_SIZE)?;
    let transform = resvg::tiny_skia::Transform::from_scale(scale, scale).post_translate(dx, dy);
    resvg::render(tree, transform, &mut pixmap.as_mut());
    pixmap.encode_png().ok()
}

/// FNV-1a: a stable name for the same file imported twice.
fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tells_one_color_svgs_from_multi_color_ones() {
        let lucide = r#"<svg xmlns="http://www.w3.org/2000/svg" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 4h16"/></svg>"#;
        let plain = r#"<svg viewBox="0 0 24 24"><path fill-rule="evenodd" d="M0 0h24v24z"/></svg>"#;
        let styled = r#"<svg><path style="fill:#000000;fill-opacity:0.5" d="M0 0h1z"/></svg>"#;
        let logo =
            r##"<svg><path fill="#F05032" d="M0 0h1z"/><path fill="#fff" d="M0 0h1z"/></svg>"##;
        let styled_logo = r#"<svg><path style="fill: rgb(10, 20, 30)" d="M0 0h1z"/></svg>"#;
        assert!(is_monochrome(lucide));
        assert!(is_monochrome(plain));
        assert!(is_monochrome(styled));
        assert!(!is_monochrome(logo));
        assert!(!is_monochrome(styled_logo));
    }

    #[test]
    fn stored_icons_round_trip() {
        assert!(matches!(parse("🚀"), GroupIcon::Emoji("🚀")));
        assert!(matches!(parse("file:abc.svg"), GroupIcon::Svg(path) if path.ends_with("abc.svg")));
        assert!(
            matches!(parse("file:abc.png"), GroupIcon::Image(path) if path.ends_with("abc.png"))
        );
    }

    #[test]
    fn rasterizes_multi_color_svgs() {
        let logo = br##"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="12"><rect width="24" height="12" fill="#f00"/></svg>"##;
        let tree = resvg::usvg::Tree::from_data(logo, &resvg::usvg::Options::default()).unwrap();
        let png = rasterize(&tree).unwrap();
        assert_eq!(&png[1..4], b"PNG");
    }
}
