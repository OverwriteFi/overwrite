// PreToolUse guard: refuse writes to any path containing ".env" unless the
// file name is exactly ".env.example". Exit code 2 blocks the tool call.
import { basename } from "node:path";

let raw = "";
for await (const chunk of process.stdin) raw += chunk;

let input;
try {
  input = JSON.parse(raw);
} catch {
  process.exit(0);
}

const tool = input.tool_name ?? "";
const ti = input.tool_input ?? {};

function offending(p) {
  if (!p) return false;
  const norm = String(p).split(String.fromCharCode(92)).join("/");
  return norm.includes(".env") && basename(norm) !== ".env.example";
}

const candidates = [];
if (["Write", "Edit", "MultiEdit", "NotebookEdit"].includes(tool)) {
  candidates.push(ti.file_path ?? ti.notebook_path);
} else if (tool === "Bash" && typeof ti.command === "string") {
  // Shell redirections / tee / cp / mv targeting a .env-ish path.
  const re = /(?:>>?|\btee\b(?:\s+-a)?|\bcp\b[^|;&]*|\bmv\b[^|;&]*)\s*["']?([^\s"'|;&]*\.env[^\s"'|;&]*)/g;
  for (const m of ti.command.matchAll(re)) candidates.push(m[1]);
}

const bad = candidates.filter(offending);
if (bad.length) {
  process.stderr.write(
    `guard-env: refusing to write ${bad.join(", ")}. Only .env.example may be written; real env files are hand-edited by the user.\n`,
  );
  process.exit(2);
}
process.exit(0);
