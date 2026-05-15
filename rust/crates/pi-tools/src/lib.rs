use serde::Deserialize;
use std::error::Error;
use std::fmt::{Display, Formatter};
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

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolDefinition {
    pub name: &'static str,
    pub label: &'static str,
    pub mutates: bool,
    pub parameters_json: &'static str,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolOutput {
    pub content: String,
}

#[derive(Debug)]
pub enum ToolError {
    UnknownTool(String),
    UnsupportedTool(String),
    InvalidArguments(serde_json::Error),
    Io(io::Error),
}

impl Display for ToolError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            ToolError::UnknownTool(name) => write!(f, "unknown tool: {name}"),
            ToolError::UnsupportedTool(name) => write!(f, "unsupported tool execution: {name}"),
            ToolError::InvalidArguments(error) => write!(f, "invalid tool arguments: {error}"),
            ToolError::Io(error) => write!(f, "tool IO error: {error}"),
        }
    }
}

impl Error for ToolError {}

impl From<io::Error> for ToolError {
    fn from(error: io::Error) -> Self {
        ToolError::Io(error)
    }
}

impl From<serde_json::Error> for ToolError {
    fn from(error: serde_json::Error) -> Self {
        ToolError::InvalidArguments(error)
    }
}

#[derive(Deserialize)]
struct ReadArgs {
    path: String,
}

#[derive(Deserialize)]
struct BashArgs {
    command: String,
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

pub fn builtin_tool_definitions() -> Vec<ToolDefinition> {
    pi_zig_codegen::generated_tools()
        .iter()
        .map(|tool| ToolDefinition {
            name: tool.name,
            label: tool.label,
            mutates: tool.mutates,
            parameters_json: tool.parameters_json,
        })
        .collect()
}

pub fn find_tool_definition(name: &str) -> Option<ToolDefinition> {
    builtin_tool_definitions()
        .into_iter()
        .find(|definition| definition.name == name)
}

pub fn execute_builtin_tool(name: &str, arguments_json: &str) -> Result<ToolOutput, ToolError> {
    if find_tool_definition(name).is_none() {
        return Err(ToolError::UnknownTool(name.to_string()));
    }

    match name {
        "read" => {
            let args: ReadArgs = serde_json::from_str(arguments_json)?;
            Ok(ToolOutput {
                content: read_file(args.path)?,
            })
        }
        "bash" => {
            let args: BashArgs = serde_json::from_str(arguments_json)?;
            let output = run_bash(&args.command)?;
            Ok(ToolOutput {
                content: format_bash_output(&output),
            })
        }
        _ => Err(ToolError::UnsupportedTool(name.to_string())),
    }
}

fn format_bash_output(output: &BashOutput) -> String {
    let mut formatted = format!("status: {}", output.status);
    if !output.stdout.is_empty() {
        formatted.push_str("\nstdout:\n");
        formatted.push_str(&output.stdout);
    }
    if !output.stderr.is_empty() {
        formatted.push_str("\nstderr:\n");
        formatted.push_str(&output.stderr);
    }
    formatted
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn read_file_returns_contents() {
        let path = write_temp_file("read", "hello");

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

    #[test]
    fn builtin_tool_definitions_include_zig_reflected_schema() {
        let edit = find_tool_definition("edit").unwrap();
        assert_eq!(edit.label, "Edit File");
        assert!(edit.parameters_json.contains("\"old_text\""));
    }

    #[test]
    fn execute_read_tool_uses_json_arguments() {
        let path = write_temp_file("execute-read", "tool body");
        let args = format!(r#"{{"path":"{}"}}"#, path.display());

        let output = execute_builtin_tool("read", &args).unwrap();
        fs::remove_file(path).unwrap();

        assert_eq!(output.content, "tool body");
    }

    #[test]
    fn execute_bash_tool_uses_json_arguments() {
        let output = execute_builtin_tool("bash", r#"{"command":"printf tool"}"#).unwrap();
        assert!(output.content.contains("status: 0"));
        assert!(output.content.contains("tool"));
    }

    #[test]
    fn execute_unknown_tool_returns_error() {
        let error = execute_builtin_tool("missing", "{}").unwrap_err();
        assert!(matches!(error, ToolError::UnknownTool(_)));
    }

    fn write_temp_file(label: &str, contents: &str) -> std::path::PathBuf {
        let mut path = std::env::temp_dir();
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        path.push(format!("pi-tools-{label}-{unique}.txt"));
        fs::write(&path, contents).unwrap();
        path
    }
}
