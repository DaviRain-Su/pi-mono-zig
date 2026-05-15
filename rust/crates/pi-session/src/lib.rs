use pi_ai::Message;
use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionEntry {
    pub sequence: u64,
    pub timestamp_ms: u128,
    pub message: Message,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionFile {
    path: PathBuf,
    next_sequence: u64,
}

impl SessionFile {
    pub fn open(path: impl Into<PathBuf>) -> io::Result<Self> {
        let path = path.into();
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }

        let next_sequence = if path.exists() {
            load_entries(&path)?
                .last()
                .map(|entry| entry.sequence + 1)
                .unwrap_or(0)
        } else {
            0
        };

        Ok(Self {
            path,
            next_sequence,
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn load_messages(&self) -> io::Result<Vec<Message>> {
        Ok(load_entries(&self.path)?
            .into_iter()
            .map(|entry| entry.message)
            .collect())
    }

    pub fn append_message(&mut self, message: Message) -> io::Result<SessionEntry> {
        let entry = SessionEntry {
            sequence: self.next_sequence,
            timestamp_ms: unix_timestamp_ms(),
            message,
        };
        self.next_sequence += 1;

        let encoded = serde_json::to_string(&entry).map_err(invalid_data)?;
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        writeln!(file, "{encoded}")?;

        Ok(entry)
    }

    pub fn append_messages(&mut self, messages: &[Message]) -> io::Result<Vec<SessionEntry>> {
        let mut entries = Vec::with_capacity(messages.len());
        for message in messages {
            entries.push(self.append_message(message.clone())?);
        }
        Ok(entries)
    }
}

pub fn load_entries(path: impl AsRef<Path>) -> io::Result<Vec<SessionEntry>> {
    let path = path.as_ref();
    if !path.exists() {
        return Ok(Vec::new());
    }

    let file = fs::File::open(path)?;
    let reader = BufReader::new(file);
    let mut entries = Vec::new();
    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let entry = serde_json::from_str(&line).map_err(invalid_data)?;
        entries.push(entry);
    }
    Ok(entries)
}

fn unix_timestamp_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or(0)
}

fn invalid_data(error: serde_json::Error) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error)
}

#[cfg(test)]
mod tests {
    use super::*;
    use pi_ai::{Message, Role};

    fn temp_session_path(name: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        let unique = unix_timestamp_ms();
        path.push(format!("pi-session-{name}-{unique}.jsonl"));
        path
    }

    #[test]
    fn append_and_load_messages_round_trip() {
        let path = temp_session_path("round-trip");
        let mut session = SessionFile::open(&path).unwrap();
        session.append_message(Message::user("hello")).unwrap();
        session.append_message(Message::assistant("hi")).unwrap();

        let messages = session.load_messages().unwrap();
        fs::remove_file(path).unwrap();

        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].role, Role::User);
        assert_eq!(messages[1].content, "hi");
    }

    #[test]
    fn reopening_continues_sequence() {
        let path = temp_session_path("sequence");
        let mut session = SessionFile::open(&path).unwrap();
        session.append_message(Message::user("one")).unwrap();

        let mut reopened = SessionFile::open(&path).unwrap();
        let entry = reopened.append_message(Message::assistant("two")).unwrap();
        fs::remove_file(path).unwrap();

        assert_eq!(entry.sequence, 1);
    }

    #[test]
    fn missing_file_loads_empty() {
        let path = temp_session_path("missing");
        let entries = load_entries(path).unwrap();
        assert!(entries.is_empty());
    }
}
