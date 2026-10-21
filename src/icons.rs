//! App assets: gpui-component's default Lucide icon bundle plus the extra icons this app uses.

use std::borrow::Cow;

use gpui::{AssetSource, SharedString};

/// The full Lucide catalog (gpui-component's own `IconName` covers only its built-in icons).
pub use gpui_kit_assets::IconName;

gpui_kit_assets::icon_assets!(
    ExtraIcons,
    [
        Apple,
        Cable,
        Clock,
        Columns2,
        CornerDownLeft,
        FaceSlightlySmiling,
        Flag,
        FolderInput,
        FolderPlus,
        Globe,
        GitBranch,
        GripVertical,
        Hand,
        Hash,
        Image,
        ImageUp,
        KeyRound,
        Lightbulb,
        Lock,
        LockOpen,
        PawPrint,
        Pencil,
        Plane,
        Play,
        Server,
        Shield,
        Rows2,
        ScrollText,
        Terminal,
        TextCursorInput,
        Timer,
        Trash,
        Trophy,
        Circle,
        Code,
        LayoutGrid,
        Pin,
        PinOff,
        RotateCw,
        ShieldOff,
        Square,
        X,
    ]
);

pub struct AppAssets;

impl AssetSource for AppAssets {
    fn load(&self, path: &str) -> gpui::Result<Option<Cow<'static, [u8]>>> {
        if let Some(bytes) = ExtraIcons.load(path)? {
            return Ok(Some(bytes));
        }
        gpui_kit_assets::Assets.load(path)
    }

    fn list(&self, path: &str) -> gpui::Result<Vec<SharedString>> {
        let mut paths = gpui_kit_assets::Assets.list(path)?;
        paths.extend(ExtraIcons.list(path)?);
        paths.sort();
        paths.dedup();
        Ok(paths)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_icon_used_by_the_app_is_bundled() {
        let used = [
            IconName::ChevronDown,
            IconName::ChevronRight,
            IconName::CircleCheck,
            IconName::CircleX,
            IconName::Clock,
            IconName::Columns2,
            IconName::CornerDownLeft,
            IconName::Ellipsis,
            IconName::File,
            IconName::Folder,
            IconName::FolderInput,
            IconName::FolderOpen,
            IconName::FolderPlus,
            IconName::Globe,
            IconName::GitBranch,
            IconName::GripVertical,
            IconName::PanelLeftClose,
            IconName::PanelLeftOpen,
            IconName::Pencil,
            IconName::Play,
            IconName::Plus,
            IconName::Rows2,
            IconName::Search,
            IconName::Settings,
            IconName::SquareTerminal,
            IconName::Terminal,
            IconName::TextCursorInput,
            IconName::Timer,
            IconName::Trash,
            IconName::X,
            IconName::Apple,
            IconName::FaceSlightlySmiling,
            IconName::Flag,
            IconName::Hand,
            IconName::Hash,
            IconName::Image,
            IconName::ImageUp,
            IconName::Lightbulb,
            IconName::PawPrint,
            IconName::Plane,
            IconName::Trophy,
            IconName::Server,
            IconName::Shield,
            IconName::Cable,
            IconName::ScrollText,
            IconName::Lock,
            IconName::LockOpen,
            IconName::KeyRound,
            IconName::Circle,
        ];
        for icon in used {
            let path = icon.path();
            assert!(
                AppAssets.load(&path).unwrap().is_some(),
                "missing icon asset {path}"
            );
        }
    }
}
