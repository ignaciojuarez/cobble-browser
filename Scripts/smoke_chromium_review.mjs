#!/usr/bin/env node

// Run an isolated Chromium-in-Cobble review smoke and 0/1/2-tab startup samples.
// This uses CDP only for renderer assertions; it is not native input, IME, or
// accessibility automation.
import { randomUUID } from "node:crypto";
import { execFile, execFileSync, spawn } from "node:child_process";
import { constants } from "node:fs";
import { access, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";

const wait = (milliseconds) => new Promise((done) => setTimeout(done, milliseconds));
const fail = (message) => { throw new Error(message); };
const LAUNCH_FLAGS = ["--remote-debugging-port=0", "--remote-debugging-address=127.0.0.1", "--use-mock-keychain", "--noerrdialogs", "--no-first-run", "--disable-background-networking", "--disable-component-update", "--disable-sync", "--no-pings", "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1, EXCLUDE localhost"];

function options() {
  const values = process.argv.slice(2);
  const result = { tabs: [], timeout: 30_000 };
  for (let index = 0; index < values.length; index++) {
    const value = values[index];
    if (["--app", "--artifacts", "--sdk", "--tabs", "--timeout-ms"].includes(value)) {
      const next = values[++index];
      if (!next) fail(`${value} requires a value`);
      if (value === "--app") result.app = resolve(next);
      else if (value === "--artifacts") result.artifacts = resolve(next);
      else if (value === "--sdk") result.sdk = resolve(next);
      else if (value === "--timeout-ms") result.timeout = Number(next);
      else {
        result.tabs = [...new Set(next.split(",").map(Number))];
        if (!result.tabs.length || result.tabs.some((count) => !Number.isInteger(count) || count < 0 || count > 2)) {
          fail("--tabs must be a nonempty subset of 0,1,2");
        }
      }
    } else if (value === "--skip-smoke") result.skipSmoke = true;
    else fail(`Unknown option: ${value}`);
  }
  if (!result.app || !result.artifacts || !result.sdk) {
    fail("Usage: node Scripts/smoke_chromium_review.mjs --app <Cobble.app> --artifacts <directory> --sdk <cobble-chromium-sdk> [--tabs 0,1,2] [--timeout-ms 30000] [--skip-smoke]");
  }
  if (!Number.isInteger(result.timeout) || result.timeout < 5_000 || result.timeout > 120_000) {
    fail("--timeout-ms must be between 5000 and 120000");
  }
  return result;
}

async function poll(label, work, timeout) {
  const deadline = Date.now() + timeout;
  let lastError;
  while (Date.now() < deadline) {
    try { const value = await work(); if (value !== false && value != null) return value; }
    catch (error) { lastError = error; }
    await wait(100);
  }
  fail(`${label} timed out${lastError ? `: ${lastError.message}` : ""}`);
}

function processTree(rootPID) {
  const output = execFileSync("/bin/ps", ["-axo", "pid=,ppid=,rss=,%cpu=,comm="], { encoding: "utf8", env: { ...process.env, LC_ALL: "C" } });
  const rows = output.split("\n").flatMap((line) => {
    const match = line.match(/^\s*(\d+)\s+(\d+)\s+(\d+)\s+([0-9.]+)\s+(.+)$/);
    return match ? [{ pid: Number(match[1]), parentPID: Number(match[2]), rssKiB: Number(match[3]), cpuPercent: Number(match[4]), command: match[5] }] : [];
  });
  const ids = new Set([rootPID]);
  for (let changed = true; changed;) {
    changed = false;
    for (const row of rows) if (ids.has(row.parentPID) && !ids.has(row.pid)) { ids.add(row.pid); changed = true; }
  }
  const processes = rows.filter((row) => ids.has(row.pid));
  if (!processes.some((row) => row.pid === rootPID)) fail("Review app exited before resource sample");
  return { timestamp: new Date().toISOString(), summedRSSKiB: processes.reduce((sum, row) => sum + row.rssKiB, 0), summedCPUPercent: processes.reduce((sum, row) => sum + row.cpuPercent, 0), processes };
}

async function sampleStartupProcessTree(rootPID) {
  await wait(250);
  const samples = [];
  for (let index = 0; index < 3; index++) {
    samples.push(processTree(rootPID));
    if (index < 2) await wait(250);
  }
  return { sampleIntervalMs: 250, samples,
    caveat: "Raw summed RSS double-counts shared pages. ps %CPU is a decaying process average, not a 250ms interval measurement, and can retain startup work. Detached Crashpad and launchd-parented services can be outside this process group. This is an isolated startup diagnostic, not a Chromium/WebKit comparison." };
}

class CDP {
  constructor(url) { this.url = url; this.next = 0; this.pending = new Map(); }
  async connect() {
    this.socket = new WebSocket(this.url);
    this.socket.addEventListener("message", ({ data }) => {
      const reply = JSON.parse(String(data)), pending = this.pending.get(reply.id);
      if (!pending) return;
      this.pending.delete(reply.id); clearTimeout(pending.timer);
      reply.error ? pending.reject(new Error(`${pending.method}: ${reply.error.message}`)) : pending.resolve(reply.result || {});
    });
    await new Promise((resolveConnect, rejectConnect) => {
      const timer = setTimeout(() => rejectConnect(new Error("CDP connect timed out")), 5_000);
      this.socket.addEventListener("open", () => { clearTimeout(timer); resolveConnect(); }, { once: true });
      this.socket.addEventListener("error", () => { clearTimeout(timer); rejectConnect(new Error("CDP connect failed")); }, { once: true });
    });
  }
  send(method, params = {}) {
    const id = ++this.next;
    return new Promise((resolveReply, rejectReply) => {
      const timer = setTimeout(() => { this.pending.delete(id); rejectReply(new Error(`${method} timed out`)); }, 5_000);
      this.pending.set(id, { method, resolve: resolveReply, reject: rejectReply, timer });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }
  async evaluate(expression) {
    const reply = await this.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    if (reply.exceptionDetails) fail(`Page JavaScript: ${reply.exceptionDetails.text}`);
    return reply.result?.value;
  }
  close() { this.socket?.close(); }
}

async function endpoint(profile) {
  const lines = (await readFile(join(profile, "DevToolsActivePort"), "utf8")).trim().split(/\r?\n/);
  const port = Number(lines[0]);
  if (!Number.isInteger(port) || port < 1 || !lines[1]) return false;
  const version = await fetch(`http://127.0.0.1:${port}/json/version`).then((response) => response.json());
  const socket = new URL(version.webSocketDebuggerUrl); socket.hostname = "127.0.0.1";
  return { port, socket: socket.href };
}

function seedSession(urls) {
  const profileID = "00000000-0000-0000-0000-000000000001";
  const spaceID = "00000000-0000-0000-0000-000000000002";
  const tabs = urls.map((url) => ({ id: randomUUID(), spaceID, urlString: url, title: "fixture", engineID: "chromium" }));
  const windows = tabs.length ? tabs.map((tab) => ({ id: randomUUID(), profileID, selectedSpaceID: spaceID, selectedTabID: tab.id, collapsedFolderIDs: [], sidebarVisible: true, tabs: [tab] })) : [{ id: randomUUID(), profileID, selectedSpaceID: spaceID, selectedTabID: null, collapsedFolderIDs: [], sidebarVisible: true, tabs: [] }];
  return { version: 7, profiles: [{ id: profileID, name: "Default", storeBinding: { legacyDefault: {} } }], spaces: [{ id: spaceID, profileID, name: "Home" }], folders: [], savedItems: [], windows, profileEngineUsage: [], pendingProfileDeletions: [] };
}

async function terminate(child) {
  if (!child || !Number.isInteger(child.pid)) return { groupID: null, remaining: [], terminated: false };
  const groupID = child.pid;
  const members = () => execFileSync("/bin/ps", ["-axo", "pid=,pgid=,comm="], { encoding: "utf8" }).split("\n").flatMap((line) => {
    const match = line.match(/^\s*(\d+)\s+(\d+)\s+(.+)$/);
    return match && Number(match[2]) === groupID ? [{ pid: Number(match[1]), command: match[3] }] : [];
  });
  const waitForEmpty = async (milliseconds) => {
    const deadline = Date.now() + milliseconds;
    while (Date.now() < deadline && members().length) await wait(100);
    return members();
  };
  let remaining = await waitForEmpty(5_000), terminated = false;
  if (remaining.length) {
    terminated = true;
    try { process.kill(-groupID, "SIGTERM"); } catch { /* Group ended between ps and signal. */ }
    remaining = await waitForEmpty(5_000);
  }
  if (remaining.length) {
    try { process.kill(-groupID, "SIGKILL"); } catch { /* Group ended between ps and signal. */ }
    remaining = await waitForEmpty(5_000);
  }
  return { groupID, remaining, terminated };
}

async function settleLogs(logs) {
  return Promise.race([Promise.all(logs).then(() => true), wait(5_000).then(() => false)]);
}

async function launch(configuration, urls, label) {
  const run = join(configuration.artifacts, label);
  const root = await mkdtemp(join(tmpdir(), "cobble-chromium-review-"));
  const data = join(root, "cobble"), profile = join(root, "chromium");
  await mkdir(run, { recursive: true }); await mkdir(data, { recursive: true }); await mkdir(profile, { recursive: true });
  await writeFile(join(data, "session.json"), JSON.stringify(seedSession(urls)));
  const child = spawn(join(configuration.app, "Contents/MacOS/Chromium"), [`--user-data-dir=${profile}`, ...LAUNCH_FLAGS], { env: { ...process.env, COBBLE_DATA_DIRECTORY: data }, detached: true, stdio: ["ignore", "pipe", "pipe"] });
  child.once("error", (error) => { child.spawnError = error; });
  const logs = ["stdout", "stderr"].map((name, index) => new Promise((done) => {
    const chunks = [], stream = child.stdio[index + 1];
    stream.on("data", (chunk) => chunks.push(chunk));
    stream.once("end", () => writeFile(join(run, `app.${name}.log`), Buffer.concat(chunks)).finally(done));
  }));
  try {
    const devTools = await poll("DevToolsActivePort", () => {
      if (child.spawnError) throw child.spawnError;
      if (child.exitCode !== null || child.signalCode !== null) fail(`Review app exited before DevTools (${child.signalCode ?? `code ${child.exitCode}`})`);
      return endpoint(profile);
    }, configuration.timeout);
    return { run, root, data, profile, child, devTools, logs };
  } catch (error) { await terminate(child); await settleLogs(logs); await rm(root, { recursive: true, force: true }); throw error; }
}

async function closeReview(launchResult, timeout) {
  const browser = new CDP(launchResult.devTools.socket); await browser.connect();
  try { await browser.send("Browser.close"); } catch { /* Closing the socket first is normal. */ }
  browser.close();
  await poll("clean app exit", () => launchResult.child.exitCode !== null || launchResult.child.signalCode !== null, timeout);
  if (launchResult.child.exitCode !== 0 || launchResult.child.signalCode) fail(`Review app did not exit cleanly: ${launchResult.child.signalCode ?? `code ${launchResult.child.exitCode}`}`);
}

async function runBaseline(configuration, fixture, count) {
  const run = await launch(configuration, count ? Array.from({ length: count }, (_, index) => index ? fixture.pageB : fixture.pageA) : [], `baseline-${count}-tabs`);
  const expectedURLs = count ? Array.from({ length: count }, (_, index) => index ? fixture.pageB : fixture.pageA) : [];
  const result = { status: "failed", seededTabCount: count, seededWindowCount: Math.max(1, count), restoredFixtureTargetCount: null, scope: "Each seeded tab occupies a selected Cobble window; no CDP-created targets are counted as Cobble tabs." };
  try {
    if (count) await poll(`${count} restored Cobble page target${count === 1 ? "" : "s"}`, async () => {
      const targets = await fetch(`http://127.0.0.1:${run.devTools.port}/json/list`).then((response) => response.json());
      return urlsPresent(targets, expectedURLs);
    }, configuration.timeout);
    await wait(3_000);
    const targets = await fetch(`http://127.0.0.1:${run.devTools.port}/json/list`).then((response) => response.json());
    result.restoredFixtureTargetCount = targets.filter((target) => target.type === "page" && expectedURLs.includes(target.url)).length;
    result.startupProcessObservation = await sampleStartupProcessTree(run.child.pid);
    await closeReview(run, configuration.timeout); result.exit = { code: run.child.exitCode, signal: run.child.signalCode }; result.status = "passed";
  } catch (error) { result.error = error.message; }
  finally {
    result.processGroup = await terminate(run.child);
    result.logsClosed = await settleLogs(run.logs);
    if (result.status === "passed" && (result.processGroup.terminated || result.processGroup.remaining.length || !result.logsClosed)) {
      result.status = "failed";
      result.error = "Review app root exited, but its detached process group or log pipes did not close cleanly.";
    }
    await writeFile(join(run.run, "result.json"), `${JSON.stringify(result, null, 2)}\n`);
    await rm(run.root, { recursive: true, force: true });
  }
  if (result.status !== "passed") fail(`Baseline ${count} failed: ${result.error}`);
  return result;
}

function urlsPresent(targets, urls) {
  return urls.every((url) => targets.some((target) => target.type === "page" && target.url === url));
}

async function inspectStorage(directory) {
  const program = "import json,pathlib,sqlite3,sys\nroot=pathlib.Path(sys.argv[1])\nwith sqlite3.connect((root/'library.sqlite').as_uri()+'?mode=ro',uri=True) as c: print(json.dumps(c.execute(\"SELECT url,title,engine_id,in_history FROM entries WHERE in_history=1 ORDER BY id\").fetchall()))";
  const { stdout } = await promisify(execFile)("python3", ["-c", program, directory], { encoding: "utf8" });
  return { library: JSON.parse(stdout), session: JSON.parse(await readFile(join(directory, "session.json"), "utf8")) };
}

async function runSmoke(configuration, fixture) {
  const run = await launch(configuration, [fixture.pageA], "smoke");
  const result = { status: "failed", scope: "Loopback CDP rendering/history smoke; not native input, IME, or accessibility proof.", checks: {} };
  let page;
  try {
    const target = await poll("fixture page target", async () => (await fetch(`http://127.0.0.1:${run.devTools.port}/json/list`).then((response) => response.json())).find((item) => item.type === "page" && item.url === fixture.pageA) || false, configuration.timeout);
    const socket = new URL(target.webSocketDebuggerUrl); socket.hostname = "127.0.0.1";
    page = new CDP(socket.href); await page.connect();
    await poll("page A DOM", () => page.evaluate("document.querySelector('#heading')?.textContent === 'Native Chromium fixture'"), configuration.timeout); result.checks.pageA = true;
    await page.evaluate("document.querySelector('#query').value='cobble-smoke';document.querySelector('#submit').click()");
    await poll("form navigation", () => page.evaluate("location.pathname.endsWith('/result') && document.querySelector('#result')?.textContent === 'cobble-smoke'"), configuration.timeout); result.checks.formNavigation = true;
    await page.send("Page.navigate", { url: fixture.pageB });
    result.checks.pageBWebGL2 = await poll("page B WebGL2", () => page.evaluate("document.readyState==='complete' && window.cobbleGraphics?.status==='passed' ? window.cobbleGraphics : false"), configuration.timeout);
    const screenshot = await page.send("Page.captureScreenshot", { format: "png" });
    await writeFile(join(run.run, "page-b.png"), Buffer.from(screenshot.data, "base64")); result.checks.screenshot = "page-b.png";
    page.close(); page = undefined; await wait(1_000); await closeReview(run, configuration.timeout);
    const saved = await inspectStorage(run.data); result.checks.unifiedHistory = saved.library;
    result.checks.sessionEngineIDs = saved.session.windows.flatMap((window) => window.tabs.map((tab) => ({ urlString: tab.urlString, engineID: tab.engineID })));
    if (!saved.library.some((row) => row[0] === fixture.pageB && row[2] === "chromium")) fail("Library lacks the Chromium page-B visit");
    if (!result.checks.sessionEngineIDs.some((tab) => tab.urlString === fixture.pageB && tab.engineID === "chromium")) fail("Session lacks the page-B Chromium engineID");
    result.status = "passed"; result.exit = { code: run.child.exitCode, signal: run.child.signalCode };
  } catch (error) { result.error = error.message; }
  finally {
    page?.close(); result.processGroup = await terminate(run.child); result.logsClosed = await settleLogs(run.logs);
    if (result.status === "passed" && (result.processGroup.terminated || result.processGroup.remaining.length || !result.logsClosed)) {
      result.status = "failed";
      result.error = "Review app root exited, but its detached process group or log pipes did not close cleanly.";
    }
    await writeFile(join(run.run, "result.json"), `${JSON.stringify(result, null, 2)}\n`); await rm(run.root, { recursive: true, force: true });
  }
  if (result.status !== "passed") fail(`Smoke failed: ${result.error}`);
  return result;
}

async function main() {
  const configuration = options();
  await access(join(configuration.app, "Contents/MacOS/Chromium"), constants.X_OK);
  await access(join(configuration.app, "Contents/Frameworks/CobbleChromiumClient.dylib"), constants.R_OK);
  await access(join(configuration.sdk, "scripts/smoke.mjs"), constants.R_OK);
  try { await mkdir(configuration.artifacts); }
  catch (error) {
    if (error.code !== "EEXIST") throw error;
    if ((await readdir(configuration.artifacts)).length) fail("--artifacts must be a new or empty directory");
  }
  execFileSync("/usr/bin/codesign", ["--verify", "--deep", "--strict", configuration.app], { stdio: "ignore" });
  const manifest = JSON.parse(await readFile(join(configuration.app, "Contents/Resources/CobbleChromiumSDK.json"), "utf8"));
  const bundleID = execFileSync("/usr/bin/plutil", ["-extract", "CFBundleIdentifier", "raw", "-o", "-", join(configuration.app, "Contents/Info.plist")], { encoding: "utf8" }).trim();
  if (bundleID !== "com.ignacio.cobble" || manifest.variant !== "sdk" || manifest.release_ready !== false) fail("App is not an Cobble bundle with the pinned SDK runtime");
  const { startFixture } = await import(pathToFileURL(join(configuration.sdk, "scripts/smoke.mjs")).href);
  const fixture = await startFixture(randomUUID());
  const report = { schema: 1, startedAt: new Date().toISOString(), app: configuration.app, bundleID, sdk: configuration.sdk, chromium: { version: manifest.lock?.version, sdkRevision: manifest.sdk_revision }, launchFlags: LAUNCH_FLAGS, baselines: [], scope: "Isolated review app and loopback-only fixture. Samples follow a three-second startup settle with background networking, updates, sync, and pings disabled; they are startup diagnostics, not idle production costs or zero-telemetry evidence." };
  try {
    for (const count of configuration.tabs) report.baselines.push(await runBaseline(configuration, fixture, count));
    if (!configuration.skipSmoke) report.smoke = await runSmoke(configuration, fixture);
    report.status = "passed";
  } catch (error) { report.status = "failed"; report.error = error.message; throw error; }
  finally { fixture.server.closeAllConnections(); await new Promise((done) => fixture.server.close(done)); report.finishedAt = new Date().toISOString(); await writeFile(join(configuration.artifacts, "result.json"), `${JSON.stringify(report, null, 2)}\n`); }
}

main().catch((error) => { console.error(`FAIL: ${error.message}`); process.exitCode = 1; });
