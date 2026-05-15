use std::error::Error;
use std::fmt::{Display, Formatter};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Role {
    User,
    Assistant,
    Tool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Message {
    pub role: Role,
    pub content: String,
}

impl Message {
    pub fn user(content: impl Into<String>) -> Self {
        Self {
            role: Role::User,
            content: content.into(),
        }
    }

    pub fn assistant(content: impl Into<String>) -> Self {
        Self {
            role: Role::Assistant,
            content: content.into(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProviderError {
    EmptyMessages,
    LastMessageNotUser,
}

impl Display for ProviderError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            ProviderError::EmptyMessages => write!(f, "provider requires at least one message"),
            ProviderError::LastMessageNotUser => write!(f, "latest message must be a user message"),
        }
    }
}

impl Error for ProviderError {}

pub trait Provider {
    fn complete(&self, messages: &[Message]) -> Result<Message, ProviderError>;
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
}
