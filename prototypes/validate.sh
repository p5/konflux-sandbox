#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
go -C prototypes vet ./...
go -C prototypes/artifacts vet ./...
go -C prototypes/source-entry/build-service vet -mod=mod ./...
for module in identity durable private-evidence consumers broker-network; do
  go -C "prototypes/$module" vet ./...
done
while IFS= read -r script; do
  bash -n "$script"
done < <(rg --files prototypes -g '*.sh')
git diff --check
git diff --cached --check
node <<'NODE'
const fs = require('fs');
const path = require('path');
const files = ['README.md', ...fs.readdirSync('docs', {recursive: true})
  .filter(file => file.endsWith('.md')).map(file => `docs/${file}`)];
const missing = [];
let links = 0;
for (const file of files) {
  for (const match of fs.readFileSync(file, 'utf8').matchAll(/\]\(([^)]+)\)/g)) {
    const target = match[1].split('#')[0];
    if (!target || /^(https?:|mailto:|\/)/.test(target)) continue;
    if (target.includes('.prototype-results/') || /prototypes\/[^/]+\/evidence\//.test(target)) continue;
    links++;
    if (!fs.existsSync(path.resolve(path.dirname(file), target))) missing.push({file, target});
  }
}
console.log(JSON.stringify({files: files.length, links, missing}, null, 2));
if (missing.length) process.exitCode = 1;
NODE
