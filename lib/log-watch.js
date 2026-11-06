const { readFileSync, writeFileSync, existsSync, mkdirSync, statSync, readdirSync, openSync, readSync, closeSync } = require("node:fs");
const { join, dirname } = require("node:path");
const { homedir } = require("node:os");

const LOG_DIR = join(homedir(), ".local", "share", "opencode", "log");
const STATE_FILE = join(homedir(), ".config", "opencode", "unlimited-watch.json");
const MAX_BYTES = 4 * 1024 * 1024;
const MAX_EVENTS = 50;

const ROTATE_PATTERNS = [
  /free usage limit/i,
  /usage limit reached/i,
  /out of usage/i,
  /insufficient credits/i,
  /payment required/i,
  /quota exceeded/i,
];

const ASK_PATTERNS = [
  /rate[ _-]?limit/i,
  /too many requests/i,
  /\b429\b/,
];

const EVENT_LINE = /^timestamp=\S+\s+level=ERROR\b/i;
const STAMP = /^timestamp=(\S+)/i;
const RUN = /\brun=([0-9a-f]+)/i;
const MESSAGE = /\bmessage="([^"]*)"/i;

function classify(text) {
  if (ROTATE_PATTERNS.some((pattern) => pattern.test(text))) return "rotate";
  if (ASK_PATTERNS.some((pattern) => pattern.test(text))) return "ask";
  return "noop";
}

function latestLog(dir) {
  if (!existsSync(dir)) return "";
  const files = readdirSync(dir)
    .filter((name) => /\.log$/i.test(name))
    .map((name) => join(dir, name));
  if (!files.length) return "";
  files.sort((left, right) => statSync(right).mtimeMs - statSync(left).mtimeMs);
  return files[0];
}

function loadState() {
  if (!existsSync(STATE_FILE)) return { file: "", offset: 0 };
  try {
    const raw = JSON.parse(readFileSync(STATE_FILE, "utf8"));
    return { file: String(raw.file || ""), offset: Math.max(0, Number(raw.offset || 0)) };
  } catch {
    return { file: "", offset: 0 };
  }
}

function saveState(state) {
  const path = dirname(STATE_FILE);
  if (!existsSync(path)) mkdirSync(path, { recursive: true });
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2) + "\n", "utf8");
}

function readNew(file, offset) {
  const size = statSync(file).size;
  let start = Number(offset || 0);
  if (start > size) start = 0;
  if (size - start > MAX_BYTES) start = size - MAX_BYTES;
  if (size === start) return { from: start, offset: start, text: "" };
  const buffer = Buffer.alloc(size - start);
  const fd = openSync(file, "r");
  try {
    readSync(fd, buffer, 0, buffer.length, start);
  } finally {
    closeSync(fd);
  }
  const end = buffer.lastIndexOf(0x0a);
  if (end < 0) return { from: start, offset: start, text: "" };
  return { from: start, offset: start + end + 1, text: buffer.subarray(0, end).toString("utf8") };
}

function parseLines(text) {
  const events = [];
  const counts = { rotate: 0, ask: 0, noop: 0 };
  if (!text) return { events, counts };
  for (const line of text.split("\n")) {
    if (!EVENT_LINE.test(line)) continue;
    const kind = classify(line);
    counts[kind] += 1;
    if (kind === "noop") continue;
    const stamp = STAMP.exec(line);
    const run = RUN.exec(line);
    const message = MESSAGE.exec(line);
    const patterns = kind === "rotate" ? ROTATE_PATTERNS : ASK_PATTERNS;
    const hit = patterns.find((pattern) => pattern.test(line));
    events.push({
      kind,
      at: stamp ? stamp[1] : "",
      run: run ? run[1] : "",
      message: message ? message[1] : "",
      reason: hit ? hit.exec(line)[0] : "",
      text: line.length > 320 ? line.slice(0, 320) + " ..." : line,
    });
  }
  if (events.length > MAX_EVENTS) events.splice(0, events.length - MAX_EVENTS);
  return { events, counts };
}

function scan(options = {}) {
  const file = String(options.file || latestLog(LOG_DIR) || "");
  if (!file || !existsSync(file)) {
    return { file: "", from: 0, offset: 0, size: 0, events: [], counts: { rotate: 0, ask: 0, noop: 0 }, error: "no log file" };
  }
  const state = loadState();
  let offset = state.offset;
  if (!state.file) offset = statSync(file).size;
  else if (state.file !== file) offset = 0;
  if (options.reset) offset = 0;
  const read = readNew(file, offset);
  const parsed = parseLines(read.text);
  saveState({ file, offset: read.offset });
  return {
    file,
    from: read.from,
    offset: read.offset,
    size: statSync(file).size,
    events: parsed.events,
    counts: parsed.counts,
  };
}

function reset() {
  saveState({ file: "", offset: 0 });
  return { reset: true, stateFile: STATE_FILE };
}

function main() {
  const argv = process.argv.slice(2);
  const action = argv[0] || "scan";
  const options = { file: "", reset: false };
  for (let i = 1; i < argv.length; i += 1) {
    if (argv[i] === "--file") options.file = argv[++i] ?? "";
    else if (argv[i] === "--reset") options.reset = true;
  }
  try {
    if (action === "scan") {
      console.log(JSON.stringify(scan(options), null, 2));
      return;
    }
    if (action === "path") {
      console.log(JSON.stringify({ dir: LOG_DIR, file: latestLog(LOG_DIR), stateFile: STATE_FILE }, null, 2));
      return;
    }
    if (action === "reset") {
      console.log(JSON.stringify(reset(), null, 2));
      return;
    }
    console.log(JSON.stringify({ error: "unknown action: " + action }));
    process.exitCode = 2;
  } catch (error) {
    console.log(JSON.stringify({ error: String(error && error.message ? error.message : error) }));
    process.exitCode = 1;
  }
}

if (require.main === module) main();

module.exports = { scan, latestLog, reset, LOG_DIR, STATE_FILE };
