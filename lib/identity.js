const { randomUUID, createHash } = require("node:crypto");
const { readFileSync, writeFileSync, existsSync, mkdirSync, unlinkSync } = require("node:fs");
const { join, dirname } = require("node:path");
const { homedir } = require("node:os");

const CONFIG_DIR = join(homedir(), ".config", "opencode");
const STATE_FILE = join(CONFIG_DIR, "unlimited-identity.json");
const SHIM_DIR = join(process.env.LOCALAPPDATA || join(homedir(), "AppData", "Local"), "opencode-unlimited", "shim");
const SHIM_GUID_FILE = join(SHIM_DIR, "machine-guid.txt");

function ensureDir(path) {
  if (!existsSync(path)) mkdirSync(path, { recursive: true });
}

function newGuid() {
  return randomUUID().toLowerCase();
}

function fingerprint(guid) {
  return createHash("sha256").update(String(guid)).digest("hex").slice(0, 16);
}

function load() {
  if (!existsSync(STATE_FILE)) return null;
  try {
    return JSON.parse(readFileSync(STATE_FILE, "utf8"));
  } catch {
    return null;
  }
}

function save(state) {
  ensureDir(dirname(STATE_FILE));
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2) + "\n", "utf8");
  ensureDir(SHIM_DIR);
  writeFileSync(SHIM_GUID_FILE, state.deviceId + "\n", "utf8");
  return state;
}

function show() {
  const state = load();
  if (!state) {
    return {
      exists: false,
      stateFile: STATE_FILE,
      shimFile: SHIM_GUID_FILE,
      hint: "run identity rotate to mint one",
    };
  }
  return {
    exists: true,
    stateFile: STATE_FILE,
    shimFile: SHIM_GUID_FILE,
    deviceId: state.deviceId,
    fingerprint: fingerprint(state.deviceId),
    generation: Number(state.generation || 0),
    createdAt: state.createdAt || "",
    rotatedAt: state.rotatedAt || "",
    registryTouched: false,
  };
}

function rotate(options = {}) {
  const previous = load();
  const now = new Date().toISOString();
  const deviceId = options.deviceId || newGuid();
  const state = {
    deviceId,
    generation: previous ? Number(previous.generation || 0) + 1 : 1,
    createdAt: (previous && previous.createdAt) || now,
    rotatedAt: now,
    history: [
      ...((previous && Array.isArray(previous.history)) ? previous.history : []).slice(-19),
      previous && previous.deviceId ? { deviceId: previous.deviceId, retiredAt: now } : null,
    ].filter(Boolean),
  };
  save(state);
  return {
    deviceId,
    previous: previous ? previous.deviceId || "" : "",
    generation: state.generation,
    fingerprint: fingerprint(deviceId),
    stateFile: STATE_FILE,
    shimFile: SHIM_GUID_FILE,
    registryTouched: false,
  };
}

function restore() {
  const state = load();
  if (!state) return { restored: false, reason: "no identity state" };
  if (existsSync(SHIM_GUID_FILE)) {
    try {
      unlinkSync(SHIM_GUID_FILE);
    } catch {
      void 0;
    }
  }
  return { restored: true, removed: SHIM_GUID_FILE, stateFile: STATE_FILE, registryTouched: false };
}

function main() {
  const [action, arg] = process.argv.slice(2);
  try {
    if (!action || action === "show") {
      console.log(JSON.stringify(show(), null, 2));
      return;
    }
    if (action === "rotate") {
      console.log(JSON.stringify(rotate({ deviceId: arg || "" }), null, 2));
      return;
    }
    if (action === "restore") {
      console.log(JSON.stringify(restore(), null, 2));
      return;
    }
    if (action === "fingerprint") {
      const state = load();
      console.log(JSON.stringify({ fingerprint: state ? fingerprint(state.deviceId) : "" }));
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

module.exports = { show, rotate, restore, fingerprint, STATE_FILE, SHIM_DIR, SHIM_GUID_FILE };
