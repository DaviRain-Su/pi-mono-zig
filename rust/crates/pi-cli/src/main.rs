use pi_ai::FauxProvider;
use pi_core::AgentSession;
use pi_session::SessionFile;
use std::path::PathBuf;

fn main() {
    match run(std::env::args().skip(1).collect()) {
        Ok(output) => {
            if let Some(output) = output {
                println!("{output}");
            }
        }
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(1);
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct CliArgs {
    prompt: String,
    session_path: Option<PathBuf>,
}

fn run(args: Vec<String>) -> Result<Option<String>, String> {
    if args
        .first()
        .is_some_and(|arg| arg == "--list-zig-generated-tools")
    {
        return Ok(Some(pi_zig_codegen::zig_generated_tool_names!().join("\n")));
    }
    if args
        .first()
        .is_some_and(|arg| arg == "--list-zig-generated-tool-schemas")
    {
        return Ok(Some(format_zig_generated_tool_schemas()));
    }

    let args = parse_args(&args)?;
    ensure_zig_kernel_linked()?;

    let existing_messages = if let Some(path) = &args.session_path {
        SessionFile::open(path)
            .and_then(|session| session.load_messages())
            .map_err(|error| error.to_string())?
    } else {
        Vec::new()
    };
    let existing_len = existing_messages.len();

    let mut agent = AgentSession::with_messages(FauxProvider, existing_messages);
    let assistant = agent
        .prompt(args.prompt)
        .map_err(|error| error.to_string())?;

    if let Some(path) = &args.session_path {
        let mut session = SessionFile::open(path).map_err(|error| error.to_string())?;
        session
            .append_messages(&agent.messages()[existing_len..])
            .map_err(|error| error.to_string())?;
    }

    Ok(Some(assistant.content))
}

fn ensure_zig_kernel_linked() -> Result<(), String> {
    pi_zig::fuzzy_filter("", &[])
        .map(|_| ())
        .map_err(|error| format!("Zig kernel smoke failed: {error}"))
}

fn format_zig_generated_tool_schemas() -> String {
    pi_zig_codegen::generated_tools()
        .iter()
        .map(|tool| format!("{} {}", tool.name, tool.parameters_json))
        .collect::<Vec<_>>()
        .join("\n")
}

fn parse_args(args: &[String]) -> Result<CliArgs, String> {
    let mut session_path = None;
    let mut prompt_parts = Vec::new();
    let mut print_mode = false;
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "-p" | "--print" => {
                print_mode = true;
                index += 1;
            }
            "--session" => {
                let Some(path) = args.get(index + 1) else {
                    return Err("--session requires a path".to_string());
                };
                session_path = Some(PathBuf::from(path));
                index += 2;
            }
            value => {
                prompt_parts.push(value.to_string());
                index += 1;
            }
        }
    }

    if !print_mode {
        return Err(usage());
    }

    Ok(CliArgs {
        prompt: prompt_parts.join(" "),
        session_path,
    })
}

fn usage() -> String {
    "usage: pi-rs -p <prompt> [--session <path>] | --list-zig-generated-tools | --list-zig-generated-tool-schemas".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use pi_session::load_entries;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn print_mode_returns_faux_response() {
        let output = run(vec!["-p".into(), "hello".into()]).unwrap();
        assert_eq!(output, Some("faux: hello".into()));
    }

    #[test]
    fn long_prompt_is_joined_with_spaces() {
        let output = run(vec!["--print".into(), "hello".into(), "world".into()]).unwrap();
        assert_eq!(output, Some("faux: hello world".into()));
    }

    #[test]
    fn missing_print_flag_returns_usage_error() {
        assert_eq!(
            run(vec![]).unwrap_err(),
            "usage: pi-rs -p <prompt> [--session <path>] | --list-zig-generated-tools | --list-zig-generated-tool-schemas"
        );
    }

    #[test]
    fn lists_zig_comptime_generated_tools() {
        let output = run(vec!["--list-zig-generated-tools".into()]).unwrap();
        assert_eq!(output, Some("read\nbash\nedit\nwrite".into()));
    }

    #[test]
    fn lists_zig_comptime_reflected_schemas() {
        let output = run(vec!["--list-zig-generated-tool-schemas".into()])
            .unwrap()
            .unwrap();
        assert!(output.contains("edit {\"type\":\"object\""));
        assert!(output.contains("\"old_text\""));
    }

    #[test]
    fn session_path_persists_new_messages() {
        let path = temp_session_path();
        let output = run(vec![
            "-p".into(),
            "hello".into(),
            "--session".into(),
            path.to_string_lossy().into_owned(),
        ])
        .unwrap();
        assert_eq!(output, Some("faux: hello".into()));

        let entries = load_entries(&path).unwrap();
        fs::remove_file(path).unwrap();

        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].message.content, "hello");
        assert_eq!(entries[1].message.content, "faux: hello");
    }

    fn temp_session_path() -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let mut path = std::env::temp_dir();
        path.push(format!("pi-cli-{unique}.jsonl"));
        path
    }
}
