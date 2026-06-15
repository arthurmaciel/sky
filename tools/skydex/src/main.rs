mod coverage;
mod extract;
mod model;
mod parity;
mod pipeline;
mod query;
mod store;
mod walk;

use anyhow::Result;
use clap::{Parser, Subcommand};
use std::collections::HashSet;

#[derive(Parser)]
#[command(name = "skydex", version)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Build the index from scratch.
    Index {
        #[arg(long, default_value = ".")]
        repo: String,
        #[arg(long, default_value = ".skydex/index.db")]
        db: String,
    },
    /// Incrementally refresh the index from the git diff since the last index.
    Update {
        #[arg(long, default_value = ".")]
        repo: String,
        #[arg(long, default_value = ".skydex/index.db")]
        db: String,
    },
    /// Cross-language kernel parity (Go vs Rust impls of Sky kernels).
    Parity {
        #[arg(long, default_value = ".skydex/index.db")]
        db: String,
        #[arg(long)]
        gaps: bool,
    },
    /// Import dependencies of a module (substring match).
    Deps {
        module: String,
        #[arg(long, default_value = ".skydex/index.db")]
        db: String,
    },
    /// File counts per role.
    Roles {
        #[arg(long, default_value = ".skydex/index.db")]
        db: String,
    },
    /// Compiler-stage module counts.
    Pipeline {
        #[arg(long, default_value = ".skydex/index.db")]
        db: String,
    },
    /// Fixtures/examples covering a kernel/module (substring match).
    Covers {
        kernel: String,
        #[arg(long, default_value = ".skydex/index.db")]
        db: String,
    },
    /// One-screen digest of the index.
    Wakeup {
        #[arg(long, default_value = ".skydex/index.db")]
        db: String,
    },
}

fn read_capped(repo: &str, rel: &str) -> Option<String> {
    let p = std::path::Path::new(repo).join(rel);
    let md = std::fs::metadata(&p).ok()?;
    if md.len() > walk::MAX_FILE_BYTES {
        eprintln!("skydex: skipping oversized {rel} ({} bytes)", md.len());
        return None;
    }
    std::fs::read_to_string(&p).ok()
}

fn cmd_index(repo: &str, db: &str) -> Result<()> {
    if let Some(parent) = std::path::Path::new(db).parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).ok();
        }
    }
    let _ = std::fs::remove_file(db);
    let store = store::Store::open(db)?;
    store.begin()?;
    let files = walk::tracked(repo)?;
    // Collect Go/Rust fn symbols for parity + accumulate Kernel.hs route source.
    // Bounded: one file's contents at a time; the parity inputs are small name sets.
    let mut go_fns: HashSet<String> = HashSet::new();
    let mut rust_fns: HashSet<String> = HashSet::new();
    let mut hs_kernel_src = String::new();
    for f in &files {
        let Some(src) = read_capped(repo, &f.path) else {
            continue;
        };
        store.put_file(&f.path, f.lang.as_str(), f.role.as_str(), src.len() as i64, "")?;
        extract::extract_file(&store, &f.path, f.lang, &src)?;
        pipeline::record_stage(&store, &f.path)?;
        // Parity inputs.
        if f.path.ends_with("Kernel.hs") {
            hs_kernel_src.push_str(&src);
            hs_kernel_src.push('\n');
        }
        if f.lang == model::Lang::Go {
            for c in extract::treesitter_defs(&src, model::Lang::Go) {
                go_fns.insert(c);
            }
        }
        if f.lang == model::Lang::Rust {
            for c in extract::treesitter_defs(&src, model::Lang::Rust) {
                rust_fns.insert(c);
            }
        }
        if f.role == model::Role::Fixture || f.role == model::Role::Example {
            coverage::record_coverage(&store, &f.path, &src)?;
        }
        // `src` and any per-file tree are dropped here before the next file.
    }
    // Parity reconcile over the whole repo's kernel tables + Go/Rust symbol sets.
    let routes = parity::parse_routes(&hs_kernel_src);
    for k in parity::reconcile(&routes, &go_fns, &rust_fns) {
        store.conn.execute(
            "INSERT OR REPLACE INTO kernels VALUES (?,?,?,?,?,?)",
            rusqlite::params![k.name, 1, k.rust_fn, k.go_impl as i64, k.rust_impl as i64, k.parity],
        )?;
    }
    store.set_meta("last_sha", &walk::head_sha(repo)?)?;
    store.commit()?;
    eprintln!("skydex: indexed {} files", files.len());
    Ok(())
}

/// Cold-fallback entry for `update` when there is no prior index.
pub fn cmd_index_pub(repo: &str, db: &str) -> Result<()> {
    cmd_index(repo, db)
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Index { repo, db } => cmd_index(&repo, &db),
        Cmd::Update { repo, db } => query::cmd_update(&repo, &db),
        Cmd::Parity { db, gaps } => query::cmd_parity(&db, gaps),
        Cmd::Deps { module, db } => query::cmd_deps(&db, &module),
        Cmd::Roles { db } => query::cmd_roles(&db),
        Cmd::Pipeline { db } => query::cmd_pipeline(&db),
        Cmd::Covers { kernel, db } => query::cmd_covers(&db, &kernel),
        Cmd::Wakeup { db } => query::cmd_wakeup(&db),
    }
}
