use clap::Parser;
use sse_bench::{run_session, Summary};
use std::time::Instant;

#[derive(Parser)]
struct Args {
    #[arg(long)] url: String,
    #[arg(long, default_value_t = 2000)] events: usize,
    #[arg(long, default_value_t = 16)] concurrency: usize,
}

#[tokio::main]
async fn main() {
    let args = Args::parse();
    let per = args.events.div_ceil(args.concurrency.max(1)); // ceil
    let start = Instant::now();
    let mut handles = Vec::new();
    for _ in 0..args.concurrency {
        let url = args.url.clone();
        handles.push(tokio::spawn(async move { run_session(&url, per).await }));
    }
    let mut all = Vec::new();
    for h in handles {
        match h.await {
            Ok(Ok(mut v)) => all.append(&mut v),
            Ok(Err(e)) => { eprintln!("session error: {e}"); std::process::exit(1); }
            Err(e) => { eprintln!("join error: {e}"); std::process::exit(1); }
        }
    }
    let wall = start.elapsed().as_secs_f64();
    println!("{}", Summary::from_latencies_ms(&all, wall).to_json());
}
