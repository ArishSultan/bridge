//! Small fzf-style fuzzy matcher: the query must appear in order (case-insensitively); matches at
//! the start, after separators and in consecutive runs score higher.

/// A successful match: higher scores are better; `positions` are matched char indices.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Match {
    pub score: i64,
    pub positions: Vec<usize>,
}

pub fn fuzzy_match(query: &str, candidate: &str) -> Option<Match> {
    if query.is_empty() {
        return Some(Match {
            score: 0,
            positions: Vec::new(),
        });
    }
    let query: Vec<char> = query.chars().flat_map(char::to_lowercase).collect();
    let chars: Vec<char> = candidate.chars().collect();
    let mut positions = Vec::with_capacity(query.len());
    let mut score = 0i64;
    let mut next = 0;
    let mut previous: Option<usize> = None;

    for &wanted in &query {
        let found = (next..chars.len())
            .find(|&index| chars[index].to_lowercase().eq(std::iter::once(wanted)))?;
        let boundary =
            found == 0 || matches!(chars[found - 1], ' ' | '/' | '-' | '_' | '.' | ':' | '=');
        score += 10;
        if boundary {
            score += 20;
        }
        match previous {
            Some(previous) if previous + 1 == found => score += 15,
            Some(previous) => score -= (found - previous - 1).min(10) as i64,
            None => score -= found.min(15) as i64,
        }
        positions.push(found);
        previous = Some(found);
        next = found + 1;
    }
    // Prefer exact-case prefixes and shorter candidates.
    if candidate.starts_with(&query.iter().collect::<String>()) {
        score += 25;
    }
    score -= (chars.len() as i64 / 8).min(10);
    Some(Match { score, positions })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_subsequences_in_order() {
        assert!(fuzzy_match("chk", "checkout").is_some());
        assert!(fuzzy_match("kch", "checkout").is_none());
        assert_eq!(fuzzy_match("co", "commit").unwrap().positions, vec![0, 1]);
        assert!(fuzzy_match("", "anything").is_some());
    }

    #[test]
    fn prefers_prefixes_and_word_starts() {
        let prefix = fuzzy_match("st", "status").unwrap().score;
        let middle = fuzzy_match("st", "rest").unwrap().score;
        assert!(prefix > middle);
        let boundary = fuzzy_match("gs", "git status").unwrap().score;
        let scattered = fuzzy_match("gs", "bigsur").unwrap().score;
        assert!(boundary > scattered);
    }

    #[test]
    fn is_case_insensitive() {
        assert!(fuzzy_match("doc", "Documents").is_some());
    }
}
