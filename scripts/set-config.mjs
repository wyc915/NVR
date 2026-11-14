// Update one top-level key in server/config.json without printing the file
// (so the API token never shows up on screen or in logs).
//
//   node scripts/set-config.mjs <key> <json-value>
//   node scripts/set-config.mjs allowedNetworks "[\"100.64.0.0/10\",\"fd7a:115c:a1e0::/48\"]"
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const file = fileURLToPath(new URL('../server/config.json', import.meta.url));
const [key, value] = process.argv.slice(2);
if (!key || value === undefined) {
  console.error('usage: node scripts/set-config.mjs <key> <json-value>');
  process.exit(2);
}
if (key === 'token') {
  console.error('refusing to set the token this way; delete config.json to regenerate it');
  process.exit(2);
}
const cfg = JSON.parse(readFileSync(file, 'utf8').replace(/^﻿/, ''));
cfg[key] = JSON.parse(value);
writeFileSync(file, JSON.stringify(cfg, null, 2) + '\n', 'utf8');
console.log(`config.json: ${key} = ${JSON.stringify(cfg[key])}`);
