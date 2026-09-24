import fs from 'node:fs';
import path from 'node:path';
import { remuxFaststart } from './faststart.js';

const dir = process.argv[2];
if (!dir) {
  console.error('usage: node remux_existing.js <uploads-dir>');
  process.exit(1);
}

const files = fs.readdirSync(dir).filter((name) =>
  ['.mp4', '.mov', '.m4v'].includes(path.extname(name).toLowerCase()),
);

let changed = 0;
for (const name of files) {
  const filePath = path.join(dir, name);
  const did = await remuxFaststart(filePath);
  console.log(`${did ? 'rewrote' : 'ok     '} ${name}`);
  if (did) changed += 1;
}
console.log(`faststart rewrote ${changed}/${files.length}`);
