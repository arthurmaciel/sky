#!/usr/bin/env node
// Rust-backend live/web verification driver — the browser round-trip the
// /web-sweep skill drives (its curl-only sibling /run-sweep only
// proves the server boots + serves HTML on `/`). This launches a real
// headless browser, replays the repo's maintained per-example scenario
// (scripts/verify-scenarios.mjs — same ones the Go backend uses, since the
// Sky.Live wire protocol is backend-identical), and HARD-FAILS the
// "click is a no-op" class: a scenario click that never POSTs /_sky/event.
//
// Usage:
//   node web-verify.mjs <example-name> <port> <scenario> <rust-binary>
//
// Differences from scripts/verify-live-app.mjs (which we deliberately do NOT
// edit — it's a shared Go-backend script, out of the Rust boundary):
//   • spawns the RUST binary passed as argv[4] (not examples/<name>/sky-out/app)
//   • launches SYSTEM chromium (executablePath + --no-sandbox) because this
//     host has no bundled Playwright browser
//   • panic patterns are Rust-shaped (panicked / RUST_BACKTRACE / unwrap …)
//
// Exit 0 = PASS, non-zero = FAIL (machine-readable `PASS `/`FAIL ` first token).

import { chromium } from 'playwright';
import { spawn } from 'child_process';
import fs from 'fs';
import path from 'path';
import net from 'net';
import { fileURLToPath, pathToFileURL } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname  = path.dirname(__filename);
// runtime-rust/scripts → runtime-rust → repo root
const repoRoot   = path.resolve(__dirname, '..', '..');

const exampleName  = process.argv[2];
const port         = parseInt(process.argv[3] || '8000', 10);
const scenarioName = process.argv[4] || 'smoke';
const binary       = process.argv[5];

if (!exampleName || !binary) {
    console.error('usage: node web-verify.mjs <example-name> <port> <scenario> <rust-binary>');
    process.exit(2);
}
if (!fs.existsSync(binary)) {
    console.error(`FAIL ${exampleName} — rust binary missing: ${binary}`);
    process.exit(2);
}

// System chromium — this host has no ~/.cache/ms-playwright bundled browser.
const CHROME = process.env.SKY_CHROMIUM || '/usr/bin/chromium';

const exampleDir  = path.join(repoRoot, 'examples', exampleName);
const artefactDir = path.join(repoRoot, '.skycache', 'verify-rust', exampleName);
fs.mkdirSync(artefactDir, { recursive: true });

function waitForPort(p, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    return new Promise((resolve, reject) => {
        const tick = () => {
            if (Date.now() > deadline) { reject(new Error(`port ${p} never accepted within ${timeoutMs}ms`)); return; }
            const sock = net.connect(p, '127.0.0.1');
            sock.on('connect', () => { sock.end(); resolve(); });
            sock.on('error', () => { setTimeout(tick, 200); });
        };
        tick();
    });
}

const RUST_PANIC_RE = [
    /panicked/i,
    /RUST_BACKTRACE/,
    /index out of bounds/i,
    /unwrap\(\) on/i,
    /called `Result::unwrap/i,
    /CompilerBug/,
];

async function main() {
    const env = { ...process.env, PORT: String(port), SKY_LIVE_PORT: String(port), SKY_CONSOLE_EMBED: 'off' };
    const serverLogPath = path.join(artefactDir, 'server.log');
    const serverLog = fs.createWriteStream(serverLogPath);
    const child = spawn(binary, [], { env, cwd: exampleDir });
    child.stdout.pipe(serverLog);
    child.stderr.pipe(serverLog);

    let exitedEarly = null;
    child.on('exit', (code, signal) => {
        if (signal !== 'SIGTERM' && signal !== 'SIGKILL') exitedEarly = { code, signal };
    });

    try {
        await waitForPort(port, 12_000);
    } catch (err) {
        child.kill('SIGKILL');
        await new Promise(r => setTimeout(r, 200));
        console.error(`FAIL ${exampleName} — server failed to listen: ${err.message}`);
        console.error(fs.readFileSync(serverLogPath, 'utf8').split('\n').slice(0, 40).join('\n'));
        process.exit(1);
    }
    if (exitedEarly) {
        console.error(`FAIL ${exampleName} — server exited early: code=${exitedEarly.code} signal=${exitedEarly.signal}`);
        console.error(fs.readFileSync(serverLogPath, 'utf8'));
        process.exit(1);
    }

    let browser;
    try {
        browser = await chromium.launch({ headless: true, executablePath: CHROME, args: ['--no-sandbox'] });
    } catch (err) {
        child.kill('SIGKILL');
        console.error(`FAIL ${exampleName} — chromium launch failed (${CHROME}): ${err.message}`);
        process.exit(1);
    }
    const context = await browser.newContext({ viewport: { width: 1280, height: 720 } });
    const page = await context.newPage();

    const consoleErrors = [];
    page.on('console', msg => { if (msg.type() === 'error') consoleErrors.push(msg.text()); });
    page.on('pageerror', err => consoleErrors.push(`pageerror: ${err.message}`));

    // Track 4xx/5xx resource URLs so a generic "Failed to load resource"
    // console error can be classified by WHAT failed. A favicon.ico 404 (every
    // browser auto-requests it; an app shipping none returns 404) or a
    // dev-console-plumbing 404 is benign — and crucially it can differ between
    // the Go backend (injects the /_sky/console link) and the Rust backend
    // (console federation staged) WITHOUT being an app-behaviour divergence.
    // The scenario must assert APP behaviour, not console/asset plumbing.
    const BENIGN_URL_RE = /(favicon\.ico|robots\.txt|apple-touch-icon|manifest\.json|sitemap\.xml|\/_sky\/console)/i;
    const nonBenignFailedUrls = [];
    page.on('response', resp => {
        if (resp.status() >= 400 && !BENIGN_URL_RE.test(resp.url())) {
            nonBenignFailedUrls.push(`${resp.status()} ${resp.url()}`);
        }
    });

    // "click is a no-op" probe — watch every /_sky/event POST. The scenario's
    // expectSkyEventAfter() asserts at least one round-trip fired.
    const skyEventPosts = [];
    page.on('request', req => {
        if (req.method() === 'POST' && req.url().includes('/_sky/event')) {
            skyEventPosts.push({ url: req.url(), postData: req.postData() || '', ts: Date.now() });
        }
    });

    let outcome = 'PASS';
    let detail = '';
    try {
        const baseUrl = `http://127.0.0.1:${port}`;
        // domcontentloaded, NOT networkidle — the SSE channel never goes idle.
        await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 12_000 });

        const pause = (ms) => page.waitForTimeout(ms);
        const scenarioMod = await import(pathToFileURL(path.join(repoRoot, 'scripts', 'verify-scenarios.mjs')).href);
        const scenarios = scenarioMod.scenarios || scenarioMod.default;
        const scenarioFn = scenarios[scenarioName];
        if (typeof scenarioFn !== 'function') {
            throw new Error(`unknown scenario: ${scenarioName} (known: ${Object.keys(scenarios).join(', ')})`);
        }
        await scenarioFn(page, { baseUrl, pause, skyEventPosts });

        await page.screenshot({ path: path.join(artefactDir, 'home.png'), fullPage: false }).catch(() => {});

        // Structural gate — interactive UI MUST carry sky-event attributes.
        const homeHtml = await page.content();
        if (/<button|<form/i.test(homeHtml) && !/sky-(click|input|change|submit)="/i.test(homeHtml)) {
            outcome = 'FAIL';
            detail = 'rendered HTML has <button>/<form> but ZERO sky-event attributes — events stripped at render time';
        }

        // A console error is benign when its text names a benign asset OR it is
        // the generic "Failed to load resource" 404 string with NO corresponding
        // non-benign failed URL (i.e. the only thing that 404'd was a favicon /
        // console-plumbing asset). This makes the gate robust to the by-design
        // Go-vs-Rust console/asset divergence while still catching a real broken
        // app resource (a missing JS/CSS the app actually needs).
        const benignRe = /(favicon\.ico|robots\.txt|apple-touch-icon|manifest\.json|sitemap\.xml|\/_sky\/console)/i;
        const genericLoadFailRe = /Failed to load resource/i;
        const realErrors = consoleErrors.filter(e => {
            if (benignRe.test(e)) return false;
            // Generic load-failure with nothing non-benign actually failing → benign.
            if (genericLoadFailRe.test(e) && nonBenignFailedUrls.length === 0) return false;
            return true;
        });
        if (realErrors.length > 0 && outcome === 'PASS') {
            outcome = 'FAIL';
            detail = `console errors: ${realErrors.slice(0, 5).join('; ')}`
                   + (nonBenignFailedUrls.length ? ` | failed: ${nonBenignFailedUrls.slice(0, 3).join(', ')}` : '');
        }
    } catch (err) {
        outcome = 'FAIL';
        detail = `playwright: ${err.message}`;
        await page.screenshot({ path: path.join(artefactDir, 'error.png'), fullPage: false }).catch(() => {});
    }

    await browser.close();
    child.kill('SIGTERM');
    await new Promise(r => setTimeout(r, 500));
    if (!child.killed) child.kill('SIGKILL');

    // Rust-panic grep on the server log (mirror of the Go driver's panic tail).
    const log = fs.readFileSync(serverLogPath, 'utf8');
    const panics = RUST_PANIC_RE.flatMap(re => { const m = log.match(re); return m ? [m[0]] : []; });
    if (panics.length > 0) {
        outcome = 'FAIL';
        detail = (detail ? detail + '; ' : '') + 'server panics: ' + panics.join(', ');
    }

    if (outcome === 'PASS') {
        console.log(`PASS ${exampleName} (port ${port}, scenario ${scenarioName}, ${skyEventPosts.length} sky-event POST)`);
        process.exit(0);
    }
    console.error(`FAIL ${exampleName} — ${detail}`);
    console.error('artefacts in ' + artefactDir);
    console.error('--- last 30 lines of server.log ---');
    console.error(log.split('\n').slice(-30).join('\n'));
    process.exit(1);
}

main().catch(err => {
    console.error('FAIL ' + exampleName + ' — driver error: ' + err.message);
    console.error(err.stack);
    process.exit(1);
});
