// Tiny fixture server with planted issues. Logs every request to hits.jsonl
// so the test can assert that the audit never hit dangerous URLs and never
// sent writes when submission was off.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const port = +process.argv[2] || 4917;
const hitsFile = process.argv[3] || path.join(HERE, 'hits.jsonl');
fs.writeFileSync(hitsFile, '');
const pages = { '/': 'index.html', '/signup': 'signup.html', '/contact': 'contact.html', '/a11y': 'a11y.html', '/overflow': 'overflow.html', '/buttons': 'buttons.html' };
http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    fs.appendFileSync(hitsFile, JSON.stringify({ method: req.method, path: url.pathname, host: req.headers.host, body: body.slice(0, 200) }) + '\n');
    if (pages[url.pathname]) { res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }); return res.end(fs.readFileSync(path.join(HERE, 'site', pages[url.pathname]))); }
    if (url.pathname === '/api/error') { res.writeHead(500, { 'content-type': 'application/json' }); return res.end('{"error":"boom"}'); }
    if (url.pathname === '/api/signup' && req.method === 'POST') { res.writeHead(500, { 'content-type': 'text/plain' }); return res.end('server exploded'); }
    if (url.pathname === '/api/contact' && req.method === 'POST') { res.writeHead(200, { 'content-type': 'application/json' }); return res.end('{"ok":true}'); }
    if (url.pathname === '/logo.png') { res.writeHead(200, { 'content-type': 'image/png' }); return res.end(fs.readFileSync(path.join(HERE, '..', 'fixtures', 'test-upload.png'))); }
    if (url.pathname === '/logout' || url.pathname === '/account/delete') { res.writeHead(200, { 'content-type': 'text/html' }); return res.end('<h1>DANGEROUS ENDPOINT HIT</h1>'); }
    res.writeHead(404, { 'content-type': 'text/html' }); res.end('<h1>Not found</h1>');
  });
}).listen(port, '127.0.0.1', () => console.log(`fixture server on ${port}`));
