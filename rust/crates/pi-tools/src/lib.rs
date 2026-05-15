use pi_zig_codegen::GeneratedToolArgs;
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
    ReplaceNotFound(String),
    ReplaceNotUnique(String),
    InvalidArguments(serde_json::Error),
    Io(io::Error),
}

impl Display for ToolError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            ToolError::UnknownTool(name) => write!(f, "unknown tool: {name}"),
            ToolError::UnsupportedTool(name) => write!(f, "unsupported tool execution: {name}"),
            ToolError::ReplaceNotFound(text) => write!(f, "replacement text not found: {text}"),
            ToolError::ReplaceNotUnique(text) => {
                write!(f, "replacement text is not unique: {text}")
            }
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

pub fn read_file(path: impl AsRef<Path>) -> io::Result<String> {
    fs::read_to_string(path)
}

pub fn write_file(path: impl AsRef<Path>, content: &str) -> io::Result<()> {
    let path = path.as_ref();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, content)
}

pub fn edit_file(path: impl AsRef<Path>, edits: &[(String, String)]) -> Result<String, ToolError> {
    let path = path.as_ref();
    let mut content = fs::read_to_string(path)?;
    for (old_text, new_text) in edits {
        let matches: Vec<_> = content.match_indices(old_text).collect();
        match matches.len() {
            0 => return Err(ToolError::ReplaceNotFound(old_text.clone())),
            1 => content = content.replacen(old_text, new_text, 1),
            _ => return Err(ToolError::ReplaceNotUnique(old_text.clone())),
        }
    }
    fs::write(path, &content)?;
    Ok(content)
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

    match pi_zig_codegen::parse_generated_tool_args(name, arguments_json)? {
        Some(GeneratedToolArgs::Read(args)) => Ok(ToolOutput {
            content: read_file(args.path)?,
        }),
        Some(GeneratedToolArgs::Bash(args)) => {
            let output = run_bash(&args.command)?;
            Ok(ToolOutput {
                content: format_bash_output(&output),
            })
        }
        Some(GeneratedToolArgs::Write(args)) => {
            write_file(&args.path, &args.content)?;
            Ok(ToolOutput {
                content: format!("wrote {} bytes to {}", args.content.len(), args.path),
            })
        }
        Some(GeneratedToolArgs::Edit(args)) => {
            let edits = args
                .edits
                .into_iter()
                .map(|edit| (edit.old_text, edit.new_text))
                .collect::<Vec<_>>();
            let content = edit_file(&args.path, &edits)?;
            Ok(ToolOutput {
                content: format!("edited {}; new size {} bytes", args.path, content.len()),
            })
        }
        None => Err(ToolError::UnsupportedTool(name.to_string())),
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
    fn write_file_creates_parent_directories() {
        let mut path = temp_path("write-dir");
        path.push("nested/file.txt");

        write_file(&path, "created").unwrap();
        let contents = read_file(&path).unwrap();
        fs::remove_dir_all(path.parent().unwrap().parent().unwrap()).unwrap();

        assert_eq!(contents, "created");
    }

    #[test]
    fn edit_file_replaces_unique_text() {
        let path = write_temp_file("edit", "alpha beta gamma");
        let edits = vec![("beta".to_string(), "delta".to_string())];

        let updated = edit_file(&path, &edits).unwrap();
        let contents = read_file(&path).unwrap();
        fs::remove_file(path).unwrap();

        assert_eq!(updated, "alpha delta gamma");
        assert_eq!(contents, "alpha delta gamma");
    }

    #[test]
    fn edit_file_rejects_non_unique_text() {
        let path = write_temp_file("edit-non-unique", "same same");
        let edits = vec![("same".to_string(), "other".to_string())];

        let error = edit_file(&path, &edits).unwrap_err();
        fs::remove_file(path).unwrap();

        assert!(matches!(error, ToolError::ReplaceNotUnique(_)));
    }

    #[test]
    fn execute_write_tool_uses_json_arguments() {
        let path = temp_path("execute-write");
        let args = serde_json::json!({"path": path, "content": "written"}).to_string();

        let output = execute_builtin_tool("write", &args).unwrap();
        let contents = read_file(&path).unwrap();
        fs::remove_file(path).unwrap();

        assert!(output.content.contains("wrote 7 bytes"));
        assert_eq!(contents, "written");
    }

    #[test]
    fn execute_edit_tool_uses_json_arguments() {
        let path = write_temp_file("execute-edit", "hello old");
        let args = serde_json::json!({
            "path": path,
            "edits": [{"old_text": "old", "new_text": "new"}]
        })
        .to_string();

        let output = execute_builtin_tool("edit", &args).unwrap();
        let contents = read_file(&path).unwrap();
        fs::remove_file(path).unwrap();

        assert!(output.content.contains("edited"));
        assert_eq!(contents, "hello new");
    }

    #[test]
    fn execute_unknown_tool_returns_error() {
        let error = execute_builtin_tool("missing", "{}").unwrap_err();
        assert!(matches!(error, ToolError::UnknownTool(_)));
    }

    fn write_temp_file(label: &str, contents: &str) -> std::path::PathBuf {
        let path = temp_path(label);
        fs::write(&path, contents).unwrap();
        path
    }

    fn temp_path(label: &str) -> std::path::PathBuf {
        let mut path = std::env::temp_dir();
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        path.push(format!("pi-tools-{label}-{unique}"));
        path
    }
}
