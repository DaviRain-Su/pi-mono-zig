use pi_ai::{Message, Provider, ProviderError};
use std::error::Error;
use std::fmt::{Display, Formatter};

const DEFAULT_MAX_TOOL_TURNS: usize = 8;

#[derive(Debug)]
pub struct AgentSession<P: Provider> {
    provider: P,
    messages: Vec<Message>,
    max_tool_turns: usize,
}

#[derive(Debug)]
pub enum AgentError {
    Provider(ProviderError),
    Tool(pi_tools::ToolError),
    ToolTurnLimitExceeded { limit: usize },
}

impl Display for AgentError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            AgentError::Provider(error) => write!(f, "provider error: {error}"),
            AgentError::Tool(error) => write!(f, "tool error: {error}"),
            AgentError::ToolTurnLimitExceeded { limit } => {
                write!(f, "tool turn limit exceeded: {limit}")
            }
        }
    }
}

impl Error for AgentError {}

impl From<ProviderError> for AgentError {
    fn from(error: ProviderError) -> Self {
        AgentError::Provider(error)
    }
}

impl From<pi_tools::ToolError> for AgentError {
    fn from(error: pi_tools::ToolError) -> Self {
        AgentError::Tool(error)
    }
}

impl<P: Provider> AgentSession<P> {
    pub fn new(provider: P) -> Self {
        Self {
            provider,
            messages: Vec::new(),
            max_tool_turns: DEFAULT_MAX_TOOL_TURNS,
        }
    }

    pub fn with_messages(provider: P, messages: Vec<Message>) -> Self {
        Self {
            provider,
            messages,
            max_tool_turns: DEFAULT_MAX_TOOL_TURNS,
        }
    }

    pub fn with_max_tool_turns(mut self, max_tool_turns: usize) -> Self {
        self.max_tool_turns = max_tool_turns;
        self
    }

    pub fn messages(&self) -> &[Message] {
        &self.messages
    }

    pub fn prompt(&mut self, text: impl Into<String>) -> Result<Message, ProviderError> {
        self.messages.push(Message::user(text));
        let assistant = self.provider.complete(&self.messages)?;
        self.messages.push(assistant.clone());
        Ok(assistant)
    }

    pub fn prompt_with_tools(&mut self, text: impl Into<String>) -> Result<Message, AgentError> {
        self.messages.push(Message::user(text));
        self.complete_with_tools()
    }

    fn complete_with_tools(&mut self) -> Result<Message, AgentError> {
        for _ in 0..=self.max_tool_turns {
            let assistant = self.provider.complete(&self.messages)?;
            let tool_calls = assistant.tool_calls.clone();
            self.messages.push(assistant.clone());
            if tool_calls.is_empty() {
                return Ok(assistant);
            }

            for tool_call in tool_calls {
                let output =
                    pi_tools::execute_builtin_tool(&tool_call.name, &tool_call.arguments_json)?;
                self.messages
                    .push(Message::tool_result(&tool_call, output.content));
            }
        }

        Err(AgentError::ToolTurnLimitExceeded {
            limit: self.max_tool_turns,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pi_ai::{FauxProvider, Role, ToolDemoProvider};

    #[test]
    fn prompt_appends_user_and_assistant_messages() {
        let mut session = AgentSession::new(FauxProvider);
        let assistant = session.prompt("hello").unwrap();

        assert_eq!(assistant.content, "faux: hello");
        assert_eq!(session.messages().len(), 2);
        assert_eq!(session.messages()[0].role, Role::User);
        assert_eq!(session.messages()[1].role, Role::Assistant);
    }

    #[test]
    fn empty_prompt_is_accepted() {
        let mut session = AgentSession::new(FauxProvider);
        let assistant = session.prompt("").unwrap();
        assert_eq!(assistant.content, "faux: ");
    }

    #[test]
    fn with_messages_preserves_existing_transcript() {
        let mut session = AgentSession::with_messages(
            FauxProvider,
            vec![Message::user("old"), Message::assistant("faux: old")],
        );
        let assistant = session.prompt("new").unwrap();

        assert_eq!(assistant.content, "faux: new");
        assert_eq!(session.messages().len(), 4);
    }

    #[test]
    fn prompt_with_tools_executes_tool_and_continues() {
        let mut session = AgentSession::new(ToolDemoProvider);
        let assistant = session.prompt_with_tools("bash: printf from-tool").unwrap();

        assert!(assistant.content.contains("tool result:"));
        assert!(assistant.content.contains("from-tool"));
        assert_eq!(session.messages().len(), 4);
        assert_eq!(session.messages()[1].role, Role::Assistant);
        assert_eq!(session.messages()[2].role, Role::Tool);
        assert_eq!(session.messages()[3].role, Role::Assistant);
    }
}
