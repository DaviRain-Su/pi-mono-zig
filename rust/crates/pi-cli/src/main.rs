use pi_ai::{FauxProvider, Message, ToolDemoProvider};
use pi_core::AgentSession;
use pi_session::SessionFile;
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use std::path::PathBuf;

fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args == ["--mode", "rpc"] {
        if let Err(message) = run_rpc_stdio() {
            eprintln!("{message}");
            std::process::exit(1);
        }
        return;
    }

    match run(args) {
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

fn run_rpc_stdio() -> Result<(), String> {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut writer = stdout.lock();
    let mut runtime = RpcRuntime::new();

    for line in stdin.lock().lines() {
        let line = line.map_err(|error| error.to_string())?;
        for response in runtime.handle_line(&line) {
            writeln!(writer, "{response}").map_err(|error| error.to_string())?;
        }
    }

    Ok(())
}

#[derive(Clone, Debug)]
struct RpcRuntime {
    provider: ProviderKind,
    messages: Vec<Message>,
}

impl RpcRuntime {
    fn new() -> Self {
        Self {
            provider: ProviderKind::Faux,
            messages: Vec::new(),
        }
    }

    fn handle_line(&mut self, line: &str) -> Vec<String> {
        let parsed = match serde_json::from_str::<Value>(line) {
            Ok(value) => value,
            Err(error) => {
                return vec![rpc_response(
                    None,
                    "parse",
                    false,
                    None,
                    Some(error.to_string()),
                )];
            }
        };

        let id = parsed.get("id").cloned();
        let command = parsed
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        vec![self.handle_command(id, command, &parsed)]
    }

    fn handle_command(&mut self, id: Option<Value>, command: &str, value: &Value) -> String {
        match command {
            "set_provider" => self.handle_set_provider(id, command, value),
            "prompt" => self.handle_prompt(id, command, value),
            "get_state" => rpc_response(
                id,
                command,
                true,
                Some(json!({
                    "provider": self.provider.as_str(),
                    "messageCount": self.messages.len(),
                })),
                None,
            ),
            "get_messages" => rpc_response(
                id,
                command,
                true,
                Some(json!({ "messages": self.messages })),
                None,
            ),
            "tool" => self.handle_tool(id, command, value),
            _ => rpc_response(
                id,
                command,
                false,
                None,
                Some(format!("unknown command: {command}")),
            ),
        }
    }

    fn handle_set_provider(&mut self, id: Option<Value>, command: &str, value: &Value) -> String {
        let Some(provider) = value.get("provider").and_then(Value::as_str) else {
            return rpc_response(
                id,
                command,
                false,
                None,
                Some("provider is required".to_string()),
            );
        };
        match parse_provider(provider) {
            Ok(provider) => {
                self.provider = provider;
                rpc_response(
                    id,
                    command,
                    true,
                    Some(json!({ "provider": self.provider.as_str() })),
                    None,
                )
            }
            Err(error) => rpc_response(id, command, false, None, Some(error)),
        }
    }

    fn handle_prompt(&mut self, id: Option<Value>, command: &str, value: &Value) -> String {
        let Some(message) = value.get("message").and_then(Value::as_str) else {
            return rpc_response(
                id,
                command,
                false,
                None,
                Some("message is required".to_string()),
            );
        };

        let provider = match value.get("provider").and_then(Value::as_str) {
            Some(provider) => match parse_provider(provider) {
                Ok(provider) => provider,
                Err(error) => return rpc_response(id, command, false, None, Some(error)),
            },
            None => self.provider,
        };

        let result = match provider {
            ProviderKind::Faux => {
                self.prompt_with_provider(FauxProvider, message.to_string(), false)
            }
            ProviderKind::ToolDemo => {
                self.prompt_with_provider(ToolDemoProvider, message.to_string(), true)
            }
        };

        match result {
            Ok(assistant) => rpc_response(
                id,
                command,
                true,
                Some(json!({ "assistant": assistant, "messages": self.messages })),
                None,
            ),
            Err(error) => rpc_response(id, command, false, None, Some(error)),
        }
    }

    fn prompt_with_provider<P: pi_ai::Provider>(
        &mut self,
        provider: P,
        message: String,
        use_tools: bool,
    ) -> Result<Message, String> {
        let mut session = AgentSession::with_messages(provider, self.messages.clone());
        let assistant = if use_tools {
            session
                .prompt_with_tools(message)
                .map_err(|error| error.to_string())?
        } else {
            session.prompt(message).map_err(|error| error.to_string())?
        };
        self.messages = session.messages().to_vec();
        Ok(assistant)
    }

    fn handle_tool(&mut self, id: Option<Value>, command: &str, value: &Value) -> String {
        let Some(name) = value.get("name").and_then(Value::as_str) else {
            return rpc_response(
                id,
                command,
                false,
                None,
                Some("name is required".to_string()),
            );
        };
        let Some(arguments) = value.get("arguments") else {
            return rpc_response(
                id,
                command,
                false,
                None,
                Some("arguments is required".to_string()),
            );
        };
        let arguments_json = arguments.to_string();
        match pi_tools::execute_builtin_tool(name, &arguments_json) {
            Ok(output) => rpc_response(
                id,
                command,
                true,
                Some(json!({ "output": output.content })),
                None,
            ),
            Err(error) => rpc_response(id, command, false, None, Some(error.to_string())),
        }
    }
}

fn rpc_response(
    id: Option<Value>,
    command: &str,
    success: bool,
    data: Option<Value>,
    error: Option<String>,
) -> String {
    let mut response = json!({
        "type": "response",
        "command": command,
        "success": success,
    });
    if let Some(id) = id {
        response["id"] = id;
    }
    if let Some(data) = data {
        response["data"] = data;
    }
    if let Some(error) = error {
        response["error"] = json!(error);
    }
    response.to_string()
}

impl ProviderKind {
    fn as_str(self) -> &'static str {
        match self {
            ProviderKind::Faux => "faux",
            ProviderKind::ToolDemo => "tool-demo",
        }
    }
}

fn usage() -> String {
    "usage: pi-rs -p <prompt> [--provider faux|tool-demo] [--session <path>] | --mode rpc | --list-tools | --tool <name> <json> | --tool-demo <prompt>".to_string()
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
            "usage: pi-rs -p <prompt> [--provider faux|tool-demo] [--session <path>] | --mode rpc | --list-tools | --tool <name> <json> | --tool-demo <prompt>"
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
    fn rpc_prompt_returns_response_and_records_messages() {
        let mut runtime = RpcRuntime::new();
        let responses = runtime.handle_line(r#"{"id":"1","type":"prompt","message":"hello"}"#);
        let response: Value = serde_json::from_str(&responses[0]).unwrap();

        assert_eq!(response["id"], "1");
        assert_eq!(response["success"], true);
        assert_eq!(response["data"]["assistant"]["content"], "faux: hello");
        assert_eq!(runtime.messages.len(), 2);
    }

    #[test]
    fn rpc_tool_demo_prompt_runs_tool_loop() {
        let mut runtime = RpcRuntime::new();
        let responses = runtime.handle_line(
            r#"{"id":"2","type":"prompt","provider":"tool-demo","message":"bash: printf rpc-loop"}"#,
        );
        let response: Value = serde_json::from_str(&responses[0]).unwrap();

        assert_eq!(response["success"], true);
        assert!(response["data"]["assistant"]["content"]
            .as_str()
            .unwrap()
            .contains("rpc-loop"));
        assert_eq!(runtime.messages.len(), 4);
    }

    #[test]
    fn rpc_tool_command_executes_registry_tool() {
        let mut runtime = RpcRuntime::new();
        let responses = runtime.handle_line(
            r#"{"id":"3","type":"tool","name":"bash","arguments":{"command":"printf rpc-tool"}}"#,
        );
        let response: Value = serde_json::from_str(&responses[0]).unwrap();

        assert_eq!(response["success"], true);
        assert!(response["data"]["output"]
            .as_str()
            .unwrap()
            .contains("rpc-tool"));
    }

    #[test]
    fn rpc_get_state_reports_provider_and_message_count() {
        let mut runtime = RpcRuntime::new();
        runtime.handle_line(r#"{"type":"set_provider","provider":"tool-demo"}"#);
        let responses = runtime.handle_line(r#"{"type":"get_state"}"#);
        let response: Value = serde_json::from_str(&responses[0]).unwrap();

        assert_eq!(response["success"], true);
        assert_eq!(response["data"]["provider"], "tool-demo");
        assert_eq!(response["data"]["messageCount"], 0);
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
