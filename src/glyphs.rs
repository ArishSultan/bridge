//! Box drawing, block elements and Powerline separators, drawn as shapes that fill the cell
//! exactly instead of as font glyphs — the way Ghostty, kitty and WezTerm draw them. Font glyphs
//! for these rarely match the grid: with a line height above 1.0 they leave gaps between rows,
//! and a font that lacks them falls back to one with other metrics, which breaks logos made of
//! blocks (Claude Code's) and box borders (most TUIs).

use gpui::{Bounds, Path, PathBuilder, Pixels, point, px, size};

/// Something to paint in the cell's foreground color.
pub enum Shape {
    /// A rectangle, with the foreground's opacity scaled by the given factor (shades use < 1).
    Rect(Bounds<Pixels>, f32),
    Path(Path<Pixels>),
}

/// Whether `ch` is drawn by [`draw`] rather than taken from the font.
pub fn is_drawn(ch: char) -> bool {
    matches!(ch, '\u{2500}'..='\u{257F}' | '\u{2580}'..='\u{259F}' | '\u{E0B0}'..='\u{E0B3}')
}

/// Shapes for `ch` in a cell at `bounds`, aligned to device pixels at `scale`.
pub fn draw(ch: char, bounds: Bounds<Pixels>, scale: f32) -> Vec<Shape> {
    let cell = Cell::new(bounds, scale);
    let mut out = Vec::new();
    match ch {
        '\u{2580}'..='\u{259F}' => cell.block(ch, &mut out),
        '\u{E0B0}'..='\u{E0B3}' => cell.powerline(ch, &mut out),
        '\u{2504}'..='\u{250B}' | '\u{254C}'..='\u{254F}' => cell.dashes(ch, &mut out),
        '\u{256D}'..='\u{2570}' => cell.arc(ch, &mut out),
        '\u{2571}'..='\u{2573}' => cell.diagonal(ch, &mut out),
        _ => {
            if let Some(arms) = arms(ch) {
                cell.lines(arms, &mut out);
            }
        }
    }
    out
}

/// Stroke weight of one arm of a box-drawing character.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Weight {
    None,
    Light,
    Heavy,
    Double,
}

/// Arms in the order up, right, down, left.
type Arms = [Weight; 4];

/// Lines, corners, tees and crosses (U+2500–U+254B), then the double-line set (U+2550–U+256C) and
/// half lines (U+2574–U+257F), each as `up right down left`: `-` none, `l` light, `h` heavy,
/// `d` double.
const LINES: [&str; 76] = [
    "-l-l", "-h-h", "l-l-", "h-h-", "", "", "", "", "", "", "",
    "", // ─━│┃ (dashes elsewhere)
    "-ll-", "-hl-", "-lh-", "-hh-", "--ll", "--lh", "--hl",
    "--hh", // ┌┍┎┏┐┑┒┓
    "ll--", "lh--", "hl--", "hh--", "l--l", "l--h", "h--l",
    "h--h", // └┕┖┗┘┙┚┛
    "lll-", "lhl-", "hll-", "llh-", "hlh-", "hhl-", "lhh-",
    "hhh-", // ├┝┞┟┠┡┢┣
    "l-ll", "l-lh", "h-ll", "l-hl", "h-hl", "h-lh", "l-hh",
    "h-hh", // ┤┥┦┧┨┩┪┫
    "-lll", "-llh", "-hll", "-hlh", "-lhl", "-lhh", "-hhl",
    "-hhh", // ┬┭┮┯┰┱┲┳
    "ll-l", "ll-h", "lh-l", "lh-h", "hl-l", "hl-h", "hh-l",
    "hh-h", // ┴┵┶┷┸┹┺┻
    "llll", "lllh", "lhll", "lhlh", "hlll", "llhl", "hlhl",
    "hllh", // ┼┽┾┿╀╁╂╃
    "hhll", "llhh", "lhhl", "hhlh", "lhhh", "hlhh", "hhhl",
    "hhhh", // ╄╅╆╇╈╉╊╋
];
const DOUBLE_LINES: [&str; 29] = [
    "-d-d", "d-d-", "-dl-", "-ld-", "-dd-", "--ld", "--dl",
    "--dd", // ═║╒╓╔╕╖╗
    "ld--", "dl--", "dd--", "l--d", "d--l", "d--d", "ldl-",
    "dld-", // ╘╙╚╛╜╝╞╟
    "ddd-", "l-ld", "d-dl", "d-dd", "-dld", "-ldl", "-ddd",
    "ld-d", // ╠╡╢╣╤╥╦╧
    "dl-l", "dd-d", "ldld", "dldl", "dddd", // ╨╩╪╫╬
];
const HALF_LINES: [&str; 12] = [
    "---l", "l---", "-l--", "--l-", "---h", "h---", "-h--",
    "--h-", // ╴╵╶╷╸╹╺╻
    "-h-l", "l-h-", "-l-h", "h-l-", // ╼╽╾╿
];

fn arms(ch: char) -> Option<Arms> {
    let code = ch as usize;
    let spec = match code {
        0x2500..=0x254B => LINES[code - 0x2500],
        0x2550..=0x256C => DOUBLE_LINES[code - 0x2550],
        0x2574..=0x257F => HALF_LINES[code - 0x2574],
        _ => return None,
    };
    let mut arms = [Weight::None; 4];
    for (arm, byte) in arms.iter_mut().zip(spec.bytes()) {
        *arm = match byte {
            b'l' => Weight::Light,
            b'h' => Weight::Heavy,
            b'd' => Weight::Double,
            _ => Weight::None,
        };
    }
    (spec.len() == 4).then_some(arms)
}

/// A cell in device pixels, so every edge lands on a pixel boundary.
struct Cell {
    scale: f32,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    cx: f32,
    cy: f32,
    light: f32,
    heavy: f32,
    /// Distance from the center to each line of a double line.
    gap: f32,
}

impl Cell {
    fn new(bounds: Bounds<Pixels>, scale: f32) -> Self {
        let device = |value: Pixels| (f32::from(value) * scale).round();
        let (x0, y0) = (device(bounds.origin.x), device(bounds.origin.y));
        let (x1, y1) = (
            device(bounds.origin.x + bounds.size.width),
            device(bounds.origin.y + bounds.size.height),
        );
        let light = ((x1 - x0) / 8.).round().max(1.);
        Self {
            scale,
            x0,
            y0,
            x1,
            y1,
            cx: ((x0 + x1) / 2.).floor(),
            cy: ((y0 + y1) / 2.).floor(),
            light,
            heavy: light * 2.,
            gap: light,
        }
    }

    fn logical(&self, x: f32, y: f32) -> gpui::Point<Pixels> {
        point(px(x / self.scale), px(y / self.scale))
    }

    /// Rectangle from device-pixel edges (rounded so neighbors meet without seams).
    fn rect(&self, out: &mut Vec<Shape>, (x0, y0, x1, y1): (f32, f32, f32, f32), alpha: f32) {
        let (x0, y0, x1, y1) = (x0.round(), y0.round(), x1.round(), y1.round());
        if x1 > x0 && y1 > y0 {
            let origin = self.logical(x0, y0);
            out.push(Shape::Rect(
                Bounds::new(
                    origin,
                    size(px((x1 - x0) / self.scale), px((y1 - y0) / self.scale)),
                ),
                alpha,
            ));
        }
    }

    /// Horizontal line of thickness `t` centered on `y`.
    fn hline(&self, out: &mut Vec<Shape>, x0: f32, x1: f32, y: f32, t: f32) {
        let top = y - (t / 2.).floor();
        self.rect(out, (x0, top, x1, top + t), 1.);
    }

    /// Vertical line of thickness `t` centered on `x`.
    fn vline(&self, out: &mut Vec<Shape>, y0: f32, y1: f32, x: f32, t: f32) {
        let left = x - (t / 2.).floor();
        self.rect(out, (left, y0, left + t, y1), 1.);
    }

    fn thickness(&self, weight: Weight) -> f32 {
        match weight {
            Weight::Heavy => self.heavy,
            _ => self.light,
        }
    }

    /// How far a crossing arm reaches from the center line.
    fn reach(&self, weight: Weight) -> f32 {
        match weight {
            Weight::None => 0.,
            Weight::Light | Weight::Heavy => self.thickness(weight) / 2.,
            Weight::Double => self.gap + self.light / 2.,
        }
    }

    /// Where one line of a double arm starts, measured from the center toward the arm's far end
    /// (negative: it reaches back past the center). `near` is the crossing arm on this line's
    /// side, `far` the one on the other side.
    fn double_start(&self, near: Weight, far: Weight) -> f32 {
        let half = self.light / 2.;
        match (near, far) {
            // Stop at the crossing double line on this side.
            (Weight::Double, _) => self.gap - half,
            // Meet a single crossing line.
            (Weight::Light | Weight::Heavy, _) | (Weight::None, Weight::Light | Weight::Heavy) => {
                -half
            }
            // Outer corner: reach the far double line's outer edge.
            (Weight::None, Weight::Double | Weight::None) => -(self.gap + half),
        }
    }

    fn lines(&self, [up, right, down, left]: Arms, out: &mut Vec<Shape>) {
        let (cx, cy, gap) = (self.cx, self.cy, self.gap);
        let horizontal_reach = self.reach(up).max(self.reach(down));
        let vertical_reach = self.reach(left).max(self.reach(right));
        let reach_or = |reach: f32, weight: Weight| {
            if reach > 0. {
                reach
            } else {
                self.thickness(weight) / 2.
            }
        };

        match right {
            Weight::None => {}
            Weight::Double => {
                self.hline(
                    out,
                    cx + self.double_start(up, down),
                    self.x1,
                    cy - gap,
                    self.light,
                );
                self.hline(
                    out,
                    cx + self.double_start(down, up),
                    self.x1,
                    cy + gap,
                    self.light,
                );
            }
            weight => self.hline(
                out,
                cx - reach_or(horizontal_reach, weight),
                self.x1,
                cy,
                self.thickness(weight),
            ),
        }
        match left {
            Weight::None => {}
            Weight::Double => {
                self.hline(
                    out,
                    self.x0,
                    cx - self.double_start(up, down),
                    cy - gap,
                    self.light,
                );
                self.hline(
                    out,
                    self.x0,
                    cx - self.double_start(down, up),
                    cy + gap,
                    self.light,
                );
            }
            weight => self.hline(
                out,
                self.x0,
                cx + reach_or(horizontal_reach, weight),
                cy,
                self.thickness(weight),
            ),
        }
        match down {
            Weight::None => {}
            Weight::Double => {
                self.vline(
                    out,
                    cy + self.double_start(left, right),
                    self.y1,
                    cx - gap,
                    self.light,
                );
                self.vline(
                    out,
                    cy + self.double_start(right, left),
                    self.y1,
                    cx + gap,
                    self.light,
                );
            }
            weight => self.vline(
                out,
                cy - reach_or(vertical_reach, weight),
                self.y1,
                cx,
                self.thickness(weight),
            ),
        }
        match up {
            Weight::None => {}
            Weight::Double => {
                self.vline(
                    out,
                    self.y0,
                    cy - self.double_start(left, right),
                    cx - gap,
                    self.light,
                );
                self.vline(
                    out,
                    self.y0,
                    cy - self.double_start(right, left),
                    cx + gap,
                    self.light,
                );
            }
            weight => self.vline(
                out,
                self.y0,
                cy + reach_or(vertical_reach, weight),
                cx,
                self.thickness(weight),
            ),
        }
    }

    /// ┄┅┆┇┈┉┊┋╌╍╎╏
    fn dashes(&self, ch: char, out: &mut Vec<Shape>) {
        let (count, heavy, vertical) = match ch {
            '┄' => (3, false, false),
            '┅' => (3, true, false),
            '┆' => (3, false, true),
            '┇' => (3, true, true),
            '┈' => (4, false, false),
            '┉' => (4, true, false),
            '┊' => (4, false, true),
            '┋' => (4, true, true),
            '╌' => (2, false, false),
            '╍' => (2, true, false),
            '╎' => (2, false, true),
            _ => (2, true, true),
        };
        let t = if heavy { self.heavy } else { self.light };
        let (start, end) = if vertical {
            (self.y0, self.y1)
        } else {
            (self.x0, self.x1)
        };
        let segment = (end - start) / count as f32;
        for index in 0..count {
            // Each dash is centered in its segment, so dashes continue across cells.
            let a = start + segment * index as f32 + segment * 0.2;
            let b = a + segment * 0.6;
            if vertical {
                self.vline(out, a, b, self.cx, t);
            } else {
                self.hline(out, a, b, self.cy, t);
            }
        }
    }

    /// ╭╮╯╰: a quarter circle between the two arms.
    fn arc(&self, ch: char, out: &mut Vec<Shape>) {
        let (cx, cy) = (self.cx, self.cy);
        let r = (self.x1 - self.x0).min(self.y1 - self.y0) / 2.;
        // (vertical end, horizontal end) directions: +1 down / right, -1 up / left.
        let (dy, dx) = match ch {
            '╭' => (1., 1.),
            '╮' => (1., -1.),
            '╯' => (-1., -1.),
            _ => (-1., 1.),
        };
        let edge_y = if dy > 0. { self.y1 } else { self.y0 };
        let edge_x = if dx > 0. { self.x1 } else { self.x0 };
        // Circle control-point distance for a cubic quarter arc.
        let k = 0.552_284_8 * r;
        let mut path = PathBuilder::stroke(px(self.light / self.scale));
        path.move_to(self.logical(cx, edge_y));
        path.line_to(self.logical(cx, cy + dy * r));
        path.cubic_bezier_to(
            self.logical(cx + dx * r, cy),
            self.logical(cx, cy + dy * (r - k)),
            self.logical(cx + dx * (r - k), cy),
        );
        path.line_to(self.logical(edge_x, cy));
        if let Ok(path) = path.build() {
            out.push(Shape::Path(path));
        }
    }

    /// ╱╲╳
    fn diagonal(&self, ch: char, out: &mut Vec<Shape>) {
        let mut segments = Vec::new();
        if ch != '╲' {
            segments.push(((self.x1, self.y0), (self.x0, self.y1)));
        }
        if ch != '╱' {
            segments.push(((self.x0, self.y0), (self.x1, self.y1)));
        }
        for ((ax, ay), (bx, by)) in segments {
            let mut path = PathBuilder::stroke(px(self.light / self.scale));
            path.move_to(self.logical(ax, ay));
            path.line_to(self.logical(bx, by));
            if let Ok(path) = path.build() {
                out.push(Shape::Path(path));
            }
        }
    }

    /// U+2580–U+259F: eighths, halves, shades and quadrants.
    fn block(&self, ch: char, out: &mut Vec<Shape>) {
        let (w, h) = (self.x1 - self.x0, self.y1 - self.y0);
        // Fractions of the cell: (left, top, right, bottom).
        let mut part = |l: f32, t: f32, r: f32, b: f32, alpha: f32| {
            self.rect(
                out,
                (
                    self.x0 + w * l,
                    self.y0 + h * t,
                    self.x0 + w * r,
                    self.y0 + h * b,
                ),
                alpha,
            );
        };
        let eighth = |n: u32| n as f32 / 8.;
        let code = ch as u32;
        match code {
            0x2580 => part(0., 0., 1., 0.5, 1.),
            // ▁▂▃▄▅▆▇█: lower n eighths.
            0x2581..=0x2588 => part(0., 1. - eighth(code - 0x2580), 1., 1., 1.),
            // ▉▊▋▌▍▎▏: left 7..1 eighths.
            0x2589..=0x258F => part(0., 0., eighth(0x2590 - code), 1., 1.),
            0x2590 => part(0.5, 0., 1., 1., 1.),
            0x2591 => part(0., 0., 1., 1., 0.25),
            0x2592 => part(0., 0., 1., 1., 0.5),
            0x2593 => part(0., 0., 1., 1., 0.75),
            0x2594 => part(0., 0., 1., eighth(1), 1.),
            0x2595 => part(eighth(7), 0., 1., 1., 1.),
            _ => {
                // Quadrants as bits: upper left, upper right, lower left, lower right.
                let quadrants: u8 = match code {
                    0x2596 => 0b0010,
                    0x2597 => 0b0001,
                    0x2598 => 0b1000,
                    0x2599 => 0b1011,
                    0x259A => 0b1001,
                    0x259B => 0b1110,
                    0x259C => 0b1101,
                    0x259D => 0b0100,
                    0x259E => 0b0110,
                    _ => 0b0111,
                };
                for (bit, (l, t)) in [
                    (0b1000, (0., 0.)),
                    (0b0100, (0.5, 0.)),
                    (0b0010, (0., 0.5)),
                    (0b0001, (0.5, 0.5)),
                ] {
                    if quadrants & bit != 0 {
                        part(l, t, l + 0.5, t + 0.5, 1.);
                    }
                }
            }
        }
    }

    /// Powerline separators: solid and thin triangles pointing right () or left ().
    fn powerline(&self, ch: char, out: &mut Vec<Shape>) {
        let (x0, x1, y0, y1, cy) = (self.x0, self.x1, self.y0, self.y1, (self.y0 + self.y1) / 2.);
        let (base, tip) = if matches!(ch, '\u{E0B0}' | '\u{E0B1}') {
            (x0, x1)
        } else {
            (x1, x0)
        };
        let points = [
            self.logical(base, y0),
            self.logical(tip, cy),
            self.logical(base, y1),
        ];
        let path = if matches!(ch, '\u{E0B0}' | '\u{E0B2}') {
            let mut path = PathBuilder::fill();
            path.add_polygon(&points, true);
            path.build()
        } else {
            let mut path = PathBuilder::stroke(px(self.light / self.scale));
            path.add_polygon(&points, false);
            path.build()
        };
        if let Ok(path) = path {
            out.push(Shape::Path(path));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cell() -> Bounds<Pixels> {
        Bounds::new(point(px(0.), px(0.)), size(px(8.), px(18.)))
    }

    fn rects(ch: char) -> Vec<Bounds<Pixels>> {
        draw(ch, cell(), 2.)
            .into_iter()
            .filter_map(|shape| match shape {
                Shape::Rect(bounds, _) => Some(bounds),
                Shape::Path(_) => None,
            })
            .collect()
    }

    #[test]
    fn tables_cover_every_line_character() {
        for ch in ('\u{2500}'..='\u{254B}')
            .chain('\u{2550}'..='\u{256C}')
            .chain('\u{2574}'..='\u{257F}')
        {
            if !('\u{2504}'..='\u{250B}').contains(&ch) {
                assert!(arms(ch).is_some(), "no arms for {ch}");
            }
        }
        assert_eq!(arms('┼'), Some([Weight::Light; 4]));
        assert_eq!(arms('╋'), Some([Weight::Heavy; 4]));
        assert_eq!(arms('╬'), Some([Weight::Double; 4]));
        assert_eq!(
            arms('┏'),
            Some([Weight::None, Weight::Heavy, Weight::Heavy, Weight::None])
        );
        assert_eq!(
            arms('╿'),
            Some([Weight::Heavy, Weight::None, Weight::Light, Weight::None])
        );
    }

    #[test]
    fn full_block_fills_the_cell_and_vertical_lines_span_it() {
        assert_eq!(rects('█'), vec![cell()]);
        // Two arms meeting in the middle, together spanning the cell with no gap between rows.
        let line = rects('│');
        let top = line
            .iter()
            .map(|arm| arm.origin.y)
            .fold(px(f32::MAX), |a, b| a.min(b));
        let bottom = line
            .iter()
            .map(|arm| arm.origin.y + arm.size.height)
            .fold(px(0.), |a, b| a.max(b));
        assert_eq!((top, bottom), (px(0.), px(18.)));
        assert!(line.iter().all(|arm| arm.origin.x == line[0].origin.x));
    }

    #[test]
    fn quadrants_and_halves() {
        // ▛ is three quadrants; ▐ the right half.
        assert_eq!(rects('▛').len(), 3);
        let right = rects('▐');
        assert_eq!((right[0].origin.x, right[0].size.width), (px(4.), px(4.)));
    }

    #[test]
    fn every_drawn_character_produces_shapes() {
        let all = ('\u{2500}'..='\u{257F}')
            .chain('\u{2580}'..='\u{259F}')
            .chain('\u{E0B0}'..='\u{E0B3}');
        for ch in all {
            assert!(is_drawn(ch));
            assert!(
                !draw(ch, cell(), 2.).is_empty(),
                "nothing drawn for {ch} (U+{:04X})",
                ch as u32
            );
        }
    }
}
