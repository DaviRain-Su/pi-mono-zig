use serde::{Deserialize, Serialize};
use std::error::Error;
use std::fmt::{Display, Formatter};
use std::str::FromStr;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Role {
    User,
    Assistant,
    Tool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments_json: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Message {
    pub role: Role,
    pub content: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tool_calls: Vec<ToolCall>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
}

impl Message {
    pub fn user(content: impl Into<String>) -> Self {
        Self {
            role: Role::User,
            content: content.into(),
            tool_calls: Vec::new(),
            tool_call_id: None,
            tool_name: None,
        }
    }

    pub fn assistant(content: impl Into<String>) -> Self {
        Self {
            role: Role::Assistant,
            content: content.into(),
            tool_calls: Vec::new(),
            tool_call_id: None,
            tool_name: None,
        }
    }

    pub fn assistant_with_tool_call(content: impl Into<String>, tool_call: ToolCall) -> Self {
        Self {
            role: Role::Assistant,
            content: content.into(),
            tool_calls: vec![tool_call],
            tool_call_id: None,
            tool_name: None,
        }
    }

    pub fn tool_result(tool_call: &ToolCall, content: impl Into<String>) -> Self {
        Self {
            role: Role::Tool,
            content: content.into(),
            tool_calls: Vec::new(),
            tool_call_id: Some(tool_call.id.clone()),
            tool_name: Some(tool_call.name.clone()),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProviderError {
    EmptyMessages,
    LastMessageNotUser,
    LastMessageNotUserOrTool,
}

impl Display for ProviderError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            ProviderError::EmptyMessages => write!(f, "provider requires at least one message"),
            ProviderError::LastMessageNotUser => write!(f, "latest message must be a user message"),
            ProviderError::LastMessageNotUserOrTool => {
                write!(f, "latest message must be a user or tool message")
            }
        }
    }
}

impl Error for ProviderError {}

pub trait Provider {
    fn complete(&self, messages: &[Message]) -> Result<Message, ProviderError>;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum BuiltinProvider {
    Faux,
    ToolDemo,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UnknownProvider {
    pub name: String,
}

impl Display for UnknownProvider {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "unknown provider: {}", self.name)
    }
}

impl Error for UnknownProvider {}

impl BuiltinProvider {
    pub const ALL: &'static [BuiltinProvider] = &[BuiltinProvider::Faux, BuiltinProvider::ToolDemo];

    pub const fn as_str(self) -> &'static str {
        match self {
            BuiltinProvider::Faux => "faux",
            BuiltinProvider::ToolDemo => "tool-demo",
        }
    }

    pub const fn supports_tools(self) -> bool {
        match self {
            BuiltinProvider::Faux => false,
            BuiltinProvider::ToolDemo => true,
        }
    }
}

impl Display for BuiltinProvider {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for BuiltinProvider {
    type Err = UnknownProvider;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "faux" => Ok(BuiltinProvider::Faux),
            "tool-demo" => Ok(BuiltinProvider::ToolDemo),
            _ => Err(UnknownProvider {
                name: value.to_string(),
            }),
        }
    }
}

impl Provider for BuiltinProvider {
    fn complete(&self, messages: &[Message]) -> Result<Message, ProviderError> {
        match self {
            BuiltinProvider::Faux => FauxProvider.complete(messages),
            BuiltinProvider::ToolDemo => ToolDemoProvider.complete(messages),
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct FauxProvider;

impl Provider for FauxProvider {
    fn complete(&self, messages: &[Message]) -> Result<Message, ProviderError> {
        let last = messages.last().ok_or(ProviderError::EmptyMessages)?;
        if last.role != Role::User {
            return Err(ProviderError::LastMessageNotUser);
        }
        Ok(Message::assistant(format!("faux: {}", last.content)))
    }
}

#[derive(Clone, Debug, Default)]
pub struct ToolDemoProvider;

impl Provider for ToolDemoProvider {
    fn complete(&self, messages: &[Message]) -> Result<Message, ProviderError> {
        let last = messages.last().ok_or(ProviderError::EmptyMessages)?;
        match last.role {
            Role::User => {
                if let Some(command) = last.content.strip_prefix("bash: ") {
                    let arguments_json = serde_json::json!({ "command": command }).to_string();
                    Ok(Message::assistant_with_tool_call(
                        "requesting bash tool",
                        ToolCall {
                            id: "call-1".to_string(),
                            name: "bash".to_string(),
                            arguments_json,
                        },
                    ))
                } else {
                    Ok(Message::assistant(format!("tool-demo: {}", last.content)))
                }
            }
            Role::Tool => Ok(Message::assistant(format!("tool result: {}", last.content))),
            Role::Assistant => Err(ProviderError::LastMessageNotUserOrTool),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn faux_provider_echoes_latest_user_prompt() {
        let provider = FauxProvider;
        let response = provider.complete(&[Message::user("hello")]).unwrap();
        assert_eq!(response, Message::assistant("faux: hello"));
    }

    #[test]
    fn faux_provider_rejects_empty_messages() {
        let provider = FauxProvider;
        assert_eq!(
            provider.complete(&[]).unwrap_err(),
            ProviderError::EmptyMessages
        );
    }

    #[test]
    fn faux_provider_requires_latest_user_message() {
        let provider = FauxProvider;
        let messages = [Message::assistant("done")];
        assert_eq!(
            provider.complete(&messages).unwrap_err(),
            ProviderError::LastMessageNotUser
        );
    }

    #[test]
    fn builtin_provider_parses_and_dispatches() {
        let provider: BuiltinProvider = "tool-demo".parse().unwrap();
        assert_eq!(provider.as_str(), "tool-demo");
        assert!(provider.supports_tools());
        let response = provider.complete(&[Message::user("plain")]).unwrap();
        assert_eq!(response, Message::assistant("tool-demo: plain"));
    }

    #[test]
    fn unknown_builtin_provider_returns_name() {
        let error = "missing".parse::<BuiltinProvider>().unwrap_err();
        assert_eq!(error.name, "missing");
    }

    #[test]
    fn tool_demo_provider_requests_bash_tool() {
        let provider = ToolDemoProvider;
        let response = provider
            .complete(&[Message::user("bash: printf hi")])
            .unwrap();
        assert_eq!(response.tool_calls.len(), 1);
        assert_eq!(response.tool_calls[0].name, "bash");
        assert!(response.tool_calls[0].arguments_json.contains("printf hi"));
    }

    #[test]
    fn tool_result_message_records_call_identity() {
        let call = ToolCall {
            id: "call-1".into(),
            name: "bash".into(),
            arguments_json: "{}".into(),
        };
        let result = Message::tool_result(&call, "ok");
        assert_eq!(result.role, Role::Tool);
        assert_eq!(result.tool_call_id.as_deref(), Some("call-1"));
        assert_eq!(result.tool_name.as_deref(), Some("bash"));
    }
}
