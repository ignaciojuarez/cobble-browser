#!/usr/bin/env node

// Isolated, real-engine login-sharing fixture. The Full app's Swift fixture
// driver writes result.json to COBBLE_AUTH_FIXTURE_ROOT and quits normally.
import { createHash, randomBytes, X509Certificate } from 'node:crypto';
import { spawn, execFile } from 'node:child_process';
import { createServer } from 'node:https';
import { createServer as createProxy } from 'node:http';
import { connect } from 'node:net';
import { constants } from 'node:fs';
import { access, copyFile, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';

const run = promisify(execFile);
const pause = (ms) => new Promise((done) => setTimeout(done, ms));
const appHost = 'app.cobble.test', providerHost = 'login.cobble.test';
const count = (values, key) => {
  if (Object.hasOwn(values, key) || Object.keys(values).length < 16) values[key] = (values[key] ?? 0) + 1;
};
const issuedSecrets = new Set();
const secret = () => {
  const value = randomBytes(24).toString('hex');
  issuedSecrets.add(value);
  return value;
};
const options = Object.fromEntries(process.argv.slice(2).reduce((pairs, item, index, args) => {
  if (item.startsWith('--')) pairs.push([item, args[index + 1]]);
  return pairs;
}, []));
if (!options['--app'] || !options['--artifacts'] ||
    process.argv.length !== 6 || !['--app', '--artifacts'].includes(process.argv[2]) ||
    !['--app', '--artifacts'].includes(process.argv[4]) || process.argv[2] === process.argv[4]) {
  throw new Error('Usage: node Scripts/test_login_sharing.mjs --app <fixtureFullCobble.app> --artifacts <newdir>');
}
const app = resolve(options['--app']);
const artifacts = resolve(options['--artifacts']);
const binary = join(app, 'Contents/MacOS/Chromium');
await access(binary, constants.X_OK);
await mkdir(artifacts, { recursive: true });
if ((await readdir(artifacts)).length) throw new Error('--artifacts must be empty');

const root = await mkdtemp(join(tmpdir(), 'cobble-login-sharing-'));
const certificate = join(root, 'certificate.pem');
const key = join(root, 'certificate.key');
const config = join(root, 'certificate.cnf');
const checks = { logins: 0, rotations: 0, logouts: 0, localLogouts: 0, actions: { success: 0, denied: 0 },
  requests: {}, tunnels: {}, proxyConnections: 0, proxyRequests: {}, rejectedConnect: {}, tlsClientErrors: {} };
const sessions = new Map();
const codes = new Map();
let server;
let proxy;
let child;
let stdout = '';
let stderr = '';
let exit;
let launchError;
const proxySockets = new Set();

async function waitForExit(milliseconds) {
  const deadline = Date.now() + milliseconds;
  while (!exit && Date.now() < deadline) await pause(100);
  return !!exit;
}

async function stopChild() {
  if (!child || exit) return;
  child.kill('SIGTERM');
  if (await waitForExit(5_000)) return;
  child.kill('SIGKILL');
  await waitForExit(5_000);
}

function send(response, title, probe, script = '', headers = {}) {
  response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', ...headers });
  response.end(`<!doctype html><title>${title}</title><meta name="fixture-probe" content="${probe}"><script>${script}</script>`);
}
function cookieSession(request) {
  const value = /(?:^|;\s*)__Host-session=([^;]+)/.exec(request.headers.cookie ?? '')?.[1];
  return value ? sessions.get(value) : undefined;
}
function csrfCookie(request) {
  return /(?:^|;\s*)csrf=([^;]+)/.exec(request.headers.cookie ?? '')?.[1];
}
function sessionHeaders(id, csrf) {
  return { 'Set-Cookie': [
    `__Host-session=${id}; Secure; HttpOnly; SameSite=Lax; Path=/`,
    `csrf=${csrf}; Secure; SameSite=Lax; Path=/`,
  ] };
}
function redirect(response, location) {
  response.writeHead(302, { Location: location, 'Cache-Control': 'no-store' });
  response.end();
}
function handle(request, response) {
  const host = request.headers.host;
  if (host !== appHost && host !== providerHost) {
    response.writeHead(400); response.end(); return;
  }
  const url = new URL(request.url ?? '/', `https://${host}`);
  count(checks.requests, host + url.pathname);
  const candidate = url.searchParams.get('probe') ?? '';
  const probe = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(candidate) ? candidate : '';
  const sendPage = (title, script = '', headers = {}) => send(response, title, probe, script, headers);
  if (request.method === 'GET' && url.pathname === '/login') {
    const user = url.searchParams.get('user');
    if (user !== 'alice' && user !== 'bob') { response.writeHead(400); response.end(); return; }
    const code = secret();
    codes.set(code, { user, storage: url.searchParams.get('storage') === '1' });
    redirect(response, `https://${providerHost}/provider?code=${code}&probe=${probe}`);
  } else if (request.method === 'GET' && url.pathname === '/provider' && host === providerHost) {
    const code = url.searchParams.get('code');
    if (!codes.has(code)) { response.writeHead(403); response.end(); return; }
    redirect(response, `https://${appHost}/callback?code=${code}&probe=${probe}`);
  } else if (request.method === 'GET' && url.pathname === '/callback' && host === appHost) {
    const code = url.searchParams.get('code');
    const login = codes.get(code);
    codes.delete(code);
    if (!login) { response.writeHead(403); response.end(); return; }
    const id = secret(), csrf = secret(), proof = login.storage ? secret() : null;
    sessions.set(id, { user: login.user, csrf, proof });
    checks.logins++;
    const storage = proof ? `localStorage.setItem('fixtureProof', '${proof}')` : `localStorage.removeItem('fixtureProof')`;
    sendPage(`fixture:${login.user}`, storage, sessionHeaders(id, csrf));
  } else if (request.method === 'GET' && url.pathname === '/whoami' && host === appHost) {
    sendPage(`fixture:${cookieSession(request)?.user ?? 'guest'}`);
  } else if (request.method === 'GET' && url.pathname === '/exercise' && host === appHost) {
    sendPage('fixture:exercise', `
      const csrf = document.cookie.split('; ').find(x => x.startsWith('csrf='))?.slice(5) ?? '';
      fetch('/action', {method:'POST', credentials:'include', headers:{
        'X-CSRF': csrf, 'X-Storage-Proof': localStorage.getItem('fixtureProof') ?? ''
      }}).then(r => r.json()).then(r => document.title = 'fixture:action:' + r.user)
        .catch(() => document.title = 'fixture:action:denied');`);
  } else if (request.method === 'POST' && url.pathname === '/action' && host === appHost) {
    const session = cookieSession(request);
    const valid = session && csrfCookie(request) === session.csrf &&
      request.headers['x-csrf'] === session.csrf &&
      (!session.proof || request.headers['x-storage-proof'] === session.proof);
    checks.actions[valid ? 'success' : 'denied']++;
    response.writeHead(valid ? 200 : 403, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    response.end(JSON.stringify({ user: valid ? session.user : 'denied' }));
  } else if (request.method === 'GET' && url.pathname === '/rotate' && host === appHost) {
    const oldID = /(?:^|;\s*)__Host-session=([^;]+)/.exec(request.headers.cookie ?? '')?.[1];
    const old = cookieSession(request);
    if (!old) { sendPage('fixture:guest'); return; }
    sessions.delete(oldID);
    const id = secret(), csrf = secret();
    sessions.set(id, { ...old, csrf });
    checks.rotations++;
    sendPage(`fixture:rotated:${old.user}`, '', sessionHeaders(id, csrf));
  } else if (request.method === 'GET' && (url.pathname === '/logout' || url.pathname === '/local-logout') && host === appHost) {
    const id = /(?:^|;\s*)__Host-session=([^;]+)/.exec(request.headers.cookie ?? '')?.[1];
    if (url.pathname === '/local-logout') checks.localLogouts++;
    else if (id && sessions.delete(id)) checks.logouts++;
    sendPage('fixture:guest', `localStorage.removeItem('fixtureProof')`, {
      'Set-Cookie': [
        '__Host-session=; Max-Age=0; Secure; HttpOnly; SameSite=Lax; Path=/',
        'csrf=; Max-Age=0; Secure; SameSite=Lax; Path=/',
      ],
    });
  } else {
    response.writeHead(404, { 'Cache-Control': 'no-store' }); response.end();
  }
}

try {
  await writeFile(config, '[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=extensions\n' +
    `[dn]\nCN=${appHost}\n[extensions]\nsubjectAltName=DNS:${appHost},DNS:${providerHost}\n` +
    'basicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature,keyEncipherment\n' +
    'extendedKeyUsage=serverAuth\n');
  await run('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
    '-config', config, '-keyout', key, '-out', certificate]);
  const pem = await readFile(certificate);
  const x509 = new X509Certificate(pem);
  await writeFile(join(root, 'certificate.der'), x509.raw);
  const spki = createHash('sha256').update(x509.publicKey.export({ type: 'spki', format: 'der' })).digest('base64');
  server = createServer({ key: await readFile(key), cert: pem }, handle);
  server.on('tlsClientError', error => count(checks.tlsClientErrors, String(error.code ?? 'unknown').slice(0, 40)));
  await new Promise((done, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', done);
  });
  const tlsPort = server.address().port;
  proxy = createProxy((request, response) => {
    let pathname = 'invalid';
    try { pathname = new URL(request.url ?? '/', 'http://fixture.invalid').pathname.slice(0, 80); } catch { /* Count malformed request. */ }
    count(checks.proxyRequests, `${request.method?.slice(0, 10) ?? 'unknown'} ${pathname}`);
    response.writeHead(405); response.end();
  });
  proxy.on('connection', socket => {
    checks.proxyConnections++;
    proxySockets.add(socket);
    socket.once('close', () => proxySockets.delete(socket));
  });
  proxy.on('connect', (request, client, head) => {
    if (request.url !== `${appHost}:443` && request.url !== `${providerHost}:443`) {
      count(checks.rejectedConnect, String(request.url ?? '').replace(/[^A-Za-z0-9.:[\]-]/g, '?').slice(0, 80));
      client.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
      return;
    }
    count(checks.tunnels, request.url);
    const upstream = connect(tlsPort, '127.0.0.1');
    proxySockets.add(upstream);
    upstream.once('close', () => proxySockets.delete(upstream));
    upstream.once('connect', () => {
      client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head.length) upstream.write(head);
      client.pipe(upstream).pipe(client);
    });
    upstream.once('error', () => client.destroy());
    client.once('error', () => upstream.destroy());
    client.once('close', () => upstream.destroy());
  });
  await new Promise((done, reject) => {
    proxy.once('error', reject);
    proxy.listen(0, '127.0.0.1', done);
  });
  const proxyPort = proxy.address().port;
  await writeFile(join(root, 'proxy-port.txt'), String(proxyPort));
  await mkdir(join(root, 'data'));
  await mkdir(join(root, 'chromium'));
  child = spawn(binary, [
    `--user-data-dir=${join(root, 'chromium')}`,
    `--ignore-certificate-errors-spki-list=${spki}`,
    '--use-mock-keychain', '--noerrdialogs', '--no-first-run',
    '--disable-background-networking', '--disable-component-update', '--disable-sync', '--no-pings',
    `--proxy-server=http://127.0.0.1:${proxyPort}`, '--proxy-bypass-list=<-loopback>',
    '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1',
  ], { env: { ...process.env, COBBLE_DATA_DIRECTORY: join(root, 'data'), COBBLE_AUTH_FIXTURE_ROOT: root },
    stdio: ['ignore', 'pipe', 'pipe'] });
  child.stdout.on('data', chunk => { stdout += chunk; });
  child.stderr.on('data', chunk => { stderr += chunk; });
  child.once('error', error => { launchError = error; });
  child.once('close', (code, signal) => { exit = { code, signal }; });
  const deadline = Date.now() + 150_000;
  while (Date.now() < deadline) {
    if (launchError) throw launchError;
    if (exit) break;
    try { await access(join(root, 'result.json')); break; } catch { /* Driver still running. */ }
    await pause(100);
  }
  const resultPath = join(root, 'result.json');
  let result;
  try { result = JSON.parse(await readFile(resultPath, 'utf8')); }
  catch { throw new Error(exit ? `Fixture app exited before result: ${JSON.stringify(exit)}` : 'Fixture result timed out'); }
  await copyFile(resultPath, join(artifacts, 'result.json'));
  if (!exit) await waitForExit(15_000);
  if (!exit) await stopChild();
  if (result.error || !Array.isArray(result.passed) || result.passed.length !== 9) {
    throw new Error(`Fixture failed: ${result.error ?? 'expected 9 passed checks in result.json'}`);
  }
  if (!exit || exit.code !== 0) throw new Error(`Fixture app did not quit cleanly: ${JSON.stringify(exit)}`);
  if (checks.actions.success < 5 || checks.actions.denied < 1 || checks.logins < 3 ||
      checks.rotations < 1 || checks.logouts < 1 || checks.localLogouts < 1) {
    throw new Error(`Fixture server counters incomplete: ${JSON.stringify(checks)}`);
  }
  console.log(`Login-sharing fixture passed (${result.passed.length} app checks).`);
} catch (error) {
  process.exitCode = 1;
  console.error(`Login-sharing fixture failed: ${error.message}`);
  await writeFile(join(artifacts, 'runner-error.txt'), `${error.message}\n`);
  await stopChild();
} finally {
  await writeFile(join(artifacts, 'server-checks.json'), `${JSON.stringify(checks, null, 2)}\n`);
  const redact = (value) => [...issuedSecrets].reduce((text, secret) => text.replaceAll(secret, '[redacted]'), value);
  await writeFile(join(artifacts, 'app.stdout.log'), redact(stdout));
  await writeFile(join(artifacts, 'app.stderr.log'), redact(stderr));
  if (proxy) {
    for (const socket of proxySockets) socket.destroy();
    proxy.closeAllConnections();
    await new Promise(done => proxy.close(done));
  }
  if (server) {
    server.closeAllConnections();
    await new Promise(done => server.close(done));
  }
  if (!child || exit) await rm(root, { recursive: true, force: true });
  else console.error(`Fixture app did not exit; temporary profile kept at ${root}`);
}
