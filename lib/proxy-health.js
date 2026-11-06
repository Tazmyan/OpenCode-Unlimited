const { readFileSync, writeFileSync, existsSync, mkdirSync } = require("node:fs");
const { join, dirname } = require("node:path");
const { homedir } = require("node:os");

const STATE_FILE = join(homedir(), ".config", "opencode", "unlimited-proxy-health.json");
const TTL_MS = 7 * 86400000;
const QUARANTINE_BASE_MS = 5 * 60000;
const QUARANTINE_MAX_MS = 6 * 3600000;
const FAIL_LIMIT = 2;
const SLOW_MS = 3500;
const MAX_ENTRIES = 400;

function load() {
  if (!existsSync(STATE_FILE)) return { at: Date.now(), proxies: {} };
  try {
    const raw = JSON.parse(readFileSync(STATE_FILE, "utf8"));
    if (!raw || typeof raw !== "object" || !raw.proxies) return { at: Date.now(), proxies: {} };
    return { at: Number(raw.at || 0), proxies: raw.proxies };
  } catch {
    return { at: Date.now(), proxies: {} };
  }
}

function save(state) {
  const path = dirname(STATE_FILE);
  if (!existsSync(path)) mkdirSync(path, { recursive: true });
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2) + "\n", "utf8");
  return state;
}

function entryFor(state, url) {
  const key = String(url || "").trim();
  if (!key) return null;
  if (!state.proxies[key]) {
    state.proxies[key] = {
      ok: 0,
      fail: 0,
      ms: 0,
      lastAt: 0,
      lastOkAt: 0,
      lastFailAt: 0,
      reason: "",
      until: 0,
    };
  }
  return { key, entry: state.proxies[key] };
}

function record(options) {
  const state = load();
  const found = entryFor(state, options.url);
  if (!found) throw new Error("record needs a url");
  const { key, entry } = found;
  const now = Date.now();
  entry.lastAt = now;
  if (options.ok) {
    entry.ok = Number(entry.ok || 0) + 1;
    entry.fail = 0;
    entry.until = 0;
    entry.reason = "";
    entry.lastOkAt = now;
    const ms = Math.max(0, Number(options.ms || 0));
    entry.ms = entry.ms ? Math.round((entry.ms * 2 + ms) / 3) : ms;
  } else {
    entry.fail = Number(entry.fail || 0) + 1;
    entry.lastFailAt = now;
    entry.reason = String(options.reason || "failed").slice(0, 40);
    if (entry.fail >= FAIL_LIMIT) {
      const step = Math.min(entry.fail - FAIL_LIMIT, 8);
      const wait = Math.min(QUARANTINE_BASE_MS * Math.pow(2, step), QUARANTINE_MAX_MS);
      entry.until = now + wait;
    }
    entry.lastMsFail = Number(options.ms || 0);
  }
  state.at = now;
  save(prune(state));
  return { url: key, entry };
}

function prune(state) {
  const cutoff = Date.now() - TTL_MS;
  const entries = Object.entries(state.proxies)
    .filter(([, entry]) => Number(entry.lastAt || 0) >= cutoff)
    .sort((left, right) => Number(right[1].lastAt || 0) - Number(left[1].lastAt || 0))
    .slice(0, MAX_ENTRIES);
  state.proxies = Object.fromEntries(entries);
  return state;
}

function score(entry, now) {
  const fail = Number(entry.fail || 0);
  const ms = Number(entry.ms || 0);
  const quarantined = Number(entry.until || 0) > now;
  if (quarantined) return 1e12 + (Number(entry.until) - now);
  const latency = ms > 0 ? Math.min(ms, 20000) : 4000;
  const slowPenalty = ms > SLOW_MS ? 30000 : 0;
  return fail * 200000 + latency + slowPenalty;
}

function rank(list, options = {}) {
  const state = load();
  const now = Date.now();
  const seen = new Set();
  const rows = [];
  for (const item of Array.isArray(list) ? list : []) {
    const url = String(item || "").trim();
    if (!url || seen.has(url)) continue;
    seen.add(url);
    const entry = state.proxies[url] || null;
    rows.push({
      url,
      entry,
      value: entry ? score(entry, now) : 20000,
      quarantined: Boolean(entry && Number(entry.until || 0) > now),
      ok: Number((entry && entry.ok) || 0),
      fail: Number((entry && entry.fail) || 0),
      ms: Number((entry && entry.ms) || 0),
      reason: (entry && entry.reason) || "",
      until: Number((entry && entry.until) || 0),
    });
  }
  const fresh = rows.filter((row) => !row.quarantined);
  const held = rows.filter((row) => row.quarantined);
  fresh.sort((left, right) => left.value - right.value);
  held.sort((left, right) => left.until - right.until);
  const ordered = fresh.concat(held);
  const limit = Number(options.limit || 0);
  const seenRows = limit > 0 ? ordered.slice(0, limit) : ordered;
  return {
    total: rows.length,
    usable: fresh.length,
    held: held.length,
    proxies: seenRows.map((row) => row.url),
    detail: seenRows,
    slowMs: SLOW_MS,
  };
}

function show(list) {
  const ranked = rank(Array.isArray(list) && list.length ? list : Object.keys(load().proxies));
  return {
    file: STATE_FILE,
    total: ranked.total,
    usable: ranked.usable,
    held: ranked.held,
    rows: ranked.detail.slice(0, 60),
  };
}

function reset() {
  save({ at: Date.now(), proxies: {} });
  return { reset: true, file: STATE_FILE };
}

function main() {
  const argv = process.argv.slice(2);
  const action = argv[0] || "show";
  try {
    if (action === "record") {
      const url = argv[1] || "";
      const state = String(argv[2] || "").toLowerCase();
      const ms = Number(argv[3] || 0);
      const reason = argv[4] || "";
      console.log(JSON.stringify(record({ url, ok: state === "ok", ms, reason }), null, 2));
      return;
    }
    if (action === "rank") {
      console.log(JSON.stringify(rank(argv.slice(1)), null, 2));
      return;
    }
    if (action === "show") {
      console.log(JSON.stringify(show(argv.slice(1)), null, 2));
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

module.exports = { record, rank, show, reset, prune, STATE_FILE, SLOW_MS };
