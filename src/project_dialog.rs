//! Create or edit a project: its folder, name, icon and color. The icon is an emoji picked
//! from a categorized, searchable picker over the full Unicode set (like WhatsApp's), a custom
//! SVG, or none for a folder icon.

use std::{ops::Range, rc::Rc};

use gpui::{
    AnyElement, App, AppContext as _, Context, Entity, EventEmitter, Hsla, InteractiveElement as _,
    IntoElement, ParentElement as _, PathPromptOptions, Pixels, Render, ScrollStrategy,
    SharedString, StatefulInteractiveElement as _, Styled as _, Subscription,
    UniformListScrollHandle, Window, div, img, prelude::FluentBuilder as _, px, svg, uniform_list,
};
use gpui_component::{
    ActiveTheme as _, Icon, Sizable as _, WindowExt as _,
    button::{Button, ButtonVariants as _},
    dialog::DialogEntrance,
    h_flex,
    input::{Input, InputEvent, InputState},
    popover::Popover,
    tooltip::Tooltip,
    v_flex,
};

use crate::{
    group_icon::{self, GroupIcon},
    icons::IconName,
    theme::{self, GROUP_COLORS},
    workspace::{expand_home, tilde},
};

const PICKER_COLUMNS: usize = 8;
const PICKER_CELL: f32 = 34.;
const PICKER_HEIGHT: f32 = 272.;
/// Emoji newer than this may have no glyph in the system font yet.
const MAX_EMOJI_VERSION: (u32, u32) = (15, 1);

/// The picker's categories, each with the icon that stands for it in the tab bar.
const CATEGORIES: [(emojis::Group, &str, IconName); 9] = [
    (
        emojis::Group::SmileysAndEmotion,
        "Smileys & emotion",
        IconName::FaceSlightlySmiling,
    ),
    (
        emojis::Group::PeopleAndBody,
        "People & body",
        IconName::Hand,
    ),
    (
        emojis::Group::AnimalsAndNature,
        "Animals & nature",
        IconName::PawPrint,
    ),
    (emojis::Group::FoodAndDrink, "Food & drink", IconName::Apple),
    (
        emojis::Group::TravelAndPlaces,
        "Travel & places",
        IconName::Plane,
    ),
    (emojis::Group::Activities, "Activities", IconName::Trophy),
    (emojis::Group::Objects, "Objects", IconName::Lightbulb),
    (emojis::Group::Symbols, "Symbols", IconName::Hash),
    (emojis::Group::Flags, "Flags", IconName::Flag),
];
/// Heading of the imported SVGs, listed first.
const CUSTOM: &str = "Custom";

/// What the dialog edits.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ProjectForm {
    pub name: String,
    pub icon: Option<String>,
    pub color: Option<String>,
    /// As typed, `~` allowed.
    pub dir: String,
}

type OnSave = Rc<dyn Fn(ProjectForm, &mut Window, &mut App)>;

/// Edit a project; `on_save` gets the result once the dialog has closed.
pub fn open(
    form: ProjectForm,
    window: &mut Window,
    cx: &mut App,
    on_save: impl Fn(ProjectForm, &mut Window, &mut App) + 'static,
) {
    let editor = cx.new(|cx| ProjectEditor::new(form, window, cx));
    let on_save: OnSave = Rc::new(on_save);
    let name = editor.read(cx).name.clone();
    window.open_dialog(cx, move |dialog, _, _| {
        let (on_enter, on_click) = (
            (editor.clone(), on_save.clone()),
            (editor.clone(), on_save.clone()),
        );
        dialog
            .title("Edit project")
            .w(px(440.))
            .entrance(DialogEntrance::FadeSlide)
            // Enter confirms, like the button.
            .on_ok(move |_, window, cx| submit(&on_enter.0, &on_enter.1, window, cx))
            .child(editor.clone())
            .footer(
                h_flex()
                    .w_full()
                    .justify_end()
                    .gap_2()
                    .child(
                        Button::new("group-cancel")
                            .label("Cancel")
                            .on_click(|_, window, cx| window.close_dialog(cx)),
                    )
                    .child(Button::new("group-save").primary().label("Save").on_click(
                        move |_, window, cx| {
                            if submit(&on_click.0, &on_click.1, window, cx) {
                                window.close_dialog(cx);
                            }
                        },
                    )),
            )
    });
    window.defer(cx, move |window, cx| {
        name.update(cx, |input, cx| input.focus(window, cx))
    });
}

/// Validate and hand the form over. Returns whether the dialog may close.
fn submit(
    editor: &Entity<ProjectEditor>,
    on_save: &OnSave,
    window: &mut Window,
    cx: &mut App,
) -> bool {
    let Some(form) = editor.read(cx).form(cx) else {
        editor.update(cx, |editor, cx| {
            editor.show_errors = true;
            cx.notify();
        });
        return false;
    };
    // After the dialog has closed and given focus back.
    let on_save = on_save.clone();
    window.defer(cx, move |window, cx| on_save(form, window, cx));
    true
}

/// The square that stands for a project: its emoji or SVG, or a folder icon, on a tint of its color.
pub fn group_tile(icon: Option<&str>, color: Option<Hsla>, size: Pixels, cx: &App) -> gpui::Div {
    let theme = cx.theme();
    let tile = div()
        .flex_none()
        .size(size)
        .flex()
        .items_center()
        .justify_center()
        .rounded(size * 0.28)
        .bg(color.map_or(theme.muted, |color| color.opacity(0.18)));
    match icon.map(group_icon::parse) {
        Some(GroupIcon::Emoji(emoji)) => tile
            .text_size(size * 0.64)
            .line_height(size)
            .child(emoji.to_owned()),
        Some(GroupIcon::Svg(path)) => tile.child(
            svg()
                .external_path(path.to_string_lossy().into_owned())
                .size(size * 0.62)
                .text_color(color.unwrap_or(theme.foreground)),
        ),
        Some(GroupIcon::Image(path)) => tile.child(img(path).size(size * 0.7)),
        None => tile.child(
            Icon::new(IconName::Folder)
                .size(size * 0.6)
                .text_color(color.unwrap_or(theme.muted_foreground)),
        ),
    }
}

/// The form's state while the dialog is open.
struct ProjectEditor {
    name: Entity<InputState>,
    dir: Entity<InputState>,
    icon: Option<String>,
    color: Option<String>,
    picker: Entity<EmojiPicker>,
    picker_open: bool,
    /// Set after a failed save, so a problem shows only once it matters.
    show_errors: bool,
    _subscriptions: Vec<Subscription>,
}

impl ProjectEditor {
    fn new(form: ProjectForm, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let name = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("Named after the folder")
                .default_value(form.name)
        });
        let dir = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("~")
                .default_value(form.dir)
        });
        let picker = cx.new(|cx| EmojiPicker::new(window, cx));
        let subscriptions = vec![
            cx.subscribe(&picker, |this, _, PickEmoji(icon), cx| {
                this.icon = icon.clone();
                this.picker_open = false;
                cx.notify();
            }),
            // The full-path hint follows the folder field.
            cx.subscribe(&dir, |_, _, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) {
                    cx.notify();
                }
            }),
        ];
        Self {
            name,
            dir,
            icon: form.icon,
            color: form.color,
            picker,
            picker_open: false,
            show_errors: false,
            _subscriptions: subscriptions,
        }
    }

    /// The folder as typed (home when empty).
    fn dir_text(&self, cx: &App) -> String {
        let dir = self.dir.read(cx).value().trim().to_owned();
        if dir.is_empty() { "~".to_owned() } else { dir }
    }

    /// The form as entered, or `None` while the folder does not exist.
    fn form(&self, cx: &App) -> Option<ProjectForm> {
        let path = expand_home(&self.dir_text(cx));
        if !path.is_dir() {
            return None;
        }
        let name = self.name.read(cx).value().trim().to_owned();
        let name = if name.is_empty() {
            folder_name(&path)
        } else {
            name
        };
        Some(ProjectForm {
            name,
            icon: self.icon.clone(),
            color: self.color.clone(),
            dir: tilde(&path.to_string_lossy()),
        })
    }

    fn browse(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let paths = cx.prompt_for_paths(PathPromptOptions {
            files: false,
            directories: true,
            multiple: false,
            prompt: Some("Choose".into()),
        });
        cx.spawn_in(window, async move |this, cx| {
            if let Ok(Ok(Some(paths))) = paths.await
                && let Some(dir) = paths.into_iter().next()
            {
                let _ = this.update_in(cx, |this, window, cx| {
                    let text = SharedString::from(tilde(&dir.to_string_lossy()));
                    this.dir
                        .update(cx, |input, cx| input.set_value(text, window, cx));
                    if this.name.read(cx).value().trim().is_empty() {
                        let name = SharedString::from(folder_name(&dir));
                        this.name
                            .update(cx, |input, cx| input.set_value(name, window, cx));
                    }
                    cx.notify();
                });
            }
        })
        .detach();
    }

    fn render_icon_picker(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let color = self
            .color
            .as_deref()
            .and_then(|id| theme::group_color(id, cx));
        let tile = group_tile(self.icon.as_deref(), color, px(26.), cx);
        let picker = self.picker.clone();
        let editor = cx.entity().downgrade();
        Popover::new("group-icon-picker")
            .open(self.picker_open)
            .on_open_change(move |open, _, cx| {
                let _ = editor.update(cx, |editor, cx| {
                    editor.picker_open = *open;
                    cx.notify();
                });
            })
            .trigger(
                Button::new("group-icon")
                    .outline()
                    .w(px(36.))
                    .h(px(36.))
                    .child(tile),
            )
            .content(move |_, _, _| picker.clone())
    }

    fn render_colors(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let none = self.render_swatch(None, "No color", cx);
        let swatches: Vec<AnyElement> = GROUP_COLORS
            .iter()
            .map(|(id, label, ..)| self.render_swatch(Some(id), label, cx))
            .collect();
        h_flex().gap_1().child(none).children(swatches)
    }

    fn render_swatch(
        &self,
        id: Option<&'static str>,
        label: &'static str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme = cx.theme();
        let selected = self.color.as_deref() == id;
        let color = id.and_then(|id| theme::group_color(id, cx));
        let ring = color.unwrap_or(theme.foreground);
        let dot = div().size(px(18.)).rounded_full().map(|dot| match color {
            Some(color) => dot.bg(color),
            None => dot.border_1().border_color(theme.muted_foreground),
        });
        div()
            .id(SharedString::from(format!(
                "group-color-{}",
                id.unwrap_or("none")
            )))
            .size(px(28.))
            .flex()
            .items_center()
            .justify_center()
            .rounded_full()
            .cursor_pointer()
            .border_2()
            .border_color(if selected {
                ring
            } else {
                gpui::transparent_black()
            })
            .tooltip(move |window, cx| Tooltip::new(label).build(window, cx))
            .on_click(cx.listener(move |this, _, _, cx| {
                this.color = id.map(str::to_owned);
                cx.notify();
            }))
            .child(dot)
            .into_any_element()
    }
}

impl Render for ProjectEditor {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let (muted, danger) = (theme.muted_foreground, theme.danger);
        let path = expand_home(&self.dir_text(cx));
        let exists = path.is_dir();
        let hint = if exists || !self.show_errors {
            div()
                .text_color(muted)
                .child(path.to_string_lossy().into_owned())
        } else {
            div().text_color(danger).child("Folder not found")
        };

        v_flex()
            .gap_4()
            .child(
                h_flex()
                    .gap_3()
                    .items_end()
                    .child(field("Icon", self.render_icon_picker(cx)))
                    .child(div().flex_1().child(field("Name", Input::new(&self.name)))),
            )
            .child(field("Color", self.render_colors(cx)))
            .child(field(
                "Folder",
                v_flex()
                    .gap_1p5()
                    .child(
                        h_flex()
                            .gap_2()
                            .child(div().flex_1().child(Input::new(&self.dir)))
                            .child(Button::new("group-browse").label("Browse").on_click(
                                cx.listener(|this, _, window, cx| this.browse(window, cx)),
                            )),
                    )
                    .child(hint.text_xs().truncate()),
            ))
    }
}

/// A labeled form row.
/// A setting with a switch: the label and description take the width and wrap, the switch keeps
/// its size on the right (so it can never be pushed past the dialog's edge).
pub(crate) fn toggle_row(
    label: &'static str,
    description: &'static str,
    switch: gpui_component::switch::Switch,
) -> impl IntoElement {
    h_flex()
        .w_full()
        .items_start()
        .gap_3()
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .gap_0p5()
                .child(div().text_sm().child(label))
                .child(div().text_xs().opacity(0.7).child(description)),
        )
        .child(div().flex_none().pt_0p5().child(switch))
}

pub(crate) fn field(label: &'static str, control: impl IntoElement) -> impl IntoElement {
    v_flex()
        .gap_1p5()
        .child(
            div()
                .text_sm()
                .font_weight(gpui::FontWeight::MEDIUM)
                .child(label),
        )
        .child(control)
}

pub(crate) fn folder_name(path: &std::path::Path) -> String {
    path.file_name().map_or_else(
        || path.to_string_lossy().into_owned(),
        |name| name.to_string_lossy().into_owned(),
    )
}

/// The picker chose an emoji (`None`: no icon).
struct PickEmoji(Option<String>);

/// One line of the picker: a heading, a row of emoji or a row of imported SVGs.
enum PickerRow {
    Heading(&'static str),
    Emoji(Vec<&'static str>),
    Custom(Vec<String>),
}

struct EmojiPicker {
    search: Entity<InputState>,
    rows: Vec<PickerRow>,
    scroll: UniformListScrollHandle,
    /// Why the last SVG import failed.
    import_error: Option<String>,
    _subscription: Subscription,
}

impl EventEmitter<PickEmoji> for EmojiPicker {}

impl EmojiPicker {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search emoji"));
        let subscription = cx.subscribe(&search, |this, search, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                this.rows = picker_rows(&search.read(cx).value(), &group_icon::imported());
                this.scroll.scroll_to_item(0, ScrollStrategy::Top);
                cx.notify();
            }
        });
        Self {
            search,
            rows: picker_rows("", &group_icon::imported()),
            scroll: UniformListScrollHandle::new(),
            import_error: None,
            _subscription: subscription,
        }
    }

    /// Ask for an SVG file, import it and pick it.
    fn import_svg(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let paths = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some("Use icon".into()),
        });
        cx.spawn_in(window, async move |this, cx| {
            if let Ok(Ok(Some(paths))) = paths.await
                && let Some(path) = paths.into_iter().next()
            {
                let _ = this.update_in(cx, |this, window, cx| {
                    match group_icon::import(&path) {
                        Ok(icon) => {
                            this.import_error = None;
                            this.search
                                .update(cx, |search, cx| search.set_value("", window, cx));
                            this.rows = picker_rows("", &group_icon::imported());
                            cx.emit(PickEmoji(Some(icon)));
                        }
                        Err(err) => this.import_error = Some(err),
                    }
                    cx.notify();
                });
            }
        })
        .detach();
    }

    /// The heading of the section at the top of the list, for the tab bar.
    fn current_section(&self) -> Option<&'static str> {
        let offset = -f32::from(self.scroll.0.borrow().base_handle.offset().y);
        // Count a section as current once its heading is half scrolled away.
        let top = ((offset + PICKER_CELL * 0.5) / PICKER_CELL).floor().max(0.) as usize;
        self.rows
            .iter()
            .take(top + 1)
            .rev()
            .find_map(|row| match row {
                PickerRow::Heading(label) => Some(*label),
                _ => None,
            })
    }

    fn jump_to(&mut self, heading: &'static str, window: &mut Window, cx: &mut Context<Self>) {
        if !self.search.read(cx).value().is_empty() {
            self.search
                .update(cx, |search, cx| search.set_value("", window, cx));
            self.rows = picker_rows("", &group_icon::imported());
        }
        if let Some(index) = self
            .rows
            .iter()
            .position(|row| matches!(row, PickerRow::Heading(label) if *label == heading))
        {
            self.scroll.scroll_to_item(index, ScrollStrategy::Top);
        }
        cx.notify();
    }

    fn render_rows(&self, range: Range<usize>, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let theme = cx.theme();
        let (muted, hover) = (theme.muted_foreground, theme.accent);
        range
            .filter_map(|index| self.rows.get(index).map(|row| (index, row)))
            .map(|(index, row)| match row {
                PickerRow::Heading(label) => div()
                    .h(px(PICKER_CELL))
                    .pt_3()
                    .px_1()
                    .text_xs()
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .text_color(muted)
                    .child(*label)
                    .into_any_element(),
                PickerRow::Emoji(emoji) => h_flex()
                    .h(px(PICKER_CELL))
                    .children(emoji.iter().enumerate().map(|(column, emoji)| {
                        let emoji = *emoji;
                        div()
                            .id(("emoji", index * PICKER_COLUMNS + column))
                            .size(px(PICKER_CELL))
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded_md()
                            .text_size(px(20.))
                            .cursor_pointer()
                            .hover(move |style| style.bg(hover))
                            .on_click(cx.listener(move |_, _, _, cx| {
                                cx.emit(PickEmoji(Some(emoji.to_owned())))
                            }))
                            .child(emoji)
                    }))
                    .into_any_element(),
                PickerRow::Custom(icons) => h_flex()
                    .h(px(PICKER_CELL))
                    .children(icons.iter().enumerate().map(|(column, icon)| {
                        let pick = icon.clone();
                        div()
                            .id(("custom-icon", index * PICKER_COLUMNS + column))
                            .size(px(PICKER_CELL))
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded_md()
                            .cursor_pointer()
                            .hover(move |style| style.bg(hover))
                            .on_click(cx.listener(move |_, _, _, cx| {
                                cx.emit(PickEmoji(Some(pick.clone())))
                            }))
                            .child(group_tile(Some(icon), None, px(26.), cx))
                    }))
                    .into_any_element(),
            })
            .collect()
    }
}

impl Render for EmojiPicker {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let (muted, foreground, hover, indicator, border, danger) = (
            theme.muted_foreground,
            theme.foreground,
            theme.accent,
            theme.primary,
            theme.border,
            theme.danger,
        );
        let current = self.current_section();
        let has_custom = self
            .rows
            .iter()
            .any(|row| matches!(row, PickerRow::Heading(CUSTOM)));
        let sections = has_custom
            .then_some((CUSTOM, IconName::Image))
            .into_iter()
            .chain(CATEGORIES.iter().map(|(_, label, icon)| (*label, *icon)));
        // Equal-width tabs, the current one underlined, like WhatsApp's category bar.
        let tabs = sections.map(|(label, icon)| {
            let active = current == Some(label);
            div()
                .id(SharedString::from(format!("emoji-tab-{label}")))
                .relative()
                .flex_1()
                .h(px(30.))
                .flex()
                .items_center()
                .justify_center()
                .rounded_md()
                .cursor_pointer()
                .text_color(if active { foreground } else { muted })
                .hover(move |style| style.bg(hover).text_color(foreground))
                .tooltip(move |window, cx| Tooltip::new(label).build(window, cx))
                .on_click(cx.listener(move |this, _, window, cx| this.jump_to(label, window, cx)))
                .child(Icon::new(icon).small())
                .when(active, |tab| {
                    tab.child(
                        div()
                            .absolute()
                            .bottom_0()
                            .left(px(6.))
                            .right(px(6.))
                            .h(px(2.))
                            .rounded_full()
                            .bg(indicator),
                    )
                })
        });
        v_flex()
            .w(px(PICKER_CELL * PICKER_COLUMNS as f32))
            .gap_2()
            .child(
                h_flex()
                    .gap_1()
                    .child(
                        div().flex_1().child(
                            Input::new(&self.search)
                                .small()
                                .prefix(Icon::new(IconName::Search).small().text_color(muted))
                                .cleanable(true),
                        ),
                    )
                    .child(
                        Button::new("emoji-import")
                            .ghost()
                            .small()
                            .icon(IconName::ImageUp)
                            .tooltip("Import an SVG icon")
                            .on_click(
                                cx.listener(|this, _, window, cx| this.import_svg(window, cx)),
                            ),
                    )
                    .child(
                        Button::new("emoji-none")
                            .ghost()
                            .small()
                            .icon(IconName::Folder)
                            .tooltip("No icon (folder)")
                            .on_click(cx.listener(|_, _, _, cx| cx.emit(PickEmoji(None)))),
                    ),
            )
            .when_some(self.import_error.clone(), |picker, error| {
                picker.child(div().text_xs().text_color(danger).child(error))
            })
            .child(
                h_flex()
                    .pb_1()
                    .border_b_1()
                    .border_color(border)
                    .children(tabs),
            )
            .child(
                uniform_list(
                    "emoji-rows",
                    self.rows.len(),
                    cx.processor(|this, range, _window, cx| this.render_rows(range, cx)),
                )
                .track_scroll(&self.scroll)
                .h(px(PICKER_HEIGHT)),
            )
    }
}

/// Picker lines for a search (`""`: imported SVGs, then every category under its heading).
fn picker_rows(query: &str, custom: &[String]) -> Vec<PickerRow> {
    let query = query.trim().to_lowercase();
    let supported = |emoji: &&'static emojis::Emoji| {
        let version = emoji.emoji_version();
        (version.major(), version.minor()) <= MAX_EMOJI_VERSION
    };
    let chunked = |emoji: Vec<&'static str>| {
        emoji
            .chunks(PICKER_COLUMNS)
            .map(|chunk| PickerRow::Emoji(chunk.to_vec()))
            .collect::<Vec<_>>()
    };
    if query.is_empty() {
        let custom = (!custom.is_empty()).then(|| {
            std::iter::once(PickerRow::Heading(CUSTOM)).chain(
                custom
                    .chunks(PICKER_COLUMNS)
                    .map(|chunk| PickerRow::Custom(chunk.to_vec())),
            )
        });
        custom
            .into_iter()
            .flatten()
            .chain(CATEGORIES.iter().flat_map(|(group, label, _)| {
                let emoji: Vec<&'static str> = group
                    .emojis()
                    .filter(supported)
                    .map(emojis::Emoji::as_str)
                    .collect();
                std::iter::once(PickerRow::Heading(label)).chain(chunked(emoji))
            }))
            .collect()
    } else {
        let emoji = emojis::iter()
            .filter(supported)
            .filter(|emoji| {
                emoji.name().contains(&query)
                    || emoji.shortcodes().any(|code| code.contains(&query))
            })
            .map(emojis::Emoji::as_str)
            .collect();
        chunked(emoji)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picker_lists_every_category_and_searches_by_name() {
        let rows = picker_rows("", &[]);
        let headings = rows
            .iter()
            .filter(|row| matches!(row, PickerRow::Heading(_)))
            .count();
        assert_eq!(headings, CATEGORIES.len());
        assert!(rows.iter().all(|row| match row {
            PickerRow::Emoji(emoji) => !emoji.is_empty() && emoji.len() <= PICKER_COLUMNS,
            PickerRow::Heading(_) | PickerRow::Custom(_) => true,
        }));

        let found: Vec<&str> = picker_rows("rocket", &[])
            .iter()
            .flat_map(|row| match row {
                PickerRow::Emoji(emoji) => emoji.clone(),
                _ => Vec::new(),
            })
            .collect();
        assert!(found.contains(&"🚀"));
        assert!(picker_rows("no such emoji at all", &[]).is_empty());

        // Imported icons come first, under their own heading.
        let rows = picker_rows("", &["file:a.svg".into()]);
        assert!(matches!(rows[0], PickerRow::Heading(CUSTOM)));
        assert!(matches!(&rows[1], PickerRow::Custom(icons) if icons == &["file:a.svg"]));
    }
}
