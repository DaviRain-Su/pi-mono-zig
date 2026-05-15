use pi_ai::{BuiltinProvider, Message};
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
    prompt: Option<String>,
    continue_session: bool,
    session_path: Option<PathBuf>,
    provider: BuiltinProvider,
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

    run_print_with_provider(args)
}

fn run_print_with_provider(args: CliArgs) -> Result<Option<String>, String> {
    let existing_messages = if let Some(path) = &args.session_path {
        SessionFile::open(path)
            .and_then(|session| session.load_messages())
            .map_err(|error| error.to_string())?
    } else {
        Vec::new()
    };
    let existing_len = existing_messages.len();

    if args.continue_session && args.session_path.is_none() {
        return Err("--continue requires --session <path>".to_string());
    }

    let mut agent = AgentSession::with_messages(args.provider, existing_messages);
    let assistant = if args.continue_session {
        if args.provider.supports_tools() {
            agent
                .continue_with_tools()
                .map_err(|error| error.to_string())?
        } else {
            agent.continue_once().map_err(|error| error.to_string())?
        }
    } else {
        let prompt = args.prompt.unwrap_or_default();
        if args.provider.supports_tools() {
            agent
                .prompt_with_tools(prompt)
                .map_err(|error| error.to_string())?
        } else {
            agent.prompt(prompt).map_err(|error| error.to_string())?
        }
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
    let mut session = AgentSession::new(BuiltinProvider::ToolDemo);
    session
        .prompt_with_tools(prompt)
        .map(|message| Some(message.content))
        .map_err(|error| error.to_string())
}

fn parse_args(args: &[String]) -> Result<CliArgs, String> {
    let mut session_path = None;
    let mut prompt_parts = Vec::new();
    let mut print_mode = false;
    let mut continue_session = false;
    let mut provider = BuiltinProvider::Faux;
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "-p" | "--print" => {
                print_mode = true;
                index += 1;
            }
            "-c" | "--continue" => {
                continue_session = true;
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

    if !print_mode && !continue_session {
        return Err(usage());
    }

    Ok(CliArgs {
        prompt: if print_mode {
            Some(prompt_parts.join(" "))
        } else {
            None
        },
        continue_session,
        session_path,
        provider,
    })
}

fn parse_provider(value: &str) -> Result<BuiltinProvider, String> {
    value
        .parse::<BuiltinProvider>()
        .map_err(|error| error.to_string())
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
    provider: BuiltinProvider,
    messages: Vec<Message>,
    session_path: Option<PathBuf>,
}

impl RpcRuntime {
    fn new() -> Self {
        Self {
            provider: BuiltinProvider::Faux,
            messages: Vec::new(),
            session_path: None,
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
        if command == "prompt" {
            return self.handle_prompt(id, command, &parsed);
        }
        if command == "continue" {
            return self.handle_continue(id, command);
        }
        vec![self.handle_command(id, command, &parsed)]
    }

    fn handle_command(&mut self, id: Option<Value>, command: &str, value: &Value) -> String {
        match command {
            "set_provider" => self.handle_set_provider(id, command, value),
            "switch_session" => self.handle_switch_session(id, command, value),
            "new_session" => self.handle_new_session(id, command, value),
            "get_state" => rpc_response(
                id,
                command,
                true,
                Some(json!({
                    "provider": self.provider.as_str(),
                    "messageCount": self.messages.len(),
                    "sessionPath": self.session_path,
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

    fn handle_switch_session(&mut self, id: Option<Value>, command: &str, value: &Value) -> String {
        let Some(path) = value.get("path").and_then(Value::as_str) else {
            return rpc_response(
                id,
                command,
                false,
                None,
                Some("path is required".to_string()),
            );
        };
        match SessionFile::open(path).and_then(|session| session.load_messages()) {
            Ok(messages) => {
                self.messages = messages;
                self.session_path = Some(PathBuf::from(path));
                rpc_response(
                    id,
                    command,
                    true,
                    Some(json!({ "sessionPath": path, "messageCount": self.messages.len() })),
                    None,
                )
            }
            Err(error) => rpc_response(id, command, false, None, Some(error.to_string())),
        }
    }

    fn handle_new_session(&mut self, id: Option<Value>, command: &str, value: &Value) -> String {
        self.messages.clear();
        self.session_path = value.get("path").and_then(Value::as_str).map(PathBuf::from);
        if let Some(path) = &self.session_path {
            if let Err(error) = SessionFile::open(path) {
                return rpc_response(id, command, false, None, Some(error.to_string()));
            }
        }
        rpc_response(
            id,
            command,
            true,
            Some(json!({ "sessionPath": self.session_path, "messageCount": 0 })),
            None,
        )
    }

    fn handle_continue(&mut self, id: Option<Value>, command: &str) -> Vec<String> {
        let old_len = self.messages.len();
        let result = self.continue_with_provider(self.provider);
        self.response_and_events(id, command, old_len, result)
    }

    fn handle_prompt(&mut self, id: Option<Value>, command: &str, value: &Value) -> Vec<String> {
        let Some(message) = value.get("message").and_then(Value::as_str) else {
            return vec![rpc_response(
                id,
                command,
                false,
                None,
                Some("message is required".to_string()),
            )];
        };

        let provider = match value.get("provider").and_then(Value::as_str) {
            Some(provider) => match parse_provider(provider) {
                Ok(provider) => provider,
                Err(error) => return vec![rpc_response(id, command, false, None, Some(error))],
            },
            None => self.provider,
        };

        let old_len = self.messages.len();
        let result = self.prompt_with_provider(provider, message.to_string());

        self.response_and_events(id, command, old_len, result)
    }

    fn response_and_events(
        &mut self,
        id: Option<Value>,
        command: &str,
        old_len: usize,
        result: Result<Message, String>,
    ) -> Vec<String> {
        match result {
            Ok(assistant) => {
                let new_messages = self.messages[old_len..].to_vec();
                if let Err(error) = self.persist_new_messages(&new_messages) {
                    return vec![rpc_response(id, command, false, None, Some(error))];
                }
                let mut lines = vec![rpc_response(
                    id,
                    command,
                    true,
                    Some(json!({ "assistant": assistant, "messages": self.messages })),
                    None,
                )];
                lines.extend(rpc_events_for_messages(&new_messages));
                lines
            }
            Err(error) => vec![rpc_response(id, command, false, None, Some(error))],
        }
    }

    fn persist_new_messages(&self, messages: &[Message]) -> Result<(), String> {
        if let Some(path) = &self.session_path {
            let mut session = SessionFile::open(path).map_err(|error| error.to_string())?;
            session
                .append_messages(messages)
                .map_err(|error| error.to_string())?;
        }
        Ok(())
    }

    fn prompt_with_provider(
        &mut self,
        provider: BuiltinProvider,
        message: String,
    ) -> Result<Message, String> {
        let mut session = AgentSession::with_messages(provider, self.messages.clone());
        let assistant = if provider.supports_tools() {
            session
                .prompt_with_tools(message)
                .map_err(|error| error.to_string())?
        } else {
            session.prompt(message).map_err(|error| error.to_string())?
        };
        self.messages = session.messages().to_vec();
        Ok(assistant)
    }

    fn continue_with_provider(&mut self, provider: BuiltinProvider) -> Result<Message, String> {
        let mut session = AgentSession::with_messages(provider, self.messages.clone());
        let assistant = if provider.supports_tools() {
            session
                .continue_with_tools()
                .map_err(|error| error.to_string())?
        } else {
            session.continue_once().map_err(|error| error.to_string())?
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

fn rpc_events_for_messages(messages: &[Message]) -> Vec<String> {
    let mut events = Vec::new();
    for message in messages {
        match message.role {
            pi_ai::Role::User => {}
            pi_ai::Role::Assistant => {
                events.push(rpc_event("message_start", json!({ "message": message })));
                events.push(rpc_event("message_end", json!({ "message": message })));
                for tool_call in &message.tool_calls {
                    events.push(rpc_event(
                        "tool_execution_start",
                        json!({
                            "toolCallId": tool_call.id,
                            "toolName": tool_call.name,
                            "arguments": tool_call.arguments_json,
                        }),
                    ));
                }
            }
            pi_ai::Role::Tool => {
                events.push(rpc_event(
                    "tool_execution_end",
                    json!({
                        "toolCallId": message.tool_call_id,
                        "toolName": message.tool_name,
                        "output": message.content,
                    }),
                ));
            }
        }
    }
    events
}

fn rpc_event(event_type: &str, data: Value) -> String {
    json!({
        "type": "event",
        "event": event_type,
        "data": data,
    })
    .to_string()
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

fn usage() -> String {
    "usage: pi-rs -p <prompt> [--provider faux|tool-demo] [--session <path>] | pi-rs --continue --session <path> [--provider faux|tool-demo] | --mode rpc | --list-tools | --tool <name> <json> | --tool-demo <prompt>".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use pi_session::load_entries;
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

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
            "usage: pi-rs -p <prompt> [--provider faux|tool-demo] [--session <path>] | pi-rs --continue --session <path> [--provider faux|tool-demo] | --mode rpc | --list-tools | --tool <name> <json> | --tool-demo <prompt>"
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
        assert_eq!(responses.len(), 3);
        let start_event: Value = serde_json::from_str(&responses[1]).unwrap();
        let end_event: Value = serde_json::from_str(&responses[2]).unwrap();
        assert_eq!(start_event["type"], "event");
        assert_eq!(start_event["event"], "message_start");
        assert_eq!(end_event["event"], "message_end");
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
        assert_eq!(responses.len(), 7);
        let tool_start: Value = serde_json::from_str(&responses[3]).unwrap();
        let tool_end: Value = serde_json::from_str(&responses[4]).unwrap();
        assert_eq!(tool_start["event"], "tool_execution_start");
        assert_eq!(tool_start["data"]["toolName"], "bash");
        assert_eq!(tool_end["event"], "tool_execution_end");
        assert!(tool_end["data"]["output"]
            .as_str()
            .unwrap()
            .contains("rpc-loop"));
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
    fn rpc_switch_session_loads_messages() {
        let path = temp_session_path();
        let mut session = SessionFile::open(&path).unwrap();
        session.append_message(Message::user("loaded")).unwrap();

        let mut runtime = RpcRuntime::new();
        let command = json!({"type":"switch_session", "path": path}).to_string();
        let responses = runtime.handle_line(&command);
        let response: Value = serde_json::from_str(&responses[0]).unwrap();
        fs::remove_file(path).unwrap();

        assert_eq!(response["success"], true);
        assert_eq!(response["data"]["messageCount"], 1);
        assert_eq!(runtime.messages[0].content, "loaded");
    }

    #[test]
    fn rpc_prompt_persists_to_switched_session() {
        let path = temp_session_path();
        let mut runtime = RpcRuntime::new();
        runtime.handle_line(&json!({"type":"new_session", "path": path}).to_string());
        runtime.handle_line(r#"{"type":"prompt","message":"persist rpc"}"#);

        let entries = load_entries(&path).unwrap();
        fs::remove_file(path).unwrap();

        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].message.content, "persist rpc");
        assert_eq!(entries[1].message.content, "faux: persist rpc");
    }

    #[test]
    fn rpc_continue_uses_loaded_session() {
        let path = temp_session_path();
        let mut session = SessionFile::open(&path).unwrap();
        session.append_message(Message::user("rpc resume")).unwrap();

        let mut runtime = RpcRuntime::new();
        runtime.handle_line(&json!({"type":"switch_session", "path": path}).to_string());
        let responses = runtime.handle_line(r#"{"id":"c","type":"continue"}"#);
        let response: Value = serde_json::from_str(&responses[0]).unwrap();
        let entries = load_entries(&path).unwrap();
        fs::remove_file(path).unwrap();

        assert_eq!(response["success"], true);
        assert_eq!(response["data"]["assistant"]["content"], "faux: rpc resume");
        assert_eq!(entries.len(), 2);
    }

    #[test]
    fn continue_session_uses_existing_user_message() {
        let path = temp_session_path();
        let mut session = SessionFile::open(&path).unwrap();
        session.append_message(Message::user("resume me")).unwrap();

        let output = run(vec![
            "--continue".into(),
            "--session".into(),
            path.to_string_lossy().into_owned(),
        ])
        .unwrap();
        let entries = load_entries(&path).unwrap();
        fs::remove_file(path).unwrap();

        assert_eq!(output, Some("faux: resume me".into()));
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[1].message.content, "faux: resume me");
    }

    #[test]
    fn continue_session_runs_tool_loop_for_tool_demo() {
        let path = temp_session_path();
        let mut session = SessionFile::open(&path).unwrap();
        session
            .append_message(Message::user("bash: printf resumed-loop"))
            .unwrap();

        let output = run(vec![
            "--continue".into(),
            "--provider".into(),
            "tool-demo".into(),
            "--session".into(),
            path.to_string_lossy().into_owned(),
        ])
        .unwrap()
        .unwrap();
        let entries = load_entries(&path).unwrap();
        fs::remove_file(path).unwrap();

        assert!(output.contains("resumed-loop"));
        assert_eq!(entries.len(), 4);
        assert_eq!(entries[2].message.role, pi_ai::Role::Tool);
    }

    #[test]
    fn continue_requires_session_path() {
        assert_eq!(
            run(vec!["--continue".into()]).unwrap_err(),
            "--continue requires --session <path>"
        );
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
        let counter = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
        let mut path = std::env::temp_dir();
        path.push(format!("pi-cli-{unique}-{counter}.jsonl"));
        path
    }
}
