#!/usr/bin/env node
// v0.13.x runtime verification driver for Sky.Live / Sky.Http.Server apps.
//
// Usage:
//   node scripts/verify-live-app.mjs <example-name> [port] [scenario-name]
//
//   example-name   directory under examples/ (e.g. 09-live-counter)
//   port           HTTP port (default: 8000)
//   scenario-name  optional named scenario (default: "smoke" — load home + screenshot)
//
// Pipeline:
//   1. Spawn `examples/<name>/sky-out/app` with PORT=<port> in env.
//   2. Wait for the server to accept connections on <port>.
//   3. Launch Playwright (headless Chromium), open the home page.
//   4. Run the scenario (default: load + verify no console errors).
//   5. Capture a screenshot (and a trace, if `SKY_TRACE=1`).
//   6. Tail server stderr for `panic` / `runtime error`.
//   7. Kill server, report PASS/FAIL.
//
// Exits 0 on pass, non-zero on any failure.

import { chromium } from 'playwright';
import { spawn } from 'child_process';
import fs from 'fs';
import path from 'path';
import net from 'net';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname  = path.dirname(__filename);
const repoRoot   = path.resolve(__dirname, '..');

const exampleName  = process.argv[2];
const port         = parseInt(process.argv[3] || '8000', 10);
const scenarioName = process.argv[4] || 'smoke';

if (!exampleName) {
    console.error('usage: node verify-live-app.mjs <example-name> [port] [scenario]');
    process.exit(2);
}

const exampleDir = path.join(repoRoot, 'examples', exampleName);
const binary     = path.join(exampleDir, 'sky-out', 'app');

if (!fs.existsSync(binary)) {
    console.error(`binary missing: ${binary}`);
    console.error('build first: cd examples/' + exampleName + ' && sky build src/Main.sky');
    process.exit(2);
}

// Output artefacts
const artefactDir = path.join(repoRoot, '.skycache', 'verify', exampleName);
fs.mkdirSync(artefactDir, { recursive: true });

// ─── Helpers ────────────────────────────────────────────────────────

function waitForPort(p, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    return new Promise((resolve, reject) => {
        const tick = () => {
            if (Date.now() > deadline) {
                reject(new Error(`port ${p} never accepted within ${timeoutMs}ms`));
                return;
            }
            const sock = net.connect(p, '127.0.0.1');
            sock.on('connect', () => { sock.end(); resolve(); });
            sock.on('error', () => { setTimeout(tick, 200); });
        };
        tick();
    });
}

async function main() {
    // Spawn server
    const env = { ...process.env, PORT: String(port), SKY_LIVE_PORT: String(port) };
    const serverLogPath = path.join(artefactDir, 'server.log');
    const serverLog = fs.createWriteStream(serverLogPath);
    const child = spawn(binary, [], { env, cwd: exampleDir });
    child.stdout.pipe(serverLog);
    child.stderr.pipe(serverLog);

    let serverExitedEarly = null;
    child.on('exit', (code, signal) => {
        if (signal !== 'SIGTERM' && signal !== 'SIGKILL') {
            serverExitedEarly = { code, signal };
        }
    });

    try {
        await waitForPort(port, 10_000);
    } catch (err) {
        child.kill('SIGKILL');
        // Wait for logs to flush
        await new Promise(r => setTimeout(r, 200));
        const log = fs.readFileSync(serverLogPath, 'utf8');
        console.error(`FAIL ${exampleName} — server failed to listen: ${err.message}`);
        console.error('--- server log ---');
        console.error(log.split('\n').slice(0, 40).join('\n'));
        process.exit(1);
    }

    if (serverExitedEarly) {
        console.error(`FAIL ${exampleName} — server exited early: code=${serverExitedEarly.code} signal=${serverExitedEarly.signal}`);
        console.error(fs.readFileSync(serverLogPath, 'utf8'));
        process.exit(1);
    }

    // Playwright
    const browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({
        viewport: { width: 1280, height: 720 },
        recordVideo: process.env.SKY_RECORD ? { dir: artefactDir } : undefined,
    });
    if (process.env.SKY_TRACE) {
        await context.tracing.start({ screenshots: true, snapshots: true });
    }
    const page = await context.newPage();

    const consoleErrors = [];
    page.on('console', msg => {
        if (msg.type() === 'error') consoleErrors.push(msg.text());
    });
    page.on('pageerror', err => consoleErrors.push(`pageerror: ${err.message}`));

    let outcome = 'PASS';
    let detail = '';
    try {
        const baseUrl = `http://127.0.0.1:${port}`;

        // Default smoke scenario: load home, screenshot, ensure no console error.
        await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 10_000 });
        await page.waitForLoadState('networkidle', { timeout: 5_000 }).catch(() => {});

        // Scenario-specific interactions
        if (scenarioName === 'smoke') {
            // Just verify the home page renders SOMETHING.
            const bodyText = await page.locator('body').innerText();
            if (!bodyText || bodyText.trim().length === 0) {
                throw new Error('home page rendered empty body');
            }
        } else if (scenarioName === 'live-counter') {
            // Click increment, observe counter advance, click decrement.
            const before = await page.locator('body').innerText();
            const incBtn = page.locator('button:has-text("+"), button:has-text("Increment"), [data-action="increment"]').first();
            if (await incBtn.count() > 0) {
                await incBtn.click();
                await page.waitForTimeout(300);
                const after = await page.locator('body').innerText();
                if (before === after) {
                    throw new Error('counter did not change after increment click');
                }
            }
        }

        await page.screenshot({ path: path.join(artefactDir, 'home.png'), fullPage: false });

        if (consoleErrors.length > 0) {
            outcome = 'FAIL';
            detail = `console errors: ${consoleErrors.slice(0, 5).join('; ')}`;
        }
    } catch (err) {
        outcome = 'FAIL';
        detail = `playwright: ${err.message}`;
        await page.screenshot({ path: path.join(artefactDir, 'error.png'), fullPage: false }).catch(() => {});
    }

    if (process.env.SKY_TRACE) {
        await context.tracing.stop({ path: path.join(artefactDir, 'trace.zip') });
    }
    await browser.close();

    // Kill server gracefully
    child.kill('SIGTERM');
    await new Promise(r => setTimeout(r, 500));
    if (!child.killed) child.kill('SIGKILL');

    // Tail server log for panic / runtime error
    const log = fs.readFileSync(serverLogPath, 'utf8');
    const panicPatterns = [
        /panic:/i,
        /runtime error:/i,
        /goroutine \d+ \[/,  // any goroutine stack trace
        /interface conversion:/,
    ];
    const panics = panicPatterns.flatMap(re => {
        const m = log.match(re);
        return m ? [m[0]] : [];
    });
    if (panics.length > 0) {
        outcome = 'FAIL';
        detail = (detail ? detail + '; ' : '') + 'server panics: ' + panics.join(', ');
    }

    if (outcome === 'PASS') {
        console.log(`PASS ${exampleName} (port ${port}, scenario ${scenarioName})`);
        process.exit(0);
    } else {
        console.error(`FAIL ${exampleName} — ${detail}`);
        console.error('artefacts in ' + artefactDir);
        console.error('--- last 30 lines of server.log ---');
        console.error(log.split('\n').slice(-30).join('\n'));
        process.exit(1);
    }
}

main().catch(err => {
    console.error('FAIL ' + exampleName + ' — driver error: ' + err.message);
    console.error(err.stack);
    process.exit(1);
});
