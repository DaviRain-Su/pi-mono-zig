use std::fs;
use std::io;
use std::path::Path;
use std::process::Command;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BashOutput {
    pub stdout: String,
    pub stderr: String,
    pub status: i32,
}

pub fn read_file(path: impl AsRef<Path>) -> io::Result<String> {
    fs::read_to_string(path)
}

pub fn run_bash(command: &str) -> io::Result<BashOutput> {
    let output = if cfg!(windows) {
        Command::new("cmd").args(["/C", command]).output()?
    } else {
        Command::new("sh").args(["-c", command]).output()?
    };

    Ok(BashOutput {
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        status: output.status.code().unwrap_or(-1),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn read_file_returns_contents() {
        let mut path = std::env::temp_dir();
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        path.push(format!("pi-tools-{unique}.txt"));
        fs::write(&path, "hello").unwrap();

        let contents = read_file(&path).unwrap();
        fs::remove_file(&path).unwrap();

        assert_eq!(contents, "hello");
    }

    #[test]
    fn missing_file_returns_error() {
        let mut path = std::env::temp_dir();
        path.push("pi-tools-definitely-missing.txt");
        assert!(read_file(path).is_err());
    }

    #[test]
    fn run_bash_captures_stdout_and_status() {
        let output = run_bash("printf hello").unwrap();
        assert_eq!(output.stdout, "hello");
        assert_eq!(output.status, 0);
    }
}
