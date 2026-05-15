use pi_ai::{FauxProvider, ToolDemoProvider};
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
    provider: ProviderKind,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ProviderKind {
    Faux,
    ToolDemo,
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
    if args.first().is_some_and(|arg| arg == "--list-tools") {
        return Ok(Some(format_tool_definitions()));
    }
    if args.first().is_some_and(|arg| arg == "--tool") {
        return run_tool_command(&args);
    }
    if args.first().is_some_and(|arg| arg == "--tool-demo") {
        return run_tool_demo_command(&args);
    }

    let args = parse_args(&args)?;
    ensure_zig_kernel_linked()?;

    match args.provider {
        ProviderKind::Faux => run_print_with_provider(FauxProvider, args, false),
        ProviderKind::ToolDemo => run_print_with_provider(ToolDemoProvider, args, true),
    }
}

fn run_print_with_provider<P: pi_ai::Provider>(
    provider: P,
    args: CliArgs,
    use_tools: bool,
) -> Result<Option<String>, String> {
    let existing_messages = if let Some(path) = &args.session_path {
        SessionFile::open(path)
            .and_then(|session| session.load_messages())
            .map_err(|error| error.to_string())?
    } else {
        Vec::new()
    };
    let existing_len = existing_messages.len();

    let mut agent = AgentSession::with_messages(provider, existing_messages);
    let assistant = if use_tools {
        agent
            .prompt_with_tools(args.prompt)
            .map_err(|error| error.to_string())?
    } else {
        agent
            .prompt(args.prompt)
            .map_err(|error| error.to_string())?
    };

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

fn format_tool_definitions() -> String {
    pi_tools::builtin_tool_definitions()
        .iter()
        .map(|tool| {
            format!(
                "{}\t{}\tmutates={}\t{}",
                tool.name, tool.label, tool.mutates, tool.parameters_json
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn run_tool_command(args: &[String]) -> Result<Option<String>, String> {
    let Some(name) = args.get(1) else {
        return Err("--tool requires a tool name".to_string());
    };
    let Some(arguments_json) = args.get(2) else {
        return Err("--tool requires JSON arguments".to_string());
    };
    pi_tools::execute_builtin_tool(name, arguments_json)
        .map(|output| Some(output.content))
        .map_err(|error| error.to_string())
}

fn run_tool_demo_command(args: &[String]) -> Result<Option<String>, String> {
    let prompt = args[1..].join(" ");
    let mut session = AgentSession::new(ToolDemoProvider);
    session
        .prompt_with_tools(prompt)
        .map(|message| Some(message.content))
        .map_err(|error| error.to_string())
}

fn parse_args(args: &[String]) -> Result<CliArgs, String> {
    let mut session_path = None;
    let mut prompt_parts = Vec::new();
    let mut print_mode = false;
    let mut provider = ProviderKind::Faux;
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
            "--provider" => {
                let Some(value) = args.get(index + 1) else {
                    return Err("--provider requires a provider name".to_string());
                };
                provider = parse_provider(value)?;
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
        provider,
    })
}

fn parse_provider(value: &str) -> Result<ProviderKind, String> {
    match value {
        "faux" => Ok(ProviderKind::Faux),
        "tool-demo" => Ok(ProviderKind::ToolDemo),
        _ => Err(format!("unknown provider: {value}")),
    }
}

fn usage() -> String {
    "usage: pi-rs -p <prompt> [--provider faux|tool-demo] [--session <path>] | --list-tools | --tool <name> <json> | --tool-demo <prompt>".to_string()
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
            "usage: pi-rs -p <prompt> [--provider faux|tool-demo] [--session <path>] | --list-tools | --tool <name> <json> | --tool-demo <prompt>"
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
    fn lists_tool_definitions_from_registry() {
        let output = run(vec!["--list-tools".into()]).unwrap().unwrap();
        assert!(output.contains("read\tRead File"));
        assert!(output.contains("\"path\""));
    }

    #[test]
    fn executes_bash_tool_from_registry() {
        let output = run(vec![
            "--tool".into(),
            "bash".into(),
            r#"{"command":"printf cli-tool"}"#.into(),
        ])
        .unwrap()
        .unwrap();
        assert!(output.contains("status: 0"));
        assert!(output.contains("cli-tool"));
    }

    #[test]
    fn tool_demo_runs_agent_tool_loop() {
        let output = run(vec![
            "--tool-demo".into(),
            "bash:".into(),
            "printf".into(),
            "loop".into(),
        ])
        .unwrap()
        .unwrap();
        assert!(output.contains("tool result:"));
        assert!(output.contains("loop"));
    }

    #[test]
    fn provider_tool_demo_runs_tool_loop_in_print_mode() {
        let output = run(vec![
            "-p".into(),
            "bash:".into(),
            "printf".into(),
            "provider-loop".into(),
            "--provider".into(),
            "tool-demo".into(),
        ])
        .unwrap()
        .unwrap();
        assert!(output.contains("tool result:"));
        assert!(output.contains("provider-loop"));
    }

    #[test]
    fn provider_tool_demo_persists_tool_loop_messages() {
        let path = temp_session_path();
        let output = run(vec![
            "--provider".into(),
            "tool-demo".into(),
            "-p".into(),
            "bash:".into(),
            "printf".into(),
            "persist-loop".into(),
            "--session".into(),
            path.to_string_lossy().into_owned(),
        ])
        .unwrap()
        .unwrap();
        assert!(output.contains("persist-loop"));

        let entries = load_entries(&path).unwrap();
        fs::remove_file(path).unwrap();

        assert_eq!(entries.len(), 4);
        assert_eq!(entries[0].message.content, "bash: printf persist-loop");
        assert!(!entries[1].message.tool_calls.is_empty());
        assert_eq!(entries[2].message.role, pi_ai::Role::Tool);
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
