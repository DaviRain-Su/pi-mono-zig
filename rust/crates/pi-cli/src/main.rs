use pi_ai::FauxProvider;
use pi_core::AgentSession;

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

fn run(args: Vec<String>) -> Result<Option<String>, String> {
    let prompt = parse_print_prompt(&args)?;
    ensure_zig_kernel_linked()?;

    let mut session = AgentSession::new(FauxProvider);
    let assistant = session.prompt(prompt).map_err(|error| error.to_string())?;
    Ok(Some(assistant.content))
}

fn ensure_zig_kernel_linked() -> Result<(), String> {
    pi_zig::fuzzy_filter("", &[])
        .map(|_| ())
        .map_err(|error| format!("Zig kernel smoke failed: {error}"))
}

fn parse_print_prompt(args: &[String]) -> Result<String, String> {
    let Some(flag) = args.first() else {
        return Err(usage());
    };

    if flag != "-p" && flag != "--print" {
        return Err(usage());
    }

    Ok(args[1..].join(" "))
}

fn usage() -> String {
    "usage: pi-rs -p <prompt>".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

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
        assert_eq!(run(vec![]).unwrap_err(), "usage: pi-rs -p <prompt>");
    }
}
