//! Projects and their terminals and views. A project is a folder; a view is a grid of terminals
//! in it (a split layout), each terminal described by a [`TerminalSpec`]: a shell, a task bound to one command,
//! or an SSH session; sandboxed to the project unless it is an open terminal. Persisted to
//! `~/.config/bridge/projects.json`.

use std::{
    fs, io,
    path::{Component, Path, PathBuf},
};

use serde::{Deserialize, Serialize};

use crate::settings::TerminalSettings;

pub type Id = u64;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SplitAxis {
    /// Side by side.
    Horizontal,
    /// Stacked.
    Vertical,
}

/// What a terminal runs.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum TerminalKind {
    /// The user's shell.
    #[default]
    Shell,
    /// One long-running command, started and stopped from the terminal's header.
    Task {
        command: String,
        /// Start it when its view opens.
        #[serde(default)]
        auto_start: bool,
        /// Start it again when it exits.
        #[serde(default)]
        restart_on_exit: bool,
    },
    /// An SSH session to a global host.
    Ssh { host: Id },
}

/// What a terminal can reach.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Isolation {
    /// In a sandbox profile (`None`: the built-in Project profile), writing only inside the project.
    Sandboxed {
        #[serde(default)]
        profile: Option<Id>,
    },
    /// Not sandboxed (marked as such in the UI).
    Open,
}

impl Default for Isolation {
    fn default() -> Self {
        Self::Sandboxed { profile: None }
    }
}

fn here() -> String {
    ".".to_owned()
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalSpec {
    /// Empty: named after what it shows.
    #[serde(default)]
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
    #[serde(default)]
    pub kind: TerminalKind,
    /// Where it starts, relative to the project folder.
    #[serde(default = "here")]
    pub folder: String,
    #[serde(default)]
    pub isolation: Isolation,
    /// Keeps running when its view is left.
    #[serde(default)]
    pub background: bool,
}

impl Default for TerminalSpec {
    fn default() -> Self {
        Self::shell(".", Isolation::default())
    }
}

impl TerminalSpec {
    pub fn shell(folder: impl Into<String>, isolation: Isolation) -> Self {
        Self {
            name: String::new(),
            tag: None,
            kind: TerminalKind::Shell,
            folder: folder.into(),
            isolation,
            background: false,
        }
    }

    /// SSH sessions need the user's keys and the network, so they are never sandboxed.
    pub fn effective_isolation(&self) -> Isolation {
        match self.kind {
            TerminalKind::Ssh { .. } => Isolation::Open,
            _ => self.isolation.clone(),
        }
    }

    /// What a terminal split off this one is: a shell in the same folder, as isolated.
    pub fn for_split(&self) -> Self {
        Self::shell(self.folder.clone(), self.effective_isolation())
    }
}

/// A side of a pane that another pane can be dropped on, to split it there.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Side {
    Left,
    Right,
    Top,
    Bottom,
}

impl Side {
    pub fn axis(self) -> SplitAxis {
        match self {
            Self::Left | Self::Right => SplitAxis::Horizontal,
            Self::Top | Self::Bottom => SplitAxis::Vertical,
        }
    }

    /// Whether the dropped pane goes first (left of or above the target).
    fn before(self) -> bool {
        matches!(self, Self::Left | Self::Top)
    }
}

/// A view's layout: a single terminal or a split of two layouts.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Layout {
    Pane {
        id: Id,
        terminal: TerminalSpec,
    },
    Split {
        id: Id,
        axis: SplitAxis,
        first: Box<Layout>,
        second: Box<Layout>,
    },
}

impl Layout {
    pub fn pane(id: Id, terminal: TerminalSpec) -> Self {
        Self::Pane { id, terminal }
    }

    /// Pane ids in reading order.
    pub fn panes(&self) -> Vec<Id> {
        let mut out = Vec::new();
        self.collect_panes(&mut out);
        out
    }

    fn collect_panes(&self, out: &mut Vec<Id>) {
        match self {
            Self::Pane { id, .. } => out.push(*id),
            Self::Split { first, second, .. } => {
                first.collect_panes(out);
                second.collect_panes(out);
            }
        }
    }

    /// Replace `pane` with a split of `pane` and `new_pane` (running `terminal`). Returns whether
    /// `pane` was found.
    pub fn split(
        &mut self,
        pane: Id,
        axis: SplitAxis,
        new_pane: Id,
        split_id: Id,
        terminal: TerminalSpec,
    ) -> bool {
        match self {
            Self::Pane { id, .. } if *id == pane => {
                let existing = std::mem::replace(self, Self::pane(0, TerminalSpec::default()));
                *self = Self::Split {
                    id: split_id,
                    axis,
                    first: Box::new(existing),
                    second: Box::new(Self::pane(new_pane, terminal)),
                };
                true
            }
            Self::Pane { .. } => false,
            Self::Split { first, second, .. } => {
                first.split(pane, axis, new_pane, split_id, terminal.clone())
                    || second.split(pane, axis, new_pane, split_id, terminal)
            }
        }
    }

    /// Move `pane` next to `target`, on its `side`: `target` is split there and `pane` leaves its
    /// old place. `split_id` names the new split.
    pub fn move_to(&mut self, pane: Id, target: Id, side: Side, split_id: Id) -> bool {
        if pane == target || self.terminal(target).is_none() {
            return false;
        }
        let Some(terminal) = self.terminal(pane).cloned() else {
            return false;
        };
        let Some(mut moved) = self.clone().remove(pane) else {
            return false;
        };
        if !moved.split(target, side.axis(), pane, split_id, terminal) {
            return false;
        }
        if side.before() {
            moved.flip(split_id);
        }
        *self = moved;
        true
    }

    /// Swap the two halves of the split `split_id`.
    fn flip(&mut self, split_id: Id) {
        if let Self::Split {
            id, first, second, ..
        } = self
        {
            if *id == split_id {
                std::mem::swap(first, second);
            } else {
                first.flip(split_id);
                second.flip(split_id);
            }
        }
    }

    /// Remove `pane`, collapsing its split. Returns `None` when the layout becomes empty.
    pub fn remove(self, pane: Id) -> Option<Self> {
        match self {
            Self::Pane { id, .. } if id == pane => None,
            Self::Pane { .. } => Some(self),
            Self::Split {
                id,
                axis,
                first,
                second,
            } => match (first.remove(pane), second.remove(pane)) {
                (Some(first), Some(second)) => Some(Self::Split {
                    id,
                    axis,
                    first: Box::new(first),
                    second: Box::new(second),
                }),
                (Some(only), None) | (None, Some(only)) => Some(only),
                (None, None) => None,
            },
        }
    }

    /// Exchange the places of two panes (each keeps its terminal). Returns whether both were found.
    pub fn swap(&mut self, a: Id, b: Id) -> bool {
        if a == b {
            return false;
        }
        let (Some(spec_a), Some(spec_b)) = (self.terminal(a).cloned(), self.terminal(b).cloned())
        else {
            return false;
        };
        self.for_each_pane_mut(&mut |id, terminal| {
            if *id == a {
                (*id, *terminal) = (b, spec_b.clone());
            } else if *id == b {
                (*id, *terminal) = (a, spec_a.clone());
            }
        });
        true
    }

    fn for_each_pane_mut(&mut self, f: &mut impl FnMut(&mut Id, &mut TerminalSpec)) {
        match self {
            Self::Pane { id, terminal } => f(id, terminal),
            Self::Split { first, second, .. } => {
                first.for_each_pane_mut(f);
                second.for_each_pane_mut(f);
            }
        }
    }

    pub fn terminal(&self, pane: Id) -> Option<&TerminalSpec> {
        match self {
            Self::Pane { id, terminal } if *id == pane => Some(terminal),
            Self::Pane { .. } => None,
            Self::Split { first, second, .. } => {
                first.terminal(pane).or_else(|| second.terminal(pane))
            }
        }
    }

    pub fn terminal_mut(&mut self, pane: Id) -> Option<&mut TerminalSpec> {
        match self {
            Self::Pane { id, terminal } if *id == pane => Some(terminal),
            Self::Pane { .. } => None,
            Self::Split { first, second, .. } => match first.terminal_mut(pane) {
                Some(terminal) => Some(terminal),
                None => second.terminal_mut(pane),
            },
        }
    }

    fn ids(&self, out: &mut Vec<Id>) {
        match self {
            Self::Pane { id, .. } => out.push(*id),
            Self::Split {
                id, first, second, ..
            } => {
                out.push(*id);
                first.ids(out);
                second.ids(out);
            }
        }
    }
}

/// An item of a project: one terminal, or a view of several in a grid. It always has at least
/// one terminal; deleting its only terminal deletes it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct View {
    pub id: Id,
    /// Its name as a view of several terminals (one terminal goes by its own name).
    #[serde(default)]
    pub name: String,
    /// `None` only in data saved by older versions, which loading drops.
    #[serde(default)]
    pub layout: Option<Layout>,
    #[serde(default)]
    pub focused: Option<Id>,
}

impl View {
    pub fn panes(&self) -> Vec<Id> {
        self.layout.as_ref().map(Layout::panes).unwrap_or_default()
    }

    pub fn terminal(&self, pane: Id) -> Option<&TerminalSpec> {
        self.layout.as_ref()?.terminal(pane)
    }

    /// The only terminal, when it has one: shown as that terminal rather than as a view.
    pub fn single(&self) -> Option<Id> {
        match &self.layout {
            Some(Layout::Pane { id, .. }) => Some(*id),
            _ => None,
        }
    }

    /// Add a terminal: split off `next_to` (or the focused one) along `axis`, or as the only one.
    pub fn add(
        &mut self,
        pane: Id,
        split_id: Id,
        axis: SplitAxis,
        next_to: Option<Id>,
        terminal: TerminalSpec,
    ) {
        let target = next_to.or(self.focused);
        let added = match (&mut self.layout, target) {
            (Some(layout), Some(target)) => {
                layout.split(target, axis, pane, split_id, terminal.clone())
            }
            _ => false,
        };
        if !added {
            match &mut self.layout {
                // No such pane: split the first one.
                Some(layout) => {
                    let first = layout.panes()[0];
                    layout.split(first, axis, pane, split_id, terminal);
                }
                None => self.layout = Some(Layout::pane(pane, terminal)),
            }
        }
        self.focused = Some(pane);
    }

    /// The terminals leaving this view stops: running ones not marked to keep running in the
    /// background.
    pub fn stopping_on_leave(&self, running: impl Fn(Id) -> bool) -> Vec<Id> {
        self.panes()
            .into_iter()
            .filter(|pane| {
                self.terminal(*pane).is_some_and(|spec| !spec.background) && running(*pane)
            })
            .collect()
    }

    /// Remove a terminal; focus moves to the first one left.
    pub fn remove(&mut self, pane: Id) {
        self.layout = self.layout.take().and_then(|layout| layout.remove(pane));
        if self.focused == Some(pane) || self.layout.is_none() {
            self.focused = self.layout.as_ref().map(|layout| layout.panes()[0]);
        }
    }
}

/// A project: a folder, and the terminals and views made in it. Each project opens in a window of
/// its own.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Project {
    pub id: Id,
    pub name: String,
    /// The project folder (`~` allowed).
    pub dir: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    /// Its terminals and views, in sidebar order.
    #[serde(default)]
    pub views: Vec<View>,
    /// The terminal or view on screen.
    #[serde(default)]
    pub active: Option<Id>,
}

impl Project {
    pub fn root(&self) -> PathBuf {
        expand_home(&self.dir)
    }

    /// Where a terminal of this project starts: its folder inside the project. A folder that would
    /// lead outside (`..`, an absolute path) falls back to the project folder.
    pub fn folder(&self, folder: &str) -> PathBuf {
        let relative = Path::new(folder.trim());
        let inside = relative
            .components()
            .all(|part| matches!(part, Component::Normal(_) | Component::CurDir));
        if inside {
            self.root().join(relative)
        } else {
            self.root()
        }
    }

    pub fn view(&self, id: Id) -> Option<&View> {
        self.views.iter().find(|view| view.id == id)
    }

    pub fn view_mut(&mut self, id: Id) -> Option<&mut View> {
        self.views.iter_mut().find(|view| view.id == id)
    }

    pub fn active_view(&self) -> Option<&View> {
        self.active.and_then(|id| self.view(id))
    }

    pub fn view_of_pane(&self, pane: Id) -> Option<Id> {
        self.views
            .iter()
            .find(|view| view.panes().contains(&pane))
            .map(|view| view.id)
    }

    pub fn terminal(&self, pane: Id) -> Option<&TerminalSpec> {
        self.views.iter().find_map(|view| view.terminal(pane))
    }

    pub fn terminal_mut(&mut self, pane: Id) -> Option<&mut TerminalSpec> {
        self.views
            .iter_mut()
            .find_map(|view| view.layout.as_mut()?.terminal_mut(pane))
    }

    /// Every terminal of the project.
    pub fn panes(&self) -> Vec<Id> {
        self.views.iter().flat_map(View::panes).collect()
    }

    /// Add an item `view` holding one terminal, `pane`.
    pub fn add_view(&mut self, view: Id, pane: Id, terminal: TerminalSpec) {
        self.views.push(View {
            id: view,
            name: String::new(),
            layout: Some(Layout::pane(pane, terminal)),
            focused: Some(pane),
        });
    }

    /// Remove an item; the one on screen moves to a neighbor. Returns it.
    pub fn remove_view(&mut self, id: Id) -> Option<View> {
        let index = self.views.iter().position(|view| view.id == id)?;
        let removed = self.views.remove(index);
        if self.active == Some(id) {
            self.active = self
                .views
                .get(index.min(self.views.len().saturating_sub(1)))
                .map(|view| view.id);
        }
        Some(removed)
    }

    /// The item `offset` positions away from the one on screen (wrapping).
    pub fn cycle_view(&self, offset: isize) -> Option<Id> {
        let order: Vec<Id> = self.views.iter().map(|view| view.id).collect();
        let current = order
            .iter()
            .position(|id| Some(*id) == self.active)
            .unwrap_or(0) as isize;
        let len = order.len() as isize;
        (len > 0).then(|| order[(current + offset).rem_euclid(len) as usize])
    }

    fn ids(&self, ids: &mut Vec<Id>) {
        ids.push(self.id);
        for view in &self.views {
            ids.push(view.id);
            if let Some(layout) = &view.layout {
                layout.ids(ids);
            }
        }
    }
}

fn default_true() -> bool {
    true
}

/// Every project, and which windows were open: a gpui global shared by the app's windows. A
/// project's window keeps its own copy of the project and puts it back here to save.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Projects {
    #[serde(default)]
    pub projects: Vec<Project>,
    /// The Global window's terminals: a project of their own, in the home folder.
    #[serde(default)]
    global: Option<Project>,
    /// Projects whose windows were open when the app last quit, to open again.
    #[serde(default)]
    pub open: Vec<Id>,
    /// Whether the Global window was open when the app last quit.
    #[serde(default)]
    pub global_open: bool,
    #[serde(default = "default_true")]
    pub sidebar_open: bool,
    #[serde(default)]
    next_id: Id,
}

impl gpui::Global for Projects {}

impl Default for Projects {
    fn default() -> Self {
        Self {
            projects: Vec::new(),
            global: None,
            open: Vec::new(),
            global_open: false,
            sidebar_open: true,
            next_id: 1,
        }
    }
}

impl Projects {
    pub fn load() -> Self {
        let mut data = fs::read_to_string(Self::path())
            .ok()
            .and_then(|json| serde_json::from_str::<Self>(&json).ok())
            .unwrap_or_default();
        for project in data.projects.iter_mut().chain(&mut data.global) {
            project.views.retain(|view| view.layout.is_some());
        }
        // Never hand out an id that is already in use.
        let max = data.all_ids().into_iter().max().unwrap_or(0);
        data.next_id = data.next_id.max(max + 1);
        data.global_id();
        data
    }

    /// The Global window's project, made the first time it is needed.
    pub fn global_id(&mut self) -> Id {
        if let Some(global) = &self.global {
            return global.id;
        }
        let id = self.next_id();
        self.global = Some(Project {
            id,
            name: "Global".into(),
            dir: "~".into(),
            icon: None,
            color: None,
            views: Vec::new(),
            active: None,
        });
        id
    }

    pub fn is_global(&self, project: Id) -> bool {
        self.global
            .as_ref()
            .is_some_and(|global| global.id == project)
    }

    pub fn save(&self) -> io::Result<()> {
        let path = Self::path();
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        fs::write(
            path,
            serde_json::to_string_pretty(self).map_err(io::Error::other)?,
        )
    }

    fn path() -> PathBuf {
        TerminalSettings::path().parent().map_or_else(
            || PathBuf::from("projects.json"),
            |dir| dir.join("projects.json"),
        )
    }

    fn all_ids(&self) -> Vec<Id> {
        let mut ids = Vec::new();
        for project in self.projects.iter().chain(&self.global) {
            project.ids(&mut ids);
        }
        ids
    }

    pub fn next_id(&mut self) -> Id {
        let id = self.next_id.max(1);
        self.next_id = id + 1;
        id
    }

    /// Add a project, with nothing in it yet; returns it.
    pub fn add_project(&mut self, name: String, dir: String) -> Id {
        let id = self.next_id();
        self.projects.push(Project {
            id,
            name,
            dir,
            icon: None,
            color: None,
            views: Vec::new(),
            active: None,
        });
        id
    }

    /// A project, or the Global window's.
    pub fn project(&self, id: Id) -> Option<&Project> {
        self.projects
            .iter()
            .chain(&self.global)
            .find(|project| project.id == id)
    }

    /// The project of a folder, if it was added before.
    pub fn find_dir(&self, dir: &Path) -> Option<Id> {
        self.projects
            .iter()
            .find(|project| project.root() == dir)
            .map(|project| project.id)
    }

    /// Store a project's new state (a project window saving its copy).
    pub fn put(&mut self, project: Project) {
        if self.is_global(project.id) {
            self.global = Some(project);
            return;
        }
        match self
            .projects
            .iter_mut()
            .find(|existing| existing.id == project.id)
        {
            Some(existing) => *existing = project,
            None => self.projects.push(project),
        }
    }

    /// Remove a project from the app (its folder is untouched). Returns it.
    pub fn remove_project(&mut self, id: Id) -> Option<Project> {
        let index = self.projects.iter().position(|project| project.id == id)?;
        self.open.retain(|open| *open != id);
        Some(self.projects.remove(index))
    }
}

/// Expand a leading `~` to the home directory.
pub fn expand_home(path: &str) -> PathBuf {
    match (path.strip_prefix('~'), std::env::var_os("HOME")) {
        (Some(rest), Some(home)) => PathBuf::from(home).join(rest.trim_start_matches('/')),
        _ => PathBuf::from(path),
    }
}

/// Show the home directory as `~`.
pub fn tilde(path: &str) -> String {
    match std::env::var("HOME") {
        Ok(home) if !home.is_empty() && path.starts_with(&home) => {
            format!("~{}", &path[home.len()..])
        }
        _ => path.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shell(folder: &str) -> TerminalSpec {
        TerminalSpec::shell(folder, Isolation::default())
    }

    #[test]
    fn splits_and_collapses_layouts() {
        let mut layout = Layout::pane(1, shell("."));
        assert!(layout.split(1, SplitAxis::Horizontal, 2, 10, shell(".")));
        assert!(layout.split(2, SplitAxis::Vertical, 3, 11, shell(".")));
        assert_eq!(layout.panes(), vec![1, 2, 3]);
        assert!(!layout.split(9, SplitAxis::Vertical, 4, 12, shell(".")));

        let layout = layout.remove(2).unwrap();
        assert_eq!(layout.panes(), vec![1, 3]);
        let layout = layout.remove(1).unwrap();
        assert_eq!(layout, Layout::pane(3, shell(".")));
        assert!(layout.remove(3).is_none());
    }

    #[test]
    fn swapping_moves_terminals_with_their_panes() {
        let task = TerminalSpec {
            name: "api".into(),
            kind: TerminalKind::Task {
                command: "nx serve api".into(),
                auto_start: false,
                restart_on_exit: false,
            },
            ..shell("apps/api")
        };
        let mut layout = Layout::pane(1, task.clone());
        layout.split(1, SplitAxis::Horizontal, 2, 10, shell("."));
        layout.split(2, SplitAxis::Vertical, 3, 11, shell("apps/portal"));
        assert!(layout.swap(1, 3));
        assert_eq!(layout.panes(), vec![3, 2, 1]);
        assert_eq!(layout.terminal(1), Some(&task));
        assert_eq!(layout.terminal(3).unwrap().folder, "apps/portal");
        assert!(!layout.swap(1, 1));
        assert!(!layout.swap(1, 9));
    }

    #[test]
    fn dropping_on_a_side_moves_a_pane_there() {
        // 1 | 2, then 1 dropped below 2: 2 over 1.
        let mut layout = Layout::pane(1, shell("a"));
        layout.split(1, SplitAxis::Horizontal, 2, 10, shell("b"));
        assert!(layout.move_to(1, 2, Side::Bottom, 11));
        let Layout::Split {
            id,
            axis,
            first,
            second,
        } = &layout
        else {
            panic!("{layout:?}")
        };
        assert_eq!((*id, *axis), (11, SplitAxis::Vertical));
        assert_eq!((first.panes(), second.panes()), (vec![2], vec![1]));
        assert_eq!(
            layout.terminal(1).unwrap().folder,
            "a",
            "the terminal moves with its pane"
        );

        // 1 | (2 / 3), then 3 dropped left of 1: 3 | 1 | 2.
        let mut layout = Layout::pane(1, shell("."));
        layout.split(1, SplitAxis::Horizontal, 2, 10, shell("."));
        layout.split(2, SplitAxis::Vertical, 3, 11, shell("."));
        assert!(layout.move_to(3, 1, Side::Left, 12));
        assert_eq!(layout.panes(), vec![3, 1, 2]);
        let Layout::Split { first, .. } = &layout else {
            panic!()
        };
        assert!(matches!(
            first.as_ref(),
            Layout::Split {
                id: 12,
                axis: SplitAxis::Horizontal,
                ..
            }
        ));

        // Onto itself, or with a pane that is not there: nothing moves.
        let before = layout.clone();
        assert!(!layout.move_to(1, 1, Side::Top, 13));
        assert!(!layout.move_to(9, 1, Side::Top, 13));
        assert!(!layout.move_to(1, 9, Side::Top, 13));
        assert_eq!(layout, before);
    }

    #[test]
    fn splits_are_shells_in_the_same_folder_and_isolation() {
        let open_task = TerminalSpec {
            name: "logs".into(),
            tag: Some("ops".into()),
            kind: TerminalKind::Task {
                command: "tail -f log".into(),
                auto_start: true,
                restart_on_exit: true,
            },
            folder: "apps/api".into(),
            isolation: Isolation::Open,
            background: true,
        };
        assert_eq!(
            open_task.for_split(),
            TerminalSpec::shell("apps/api", Isolation::Open)
        );
        // SSH sessions are never sandboxed, and neither is a shell split off one.
        let ssh = TerminalSpec {
            kind: TerminalKind::Ssh { host: 4 },
            ..shell(".")
        };
        assert_eq!(ssh.effective_isolation(), Isolation::Open);
        assert_eq!(ssh.for_split().isolation, Isolation::Open);
    }

    #[test]
    fn folders_stay_inside_the_project() {
        let project = Project {
            id: 1,
            name: "app".into(),
            dir: "/work/app".into(),
            icon: None,
            color: None,
            active: None,
            views: Vec::new(),
        };
        assert_eq!(project.folder("."), PathBuf::from("/work/app/."));
        assert_eq!(
            project.folder("apps/api"),
            PathBuf::from("/work/app/apps/api")
        );
        assert_eq!(project.folder("../other"), PathBuf::from("/work/app"));
        assert_eq!(project.folder("/etc"), PathBuf::from("/work/app"));
    }

    #[test]
    fn manages_projects_and_their_items() {
        let mut data = Projects::default();
        let rooster = data.add_project("rooster".into(), "/work/rooster".into());
        assert_eq!(data.find_dir(Path::new("/work/rooster")), Some(rooster));
        // No terminal is made for you: a project starts empty.
        let mut project = data.project(rooster).unwrap().clone();
        assert!(project.views.is_empty());
        project.add_view(2, 50, shell("."));
        assert_eq!(project.view(2).unwrap().single(), Some(50));
        project.add_view(3, 60, shell("."));
        // A second terminal makes it a view.
        project
            .view_mut(3)
            .unwrap()
            .add(61, 62, SplitAxis::Horizontal, None, shell("."));
        assert_eq!(project.view(3).unwrap().single(), None);
        project.active = Some(3);
        assert_eq!(project.view_of_pane(61), Some(3));
        assert_eq!(project.panes(), vec![50, 60, 61]);
        assert_eq!(project.cycle_view(1), Some(2));
        assert_eq!(project.cycle_view(-1), Some(2));

        project.remove_view(3);
        assert_eq!(
            project.active,
            Some(2),
            "the item on screen moves to a neighbor"
        );
        project.remove_view(2);
        assert_eq!(project.active, None);

        // Saving puts the window's copy back.
        project.name = "Rooster".into();
        data.put(project);
        assert_eq!(data.project(rooster).unwrap().name, "Rooster");
        data.open = vec![rooster];
        data.remove_project(rooster);
        assert!(data.projects.is_empty() && data.open.is_empty());

        // The Global window's project is kept apart from the others.
        let global = data.global_id();
        assert_eq!(data.global_id(), global, "made once");
        assert!(data.is_global(global) && data.projects.is_empty());
        let mut project = data.project(global).unwrap().clone();
        project.add_view(70, 71, shell("."));
        data.put(project);
        assert_eq!(data.project(global).unwrap().views.len(), 1);
        assert!(data.projects.is_empty() && data.find_dir(&expand_home("~")).is_none());
    }

    #[test]
    fn views_add_and_close_terminals_down_to_none() {
        let mut view = View {
            id: 1,
            name: "Dev".into(),
            layout: None,
            focused: None,
        };
        view.add(2, 3, SplitAxis::Horizontal, None, shell("."));
        view.add(4, 5, SplitAxis::Vertical, None, shell("apps/api"));
        assert_eq!(view.panes(), vec![2, 4]);
        assert_eq!(view.focused, Some(4));
        // Next to a pane that is gone: still added.
        view.add(6, 7, SplitAxis::Horizontal, Some(99), shell("."));
        assert_eq!(view.panes().len(), 3);
        view.remove(6);
        assert_eq!(view.focused, Some(2));
        view.remove(2);
        view.remove(4);
        assert_eq!((view.layout.clone(), view.focused), (None, None));
    }

    #[test]
    fn leaving_a_view_stops_only_unmarked_running_terminals() {
        let mut view = View {
            id: 1,
            name: "Dev".into(),
            layout: None,
            focused: None,
        };
        let background = TerminalSpec {
            background: true,
            ..shell(".")
        };
        view.add(2, 10, SplitAxis::Horizontal, None, background); // running, background
        view.add(3, 11, SplitAxis::Horizontal, None, shell(".")); // running
        view.add(4, 12, SplitAxis::Horizontal, None, shell(".")); // stopped
        assert_eq!(view.stopping_on_leave(|pane| pane != 4), vec![3]);
    }

    #[test]
    fn round_trips_through_json_and_keeps_ids_unique() {
        let mut data = Projects::default();
        let id = data.add_project("p".into(), "/tmp".into());
        let mut project = data.project(id).unwrap().clone();
        let view = 97;
        project.add_view(view, 98, shell("."));
        project
            .view_mut(view)
            .unwrap()
            .add(99, 100, SplitAxis::Vertical, Some(98), shell("."));
        project.active = Some(view);
        data.put(project);
        let json = serde_json::to_string(&data).unwrap();
        let mut restored: Projects = serde_json::from_str(&json).unwrap();
        assert_eq!(restored, data);
        restored.next_id = 0;
        let max = restored.all_ids().into_iter().max().unwrap();
        restored.next_id = restored.next_id.max(max + 1);
        assert!(restored.next_id() > 100);
        // A hand-written terminal fills in its defaults: a sandboxed shell in the project folder.
        let spec: TerminalSpec = serde_json::from_str("{}").unwrap();
        assert_eq!(
            spec,
            TerminalSpec::shell(".", Isolation::Sandboxed { profile: None })
        );
    }
}
