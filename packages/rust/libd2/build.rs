//! Builds the native C ABIs (the combined `d2` library: drlg, pathfinding, item, itemdraw, net
//! and util in one archive) for whatever target cargo asked for, and links it statically so the
//! resulting binary needs no shared library beside it. One archive rather than one per library:
//! each Zig static library carries its own copy of the shared packages and runtime, so several of
//! them cannot be linked into one binary.
//!
//! Unlike the npm and NuGet packages, which ship a prebuilt binary per platform, a crate
//! cannot reasonably carry fourteen of them. So the native side is built here from source,
//! which means `zig` has to be on PATH. That is a real requirement and the error below says
//! so plainly rather than failing with a linker error three screens later.

use std::{env, path::PathBuf, process::Command};

fn main() {
    // docs.rs only ever runs `cargo doc`, which never links, and has no zig. Building the
    // engine there would fail the docs build for no gain.
    if env::var_os("DOCS_RS").is_some() {
        return;
    }

    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    // In the repo the engine is a sibling package, and that is the copy to build: engine/ is
    // a vendored snapshot that goes stale the moment the real sources change. A published
    // crate has only engine/, because cargo will not package anything above the crate root.
    let drlg = ["../../wasm", "engine/wasm"]
        .iter()
        .map(|p| manifest.join(p))
        .find_map(|p| p.canonicalize().ok())
        .expect("libd2: cannot find the zig engine sources (engine/wasm or ../../wasm)");
    let packages = drlg.parent().unwrap().to_path_buf();
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());

    for pkg in ["wasm", "drlg", "pathfinding", "item", "itemdraw", "net", "util", "core", "data", "formats", "save"] {
        println!("cargo:rerun-if-changed={}", packages.join(pkg).join("src").display());
        println!("cargo:rerun-if-changed={}", packages.join(pkg).join("include").display());
    }

    let target = env::var("TARGET").unwrap();
    let zig_target = zig_target_for(&target)
        .unwrap_or_else(|| panic!("libd2: no zig target known for the rust target '{target}'. \
             Open an issue; the mapping lives in build.rs."));

    let status = Command::new("zig")
        .current_dir(&drlg)
        .args([
            "build",
            &format!("-Dtarget={zig_target}"),
            "-Doptimize=ReleaseFast",
            "--cache-dir",
        ])
        // Zig defaults its cache to .zig-cache beside build.zig. That would write into the
        // crate's own sources, which cargo rejects during `cargo package` verification and
        // which is rude to a read-only registry checkout either way.
        .arg(out.join("zig-cache"))
        .arg("--prefix")
        .arg(&out)
        .status()
        .unwrap_or_else(|e| panic!(
            "libd2: could not run `zig` ({e}). The native engine is written in Zig, so building \
             this crate needs zig 0.16+ on PATH — see https://ziglang.org/download/"
        ));
    assert!(status.success(), "libd2: `zig build` failed for target {zig_target}");

    println!("cargo:rustc-link-search=native={}", out.join("lib").display());
    if target.contains("apple") {
        realign(&out.join("lib").join("libd2.a"), &out.join("realign"));
    }
    println!("cargo:rustc-link-lib=static=d2");

    // Zig's static library carries no libc dependency of its own, but the Rust target's
    // runtime still needs its usual system libraries.
    if target.contains("apple") {
        println!("cargo:rustc-link-lib=framework=CoreFoundation");
    }
}

/// Apple's linker refuses an archive whose 64-bit object member does not start 8-byte aligned, and
/// where zig's archive writer puts the one object depends on the length of the symbol table before
/// it. Rewriting the archive with `zig ar --format=darwin` pads it into place.
fn realign(archive: &std::path::Path, work: &std::path::Path) {
    let _ = std::fs::remove_dir_all(work);
    std::fs::create_dir_all(work).unwrap();
    let run = |args: &[&std::ffi::OsStr]| {
        let ok = Command::new("zig").current_dir(work).args(args).status().map(|s| s.success()).unwrap_or(false);
        assert!(ok, "libd2: `zig {:?}` failed while realigning the archive", args);
    };
    run(&["ar".as_ref(), "x".as_ref(), archive.as_os_str()]);
    let mut objects: Vec<std::ffi::OsString> = Vec::new();
    for e in std::fs::read_dir(work).unwrap() {
        let p = e.unwrap().path();
        let mut perm = std::fs::metadata(&p).unwrap().permissions();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            perm.set_mode(0o644);
        }
        std::fs::set_permissions(&p, perm).unwrap();
        objects.push(p.file_name().unwrap().to_owned());
    }
    std::fs::remove_file(archive).unwrap();
    let mut args: Vec<&std::ffi::OsStr> = vec!["ar".as_ref(), "--format=darwin".as_ref(), "rcs".as_ref(), archive.as_os_str()];
    args.extend(objects.iter().map(|o| o.as_os_str()));
    run(&args);
}

/// Rust target triples and zig's differ in the vendor field, so map rather than munge.
fn zig_target_for(rust_target: &str) -> Option<&'static str> {
    Some(match rust_target {
        "x86_64-unknown-linux-gnu" => "x86_64-linux-gnu",
        "aarch64-unknown-linux-gnu" => "aarch64-linux-gnu",
        "arm-unknown-linux-gnueabihf" | "armv7-unknown-linux-gnueabihf" => "arm-linux-gnueabihf",
        "x86_64-unknown-linux-musl" => "x86_64-linux-musl",
        "aarch64-unknown-linux-musl" => "aarch64-linux-musl",
        "riscv64gc-unknown-linux-gnu" => "riscv64-linux-gnu",
        "x86_64-unknown-freebsd" => "x86_64-freebsd",
        "aarch64-unknown-freebsd" => "aarch64-freebsd",
        "x86_64-apple-darwin" => "x86_64-macos",
        "aarch64-apple-darwin" => "aarch64-macos",
        "i686-pc-windows-gnu" => "x86-windows-gnu",
        "x86_64-pc-windows-gnu" => "x86_64-windows-gnu",
        "aarch64-pc-windows-gnullvm" => "aarch64-windows-gnu",
        _ => return None,
    })
}
