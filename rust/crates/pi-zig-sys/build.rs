use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let manifest_dir =
        PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is set"));
    let kernel_dir = manifest_dir.join("../../zig-kernel");

    println!(
        "cargo:rerun-if-changed={}",
        kernel_dir.join("build.zig").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        kernel_dir.join("src/ffi.zig").display()
    );

    let mut command = Command::new("zig");
    command
        .arg("build")
        .arg("-Doptimize=ReleaseSafe")
        .current_dir(&kernel_dir);
    if let Some(zig_target) = rust_target_to_zig_target() {
        command.arg(format!("-Dtarget={zig_target}"));
    }

    let status = command
        .status()
        .expect("failed to run zig build for pi Zig kernel");
    if !status.success() {
        panic!("zig build failed for pi Zig kernel");
    }

    println!(
        "cargo:rustc-link-search=native={}",
        kernel_dir.join("zig-out/lib").display()
    );
    println!("cargo:rustc-link-lib=static=pi_zig_kernel");
}

fn rust_target_to_zig_target() -> Option<&'static str> {
    let target = env::var("TARGET").ok()?;
    match target.as_str() {
        "aarch64-apple-darwin" => Some("aarch64-macos"),
        "x86_64-apple-darwin" => Some("x86_64-macos"),
        "x86_64-unknown-linux-gnu" => Some("x86_64-linux-gnu"),
        "aarch64-unknown-linux-gnu" => Some("aarch64-linux-gnu"),
        "x86_64-pc-windows-gnu" => Some("x86_64-windows-gnu"),
        "aarch64-pc-windows-msvc" => Some("aarch64-windows-msvc"),
        _ => None,
    }
}
