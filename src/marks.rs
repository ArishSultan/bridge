//! Private shell-integration markers.
//!
//! The integration scripts print `ESC ] 7700 ; KIND [; payload] BEL`:
//!
//! - `P;<exit status>;<cwd>` at the end of every prompt,
//! - `C;<command line>` when a command starts,
//! - `E;<PATH>` whenever the shell's `PATH` changes.
//!
//! Markers are removed from the output stream before it reaches the VT, so they never have side
//! effects, and they tell the view where the prompt ends, which command ran and where.

/// Something the shell reported through a marker.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ShellMark {
    /// The prompt has been fully drawn; the shell is waiting for input.
    Prompt {
        /// Exit status of the previous command.
        status: Option<i32>,
        cwd: Option<String>,
    },
    /// A command line was accepted and is about to run.
    Command(String),
    /// The shell's `PATH`.
    Path(String),
}

/// Output and markers in stream order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Segment {
    Output(Vec<u8>),
    Mark(ShellMark),
}

const PREFIX: &[u8] = b"\x1b]7700;";
/// Markers longer than this are treated as ordinary output.
const MAX_MARK_LEN: usize = 64 * 1024;

/// Strips markers from PTY output, also when one is split across reads.
#[derive(Debug, Default)]
pub struct MarkScanner {
    /// Bytes of a possibly incomplete marker held back from the previous chunk.
    pending: Vec<u8>,
}

impl MarkScanner {
    /// Split `chunk` into output and markers, in order.
    pub fn feed(&mut self, chunk: &[u8]) -> Vec<Segment> {
        let mut data = std::mem::take(&mut self.pending);
        data.extend_from_slice(chunk);

        let mut segments = Vec::new();
        let mut copied = 0;
        let mut search = 0;
        while let Some(offset) = data[search..].iter().position(|&byte| byte == 0x1b) {
            let at = search + offset;
            let rest = &data[at..];
            if rest.len() < PREFIX.len() {
                if PREFIX.starts_with(rest) {
                    push_output(&mut segments, &data[copied..at]);
                    self.pending = rest.to_vec();
                    return segments;
                }
            } else if rest.starts_with(PREFIX) {
                let body = &rest[PREFIX.len()..];
                match body.iter().position(|&byte| byte == 0x07) {
                    Some(end) => {
                        if let Some(mark) = parse(&body[..end]) {
                            push_output(&mut segments, &data[copied..at]);
                            segments.push(Segment::Mark(mark));
                            copied = at + PREFIX.len() + end + 1;
                            search = copied;
                            continue;
                        }
                    }
                    None if rest.len() < MAX_MARK_LEN => {
                        // The marker continues in the next read.
                        push_output(&mut segments, &data[copied..at]);
                        self.pending = rest.to_vec();
                        return segments;
                    }
                    None => {}
                }
            }
            search = at + 1;
        }
        push_output(&mut segments, &data[copied..]);
        segments
    }
}

fn push_output(segments: &mut Vec<Segment>, bytes: &[u8]) {
    if !bytes.is_empty() {
        segments.push(Segment::Output(bytes.to_vec()));
    }
}

fn parse(body: &[u8]) -> Option<ShellMark> {
    let text = String::from_utf8_lossy(body);
    let (kind, payload) = text.split_once(';').unwrap_or((&text, ""));
    let non_empty = |value: &str| (!value.is_empty()).then(|| value.to_owned());
    Some(match kind {
        "P" => {
            let (status, cwd) = payload.split_once(';').unwrap_or((payload, ""));
            ShellMark::Prompt {
                status: status.trim().parse().ok(),
                cwd: non_empty(cwd),
            }
        }
        "C" => ShellMark::Command(payload.to_owned()),
        "E" => ShellMark::Path(payload.to_owned()),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn output(bytes: &[u8]) -> Segment {
        Segment::Output(bytes.to_vec())
    }

    #[test]
    fn strips_markers_and_keeps_order() {
        let mut scanner = MarkScanner::default();
        let segments = scanner.feed(b"a\x1b]7700;C;ls -la\x07b\x1b[31mc\x1b]7700;P;1;/tmp/x y\x07");
        assert_eq!(
            segments,
            vec![
                output(b"a"),
                Segment::Mark(ShellMark::Command("ls -la".into())),
                output(b"b\x1b[31mc"),
                Segment::Mark(ShellMark::Prompt {
                    status: Some(1),
                    cwd: Some("/tmp/x y".into())
                }),
            ]
        );
    }

    #[test]
    fn handles_markers_split_across_reads() {
        let mut scanner = MarkScanner::default();
        assert_eq!(scanner.feed(b"text\x1b]77"), vec![output(b"text")]);
        assert_eq!(scanner.feed(b"00;E;/bin:/usr"), vec![]);
        assert_eq!(
            scanner.feed(b"/bin\x07$ "),
            vec![
                Segment::Mark(ShellMark::Path("/bin:/usr/bin".into())),
                output(b"$ ")
            ]
        );
    }

    #[test]
    fn leaves_other_sequences_alone() {
        let mut scanner = MarkScanner::default();
        let input = b"\x1b]0;title\x07\x1b]7700;X\x07\x1b[H";
        assert_eq!(scanner.feed(input), vec![output(input)]);
        // A trailing escape that cannot start a marker is passed through immediately.
        assert_eq!(scanner.feed(b"x\x1b["), vec![output(b"x\x1b[")]);
    }
}
