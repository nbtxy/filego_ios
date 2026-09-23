#!/usr/bin/env node
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const root = new URL("../fastlane/metadata/", import.meta.url).pathname;
const limits = new Map([
  ["name.txt", 30],
  ["subtitle.txt", 30],
  ["keywords.txt", 100],
  ["description.txt", 4_000],
  ["promotional_text.txt", 170],
  ["release_notes.txt", 4_000],
]);
let failed = false;

for (const locale of readdirSync(root, { withFileTypes: true }).filter((entry) => entry.isDirectory())) {
  if (locale.name === "review_information") continue;
  for (const [filename, limit] of limits) {
    const value = readFileSync(join(root, locale.name, filename), "utf8").trim();
    const length = [...value].length;
    const ok = length > 0 && length <= limit;
    const status = ok ? "OK" : length === 0 ? "缺失" : "超限";
    console.log(`${status.padEnd(4)} ${locale.name}/${filename}: ${length}/${limit}`);
    if (!ok) failed = true;
  }
}

if (failed) process.exitCode = 1;

