use pi_ai::{Message, Provider, ProviderError};

#[derive(Debug)]
pub struct AgentSession<P: Provider> {
    provider: P,
    messages: Vec<Message>,
}

impl<P: Provider> AgentSession<P> {
    pub fn new(provider: P) -> Self {
        Self {
            provider,
            messages: Vec::new(),
        }
    }

    pub fn with_messages(provider: P, messages: Vec<Message>) -> Self {
        Self { provider, messages }
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use pi_ai::{FauxProvider, Role};

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
}
