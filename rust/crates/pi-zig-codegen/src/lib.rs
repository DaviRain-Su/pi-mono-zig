mod generated {
    include!(concat!(env!("OUT_DIR"), "/zig_tools.rs"));
}

pub use generated::{
    GeneratedTool, ZIG_GENERATED_TOOLS, ZIG_GENERATED_TOOL_COUNT, ZIG_GENERATED_TOOL_NAMES,
};

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
    }
}
