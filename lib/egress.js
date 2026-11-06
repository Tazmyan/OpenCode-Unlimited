const { readFileSync, writeFileSync, existsSync, mkdirSync } = require("node:fs");
const { join, dirname } = require("node:path");
const { homedir } = require("node:os");

const STATE_FILE = join(homedir(), ".config", "opencode", "unlimited-egress.json");

function utcDay(ms) {
  return new Date(Number(ms) || Date.now()).toISOString().slice(0, 10);
}

function nextMidnightUtc(ms) {
  const now = new Date(Number(ms) || Date.now());
  return Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1, 0, 0, 0, 0);
}

function cleanAddress(value) {
  let text = String(value ?? "").trim().toLowerCase();
  if (!text) return "";
  if (text.startsWith("[")) {
    const end = text.indexOf("]");
    if (end > 0) text = text.slice(1, end);
  }
  const zone = text.indexOf("%");
  if (zone > 0) text = text.slice(0, zone);
  return text;
}

function ipv4Parts(text) {
  const parts = text.split(".");
  if (parts.length !== 4) return null;
  const out = [];
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null;
    const octet = Number(part);
    if (octet > 255) return null;
    out.push(octet);
  }
  return out;
}

function expandGroups(list) {
  const out = [];
  for (const item of list) {
    if (!item) return null;
    if (item.includes(".")) {
      const v4 = ipv4Parts(item);
      if (!v4) return null;
      out.push(((v4[0] << 8) | v4[1]).toString(16));
      out.push(((v4[2] << 8) | v4[3]).toString(16));
      continue;
    }
    if (!/^[0-9a-f]{1,4}$/.test(item)) return null;
    out.push(item);
  }
  return out;
}

function ipv6Parts(text) {
  if (!text.includes(":")) return null;
  const halves = text.split("::");
  if (halves.length > 2) return null;
  const head = halves[0] ? expandGroups(halves[0].split(":")) : [];
  if (!head) return null;
  if (halves.length === 1) return head.length === 8 ? head : null;
  const tail = halves[1] ? expandGroups(halves[1].split(":")) : [];
  if (!tail) return null;
  const fill = 8 - head.length - tail.length;
  if (fill < 1) return null;
  return [...head, ...Array(fill).fill("0"), ...tail];
}

function shortGroup(value) {
  const trimmed = String(value).replace(/^0+/, "");
  return trimmed || "0";
}

function blockKey(ip) {
  const text = cleanAddress(ip);
  if (!text) return "";
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(text);
  if (mapped) {
    const v4 = ipv4Parts(mapped[1]);
    if (v4) return v4.join(".") + "/32";
  }
  const plain = ipv4Parts(text);
  if (plain) return plain.join(".") + "/32";
  const v6 = ipv6Parts(text);
  if (v6) return v6.slice(0, 4).map(shortGroup).join(":") + "::/64";
  return "";
}

function sameBlock(left, right) {
  const a = blockKey(left);
  const b = blockKey(right);
  return Boolean(a) && a === b;
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
    ip: cleanAddress(options.ip),
    firstSeen: new Date().toISOString(),
    seen: 0,
    open: 0,
    refused: 0,
  };
  const status = Number(options.status || 0);
  entry.seen += 1;
  entry.lastSeen = new Date().toISOString();
  entry.lastIp = cleanAddress(options.ip);
  if (options.country) entry.country = String(options.country).trim().toUpperCase().slice(0, 8);
  if (status === 429) {
    entry.refused += 1;
    entry.spent = true;
    entry.lastStatus = 429;
    entry.retryAfter = Number(options.retryAfter || 0);
    entry.resetAt = new Date(nextMidnightUtc()).toISOString();
  } else if (status === 200) {
    entry.open += 1;
    entry.lastOkAt = new Date().toISOString();
    if (!entry.spent) entry.lastStatus = 200;
  } else if (status > 0) {
    entry.lastStatus = status;
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
    ip: entry.lastIp || entry.ip,
    country: entry.country || "",
    spent: Boolean(entry.spent),
    open: Number(entry.open || 0),
    refused: Number(entry.refused || 0),
    lastStatus: Number(entry.lastStatus || 0),
    lastOkAt: entry.lastOkAt || "",
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
  const entry = (key && state.addresses[key]) || null;
  return {
    block: key,
    known: Boolean(entry),
    spent: Boolean(entry && entry.spent),
    country: (entry && entry.country) || "",
    open: Number((entry && entry.open) || 0),
    refused: Number((entry && entry.refused) || 0),
    lastStatus: Number((entry && entry.lastStatus) || 0),
    lastSeen: (entry && entry.lastSeen) || "",
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
      const country = (process.env.UNLIMITED_EGRESS_COUNTRY || "").trim();
      console.log(JSON.stringify(record({ ip, status, retryAfter, country }), null, 2));
      return;
    }
    if (action === "check") {
      console.log(JSON.stringify(check({ ip: a }), null, 2));
      return;
    }
    if (action === "same") {
      console.log(JSON.stringify({ same: sameBlock(a, b), a: blockKey(a), b: blockKey(b) }));
      return;
    }
    if (action === "key") {
      console.log(JSON.stringify({ block: blockKey(a) }));
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

module.exports = {
  record,
  show,
  check,
  clear,
  blockKey,
  sameBlock,
  nextMidnightUtc,
  STATE_FILE,
};
