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
    /// Find all occurrences of a symbol name across the index.
    Locate {
        name: String,
        #[arg(long, default_value = ".skydex/index.db")]
        db: String,
    },
    /// Reverse dependencies: files/modules that import a given module or path.
    Rdeps {
        module: String,
        #[arg(long, default_value = ".skydex/index.db")]
        db: String,
        #[arg(long)]
        count: bool,
        /// Also match submodules (e.g. `Sky.Core.List` also matches `Sky.Core.List.Foo`).
        #[arg(long)]
        subtree: bool,
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
    // `index` builds from scratch. The non-PK `symbols`/`edges` tables would
    // accumulate duplicate rows across re-index if opened against a stale DB, so
    // fail loudly if an existing DB can't be removed (NotFound on first run is
    // expected and ignored).
    match std::fs::remove_file(db) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(anyhow::anyhow!("cannot remove stale index db {db}: {e}")),
    }
    let store = store::Store::open(db)?;
    store.begin()?;
    let files = walk::tracked(repo)?;
    // Collect Go/Rust fn symbols for parity + accumulate Kernel.hs route source.
    // Bounded: one file's contents at a time; the parity inputs are small name sets.
    let mut go_fns: HashSet<String> = HashSet::new();
    let mut rust_fns: HashSet<String> = HashSet::new();
    // Ffi.kernel names declared in sky-stdlib (e.g. "Set_insert", "Dict_union").
    // A kernel in this set is a REAL Rust gap when Go has an impl but Rust does not.
    // Bounded: ~393 names from sky-stdlib, one short string each.
    let mut sky_kernel_decls: HashSet<String> = HashSet::new();
    // Vec of (relative_path, source) for all Kernel.hs files found.
    let mut kernel_hs_sources: Vec<(String, String)> = Vec::new();
    for f in &files {
        let Some(src) = read_capped(repo, &f.path) else {
            continue;
        };
        store.put_file(&f.path, f.lang.as_str(), f.role.as_str(), src.len() as i64, "")?;
        extract::extract_file(&store, &f.path, f.lang, &src)?;
        pipeline::record_stage(&store, &f.path)?;
        // Parity inputs.
        if f.path.ends_with("Kernel.hs") {
            kernel_hs_sources.push((f.path.clone(), src.clone()));
        }
        if f.lang == model::Lang::Go {
            for c in extract::treesitter_defs(&src, model::Lang::Go) {
                go_fns.insert(c);
            }
            // Kernels registered via string literals (e.g. RegisterPure("Decimal_add", ...))
            // are invisible to tree-sitter (the closure is anonymous). Line-scan them
            // separately and union into go_fns so parity reconcile sees them.
            for (name, _line) in extract::go_registered_kernels(&src) {
                go_fns.insert(name);
            }
        }
        if f.lang == model::Lang::Rust {
            for c in extract::treesitter_defs(&src, model::Lang::Rust) {
                rust_fns.insert(c);
            }
        }
        // Collect Ffi.kernel declarations from sky-stdlib source files.
        // These are the kernels any Sky program routes at the runtime level —
        // if Go has an impl but Rust doesn't, it's a REAL gap only for these.
        if f.role == model::Role::StdlibSky {
            let scan = extract::sky::scan_sky(&src);
            for kernel_name in scan.kernels {
                sky_kernel_decls.insert(kernel_name);
            }
        }
        if f.role == model::Role::Fixture || f.role == model::Role::Example {
            coverage::record_coverage(&store, &f.path, &src)?;
        }
        // `src` and any per-file tree are dropped here before the next file.
    }
    // Parity reconcile over the whole repo's kernel tables + Go/Rust symbol sets.
    let pairs: Vec<(&str, &str)> = kernel_hs_sources.iter().map(|(p, s)| (p.as_str(), s.as_str())).collect();
    let routes = parity::parse_routes_with_locs(&pairs);
    for k in parity::reconcile_with_locs(&routes, &go_fns, &rust_fns, &sky_kernel_decls) {
        // Look up go_impl_loc and rust_impl_loc from the symbols table, using
        // language-aware lookup so we never return a Go test file as a Rust loc
        // or vice versa.  Only emit a loc when the matching impl boolean is true —
        // a loc for a missing impl would contradict its own parity row.
        let go_impl_loc = if k.go_impl {
            lookup_sym_loc_lang(&store, &k.name.replace('.', "_"), "go")?
        } else {
            None
        };
        let rust_impl_loc = if k.rust_impl {
            lookup_sym_loc_lang(&store, &k.rust_fn, "rs")?
        } else {
            None
        };
        store.conn.execute(
            "INSERT OR REPLACE INTO kernels VALUES (?,?,?,?,?,?,?,?,?)",
            rusqlite::params![
                k.name, k.sky_decl as i64, k.rust_fn,
                k.hs_route_loc.as_deref(),
                k.go_impl as i64, k.rust_impl as i64,
                go_impl_loc, rust_impl_loc,
                k.parity
            ],
        )?;
    }
    // Resolution pass: populate edges.resolved for import edges.
    query::resolve_edges(&store, repo)?;
    store.set_meta("last_sha", &walk::head_sha(repo)?)?;
    store.commit()?;
    eprintln!("skydex: indexed {} files", files.len());
    Ok(())
}

/// Look up `"file:line"` for the first `def` symbol matching `name` in `lang`,
/// excluding test and example files.
fn lookup_sym_loc_lang(store: &store::Store, name: &str, lang: &str) -> Result<Option<String>> {
    let hits = store.symbols_named_in_lang(name, lang)?;
    Ok(hits.into_iter()
        .map(|(file, line, _)| format!("{file}:{line}"))
        .next())
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
        Cmd::Locate { name, db } => query::cmd_locate(&db, &name),
        Cmd::Rdeps { module, db, count, subtree } => query::cmd_rdeps(&db, &module, count, subtree),
    }
}
