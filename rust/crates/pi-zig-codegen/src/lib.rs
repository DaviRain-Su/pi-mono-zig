mod generated {
    include!(concat!(env!("OUT_DIR"), "/zig_tools.rs"));
}

pub use generated::*;

#[macro_export]
macro_rules! zig_generated_tool_count {
    () => {
        $crate::ZIG_GENERATED_TOOL_COUNT
    };
}

#[macro_export]
macro_rules! zig_generated_tool_names {
    () => {
        $crate::ZIG_GENERATED_TOOL_NAMES
    };
}

pub fn generated_tool_names() -> &'static [&'static str] {
    ZIG_GENERATED_TOOL_NAMES
}

pub fn generated_tools() -> &'static [GeneratedTool] {
    ZIG_GENERATED_TOOLS
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exposes_zig_comptime_generated_tool_table() {
        assert_eq!(zig_generated_tool_count!(), 4);
        assert_eq!(zig_generated_tool_names!()[0], "read");
        assert!(generated_tools()
            .iter()
            .any(|tool| tool.name == "bash" && tool.mutates));
        let edit = generated_tools()
            .iter()
            .find(|tool| tool.name == "edit")
            .expect("edit tool exists");
        assert!(edit
            .parameters_json
            .contains("\"edits\":{\"type\":\"array\""));
        assert!(edit.parameters_json.contains("\"old_text\""));

        let args = parse_generated_tool_args(
            "edit",
            r#"{"path":"a.txt","edits":[{"old_text":"old","new_text":"new"}]}"#,
        )
        .unwrap()
        .unwrap();
        assert_eq!(args.tool_name().as_str(), "edit");
        assert!(matches!(args, GeneratedToolArgs::Edit(_)));
    }
}
