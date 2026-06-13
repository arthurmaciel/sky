//! Pre-built console child + reverse-proxy (epic A).
//!
//! Replaces the in-process `console.rs` plain-HTML shell with the **real bundled
//! Sky.Live console**, spawned as a child process and reverse-proxied at
//! `/_sky/console/*`. The console binary is **pre-built at the user's `sky build`
//! time** (epic A1) into a shared cache — at runtime this module only `exec`s it,
//! never builds. See `runtime-rust/README.md` §"Rust vs Go — divergent strategies"
//! for why Rust takes the separate-process path Go abandoned (Go's subprocess
//! OOM was a *runtime* `go build`, which a pre-built binary doesn't incur).
//!
//! This module (Task 1): gate + spawn + lifecycle. The reverse-proxy handler and
//! the Live-boot wiring land in Tasks 2–3.
//!
//! No panic vectors: a missing binary / spawn failure / disabled gate returns
//! `None` so the caller falls back to the in-process console; no `unwrap`.

use std::sync::Mutex;
use tokio::process::{Child, Command};

/// Override for the pre-built console binary path. When unset, the cache path
/// (`~/.cache/sky/rust-console/<sky-version>/sky-console`, written by A1) is used.
const CONSOLE_BIN_ENV: &str = "SKY_CONSOLE_BIN";

/// The spawned console child, tracked so the parent can kill it on shutdown
/// (Go's `ShutdownSubApps` equivalent — Go deleted it when it went in-process;
/// the separate-process Rust path needs it back to avoid an orphan child).
static CHILD: Mutex<Option<Child>> = Mutex::new(None);

/// Resolve the pre-built console binary path: `SKY_CONSOLE_BIN`, else the
/// version-keyed cache path A1 populates. `None` when neither exists (→ the
/// caller falls back to the in-process console; first build before A1 lands, or
/// a build env where the console couldn't be pre-built).
pub fn console_bin_path() -> Option<std::path::PathBuf> {
    if let Ok(p) = std::env::var(CONSOLE_BIN_ENV) {
        if !p.is_empty() {
            let pb = std::path::PathBuf::from(p);
            return if pb.is_file() { Some(pb) } else { None };
        }
    }
    let ver = env!("CARGO_PKG_VERSION");
    let home = std::env::var("HOME").ok()?;
    let pb = std::path::Path::new(&home)
        .join(".cache/sky/rust-console")
        .join(ver)
        .join("sky-console");
    if pb.is_file() {
        Some(pb)
    } else {
        None
    }
}

/// Boot-time decision: should the console child be spawned + mounted at all?
/// Mirrors Go `MountEmbeddedConsole`'s skip conditions (console.go:257).
/// `false` → the caller skips the proxy (and may mount the in-process console or
/// nothing, per its own gate).
pub fn gate_allows() -> bool {
    // Sub-app context: the parent owns its own console; a nested app must not
    // recursively mount one.
    if std::env::var("SKY_LIVE_BASE_PATH").map(|v| !v.is_empty()).unwrap_or(false) {
        return false;
    }
    // Explicit opt-outs.
    if matches!(
        std::env::var("SKY_CONSOLE_EMBED").as_deref(),
        Ok("off") | Ok("0") | Ok("false")
    ) {
        return false;
    }
    if std::env::var("SKY_CONSOLE_AUTH").map(|v| v == "off").unwrap_or(false) {
        return false;
    }
    // Production without an admin token → no silent open-to-the-world mount.
    if super::super::telemetry::production_from_env()
        && std::env::var("SKY_ADMIN_TOKEN").map(|v| v.is_empty()).unwrap_or(true)
        && std::env::var("SKY_CONSOLE_TOKEN").map(|v| v.is_empty()).unwrap_or(true)
    {
        return false;
    }
    true
}

/// Spawn the pre-built console child on `child_port`, pointing it at the spill
/// (`hub_db`, the parent's `SKY_CONSOLE_DB_PATH`). Returns `Some(())` on a
/// successful spawn (the `Child` is tracked in `CHILD`); `None` when the binary
/// is absent or the spawn fails — the caller falls back to the in-process
/// console. `kill_on_drop` + `shutdown_console` ensure no orphan.
pub fn spawn_console(child_port: u16, hub_db: &str) -> Option<()> {
    let bin = console_bin_path()?;
    let mut cmd = Command::new(&bin);
    cmd.env("SKY_LIVE_PORT", child_port.to_string())
        .env("SKY_LIVE_BASE_PATH", "/_sky/console")
        // The console reads its data plane from SKY_CONSOLE_HUB_DB (→ hubStore);
        // wire it to the parent's spill so D→S1→A is one loop.
        .env("SKY_CONSOLE_HUB_DB", hub_db)
        // Belt-and-braces: suppress the child's own console auto-mount + banner.
        .env("SKY_CONSOLE_EMBED", "off")
        .kill_on_drop(true);
    if hub_db.is_empty() {
        cmd.env_remove("SKY_CONSOLE_HUB_DB");
    }
    match cmd.spawn() {
        Ok(child) => {
            if let Ok(mut g) = CHILD.lock() {
                *g = Some(child);
            }
            eprintln!("[sky.console] spawned console child on :{child_port} (bin {})", bin.display());
            Some(())
        }
        Err(e) => {
            eprintln!("[sky.console] spawn failed ({e}); falling back to in-process console");
            None
        }
    }
}

/// Kill the tracked console child (parent shutdown). Idempotent; never panics.
pub fn shutdown_console() {
    if let Ok(mut g) = CHILD.lock() {
        if let Some(child) = g.as_mut() {
            let _ = child.start_kill();
        }
        *g = None;
    }
}

/// Install a best-effort signal handler that kills the console child on
/// SIGINT/SIGTERM, so the child dies with the parent even though the Live server
/// has no graceful-shutdown hook of its own. Spawned once at mount time.
pub fn install_shutdown_hook() {
    tokio::spawn(async {
        #[cfg(unix)]
        {
            use tokio::signal::unix::{signal, SignalKind};
            let mut term = match signal(SignalKind::terminate()) {
                Ok(s) => s,
                Err(_) => return,
            };
            let mut intr = match signal(SignalKind::interrupt()) {
                Ok(s) => s,
                Err(_) => return,
            };
            tokio::select! {
                _ = term.recv() => {}
                _ = intr.recv() => {}
            }
            shutdown_console();
        }
        #[cfg(not(unix))]
        {
            let _ = tokio::signal::ctrl_c().await;
            shutdown_console();
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gate_skips_in_subapp_context() {
        std::env::set_var("SKY_LIVE_BASE_PATH", "/billing");
        assert!(!gate_allows());
        std::env::remove_var("SKY_LIVE_BASE_PATH");
    }

    #[test]
    fn gate_skips_on_explicit_off() {
        std::env::set_var("SKY_CONSOLE_EMBED", "off");
        assert!(!gate_allows());
        std::env::remove_var("SKY_CONSOLE_EMBED");
    }

    #[test]
    fn bin_path_none_when_absent() {
        std::env::set_var(CONSOLE_BIN_ENV, "/nonexistent/sky-console-xyz");
        assert!(console_bin_path().is_none());
        std::env::remove_var(CONSOLE_BIN_ENV);
    }

    #[test]
    fn spawn_returns_none_without_binary() {
        // No binary at the override path → None (caller falls back), no panic.
        std::env::set_var(CONSOLE_BIN_ENV, "/nonexistent/sky-console-xyz");
        assert!(spawn_console(9931, "").is_none());
        std::env::remove_var(CONSOLE_BIN_ENV);
    }

    #[test]
    fn shutdown_is_idempotent_noop_when_empty() {
        shutdown_console();
        shutdown_console();
    }
}
