use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let manifest_dir =
        PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is set"));
    let codegen_path = manifest_dir.join("../../zig-codegen/tool_registry.zig");
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is set"));
    let generated_path = out_dir.join("zig_tools.rs");

    println!("cargo:rerun-if-changed={}", codegen_path.display());

    let output = Command::new("zig")
        .arg("run")
        .arg(&codegen_path)
        .output()
        .expect("failed to run Zig comptime code generator");

    if !output.status.success() {
        panic!(
            "Zig comptime code generator failed:\n{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fs::write(generated_path, output.stdout).expect("failed to write generated Rust source");
}
