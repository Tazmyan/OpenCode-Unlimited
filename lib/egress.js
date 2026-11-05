const { readFileSync, writeFileSync, existsSync, mkdirSync } = require("node:fs");
const { join, dirname } = require("node:path");
const { homedir } = require("node:os");

const STATE_FILE = join(homedir(), ".config", "opencode", "unlimited-egress.json");
const DAY_MS = 86400000;

function utcDay(ms) {
  return new Date(Number(ms) || Date.now()).toISOString().slice(0, 10);
}

function nextMidnightUtc(ms) {
  const now = new Date(Number(ms) || Date.now());
  return Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1, 0, 0, 0, 0);
}

function blockKey(ip) {
  const text = String(ip || "").trim();
  if (!text) return "";
  if (text.includes(":")) {
    const parts = text.split(":").filter(Boolean);
    return parts.slice(0, 4).join(":") + "::/64";
  }
  return text + "/32";
}

function load() {
  if (!existsSync(STATE_FILE)) return { day: utcDay(), addresses: {} };
  try {
    const raw = JSON.parse(readFileSync(STATE_FILE, "utf8"));
    if (!raw || raw.day !== utcDay()) return { day: utcDay(), addresses: {} };
    return { day: raw.day, addresses: raw.addresses || {} };
  } catch {
    return { day: utcDay(), addresses: {} };
  }
}

function save(state) {
  const path = dirname(STATE_FILE);
  if (!existsSync(path)) mkdirSync(path, { recursive: true });
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2) + "\n", "utf8");
  return state;
}

function record(options) {
  const state = load();
  const key = blockKey(options.ip);
  if (!key) throw new Error("record needs an ip");
  const entry = state.addresses[key] || {
    ip: String(options.ip || ""),
    firstSeen: new Date().toISOString(),
    seen: 0,
    open: 0,
    refused: 0,
  };
  entry.seen += 1;
  entry.lastSeen = new Date().toISOString();
  entry.lastStatus = Number(options.status || 0);
  if (Number(options.status || 0) === 429) {
    entry.refused += 1;
    entry.spent = true;
    entry.retryAfter = Number(options.retryAfter || 0);
    entry.resetAt = new Date(nextMidnightUtc()).toISOString();
  } else if (Number(options.status || 0) === 200) {
    entry.open += 1;
    entry.spent = false;
  }
  if (options.note) entry.note = String(options.note).slice(0, 120);
  state.addresses[key] = entry;
  save(state);
  return { key, entry };
}

function show() {
  const state = load();
  const midnight = nextMidnightUtc();
  const rows = Object.entries(state.addresses).map(([key, entry]) => ({
    block: key,
    ip: entry.ip,
    spent: Boolean(entry.spent),
    open: Number(entry.open || 0),
    refused: Number(entry.refused || 0),
    lastStatus: Number(entry.lastStatus || 0),
    resetAt: entry.resetAt || new Date(midnight).toISOString(),
    lastSeen: entry.lastSeen || "",
  }));
  rows.sort((a, b) => Number(b.spent) - Number(a.spent) || b.refused - a.refused);
  return {
    day: state.day,
    nextResetUtc: new Date(midnight).toISOString(),
    secondsToReset: Math.max(0, Math.round((midnight - Date.now()) / 1000)),
    total: rows.length,
    spent: rows.filter((row) => row.spent).length,
    blocks: rows,
  };
}

function check(options) {
  const state = load();
  const key = blockKey(options.ip);
  const entry = state.addresses[key] || null;
  return {
    block: key,
    spent: Boolean(entry && entry.spent),
    known: Boolean(entry),
    resetAt: new Date(nextMidnightUtc()).toISOString(),
  };
}

function clear() {
  save({ day: utcDay(), addresses: {} });
  return { cleared: true, day: utcDay() };
}

function main() {
  const [action, a, b] = process.argv.slice(2);
  try {
    if (!action || action === "show") {
      console.log(JSON.stringify(show(), null, 2));
      return;
    }
    if (action === "record") {
      const status = Number(a || 0);
      const retryAfter = Number(b || 0);
      const ip = (process.env.UNLIMITED_EGRESS_IP || "").trim();
      console.log(JSON.stringify(record({ ip, status, retryAfter }), null, 2));
      return;
    }
    if (action === "check") {
      console.log(JSON.stringify(check({ ip: a }), null, 2));
      return;
    }
    if (action === "clear") {
      console.log(JSON.stringify(clear(), null, 2));
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

module.exports = { record, show, check, clear, blockKey, nextMidnightUtc, STATE_FILE };
