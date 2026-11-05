const { DatabaseSync } = require("node:sqlite");
const { readFileSync, existsSync } = require("node:fs");
const { join } = require("node:path");
const { homedir } = require("node:os");
const { detectSchema, quoteIdent, findDatabase } = require("./oc-info.js");

const CACHE_CANDIDATES = [
  join(homedir(), ".cache", "opencode", "models.json"),
  join(process.env.LOCALAPPDATA || "", "opencode", "models.json"),
  join(homedir(), "AppData", "Local", "opencode", "models.json"),
];

const AUTH_CANDIDATES = [
  join(homedir(), ".local", "share", "opencode", "auth.json"),
  join(process.env.LOCALAPPDATA || "", "opencode", "auth.json"),
  join(homedir(), "AppData", "Local", "opencode", "auth.json"),
];

function firstExisting(paths) {
  for (const path of paths) {
    if (path && existsSync(path)) return path;
  }
  return null;
}

function loadRegistry() {
  const path = firstExisting(CACHE_CANDIDATES);
  if (!path) return { path: null, providers: {} };
  try {
    const raw = JSON.parse(readFileSync(path, "utf8"));
    return { path, providers: raw.providers || raw || {} };
  } catch {
    return { path, providers: {} };
  }
}

function loadAuth() {
  const path = firstExisting(AUTH_CANDIDATES);
  if (!path) return { path: null, ids: [] };
  try {
    const raw = JSON.parse(readFileSync(path, "utf8"));
    return { path, ids: Object.keys(raw || {}) };
  } catch {
    return { path, ids: [] };
  }
}

function providerModels(providers, providerId) {
  const provider = providers[providerId];
  if (!provider) return null;
  const models = provider.models || {};
  return Array.isArray(models) ? models : Object.values(models);
}

function modelOf(providers, providerId, modelId) {
  const models = providerModels(providers, providerId);
  if (!models) return null;
  return models.find((row) => row && String(row.id) === modelId) || null;
}

function parseSpec(spec) {
  const text = String(spec || "").trim();
  if (!text) throw new Error("empty model spec");
  const hash = text.indexOf("#");
  const head = hash >= 0 ? text.slice(0, hash) : text;
  const variant = hash >= 0 ? text.slice(hash + 1).trim() : "";
  const slash = head.indexOf("/");
  if (slash <= 0 || slash === head.length - 1) {
    throw new Error("model spec must look like provider/model or provider/model#variant");
  }
  return { providerID: head.slice(0, slash), id: head.slice(slash + 1), variant };
}

function modelJson(parsed) {
  const out = { id: parsed.id, providerID: parsed.providerID };
  if (parsed.variant) out.variant = parsed.variant;
  return out;
}

function normalizeDirectory(value) {
  return String(value || "").replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();
}

function sessionRows(handle, schema) {
  if (!schema.sessionTable) return [];
  const table = quoteIdent(schema.sessionTable);
  const select = ["id"];
  if (schema.directoryColumn) select.push(quoteIdent(schema.directoryColumn) + " as directory");
  if (schema.titleColumn) select.push(quoteIdent(schema.titleColumn) + " as title");
  return handle.prepare("select " + select.join(", ") + " from " + table).all();
}

function resolveTarget(handle, schema, target) {
  const text = String(target || "").trim();
  if (!text) throw new Error("name a session id or a folder");
  if (text.startsWith("ses_")) {
    return { kind: "session", ids: [text], directory: "" };
  }
  const want = normalizeDirectory(text);
  const rows = sessionRows(handle, schema).filter((row) => {
    const value = normalizeDirectory(row.directory);
    return value === want || value.startsWith(want + "/");
  });
  if (!rows.length) throw new Error("no sessions for folder: " + text);
  return { kind: "folder", ids: rows.map((row) => String(row.id)), directory: text };
}

function readModel(handle, schema, id) {
  if (!schema.sessionTable) throw new Error("no session table");
  const table = quoteIdent(schema.sessionTable);
  const row = handle.prepare("select model from " + table + " where id = ?").get(id);
  if (!row) throw new Error("session not found: " + id);
  let parsed = null;
  try {
    parsed = row.model ? JSON.parse(String(row.model)) : null;
  } catch {
    parsed = { raw: String(row.model) };
  }
  return parsed;
}

function writeModel(handle, schema, id, value) {
  if (!schema.sessionTable) throw new Error("no session table");
  const table = quoteIdent(schema.sessionTable);
  const row = handle.prepare("select id from " + table + " where id = ?").get(id);
  if (!row) throw new Error("session not found: " + id);
  const text = JSON.stringify(value);
  handle.exec("begin");
  try {
    handle.prepare("update " + table + " set model = ? where id = ?").run(text, id);
    handle.exec("commit");
  } catch (error) {
    try {
      handle.exec("rollback");
    } catch {
      void 0;
    }
    throw error;
  }
  return text;
}

function availability(providers, authIds, providerID, modelId) {
  const models = providerModels(providers, providerID);
  const authed = authIds.includes(providerID);
  const model = modelOf(providers, providerID, modelId);
  return { authed, modelFound: Boolean(model), models: models ? models.length : 0 };
}

function setModel(handle, options) {
  const schema = detectSchema(handle, { deep: false });
  const parsed = parseSpec(options.spec);
  const registry = loadRegistry();
  const auth = loadAuth();
  const check = availability(registry.providers, auth.ids, parsed.providerID, parsed.id);

  if (!registry.path) throw new Error("model registry not found, run opencode once to populate the cache");
  if (!check.models) throw new Error("unknown provider: " + parsed.providerID);
  if (!check.modelFound) throw new Error("model not in registry: " + parsed.providerID + "/" + parsed.id);
  if (!check.authed && !options.force) {
    throw new Error("provider has no credentials in auth.json: " + parsed.providerID);
  }

  const value = modelJson(parsed);
  const target = resolveTarget(handle, schema, options.target);
  const changed = [];
  for (const id of target.ids) {
    const before = readModel(handle, schema, id);
    writeModel(handle, schema, id, value);
    changed.push({ id, before, after: value });
  }
  return {
    spec: parsed.providerID + "/" + parsed.id + (parsed.variant ? "#" + parsed.variant : ""),
    applied: value,
    kind: target.kind,
    directory: target.directory,
    provider: {
      credentials: check.authed,
      models: check.models,
    },
    changed,
  };
}

function listModels(handle) {
  const registry = loadRegistry();
  const auth = loadAuth();
  const out = [];
  for (const providerID of auth.ids) {
    const models = providerModels(registry.providers, providerID) || [];
    const priced = models.map((row) => {
      const cost = (row && row.cost) || {};
      return {
        id: String(row.id),
        name: String(row.name || row.id),
        free: Number(cost.input || 0) === 0 && Number(cost.output || 0) === 0,
        context: Number((row.limit && row.limit.context) || 0),
        output: Number((row.limit && row.limit.output) || 0),
        variant: row.variants ? Object.keys(row.variants) : [],
      };
    });
    out.push({ providerID, models: priced });
  }
  return { registry: registry.path, auth: auth.path, providers: out };
}

function main() {
  const [dbArg, action, a, b] = process.argv.slice(2);
  if (!action) {
    console.log(JSON.stringify({ error: "usage: model-switch.js <db|-> <list|get|set> [args]" }));
    process.exitCode = 2;
    return;
  }
  const dbPath = !dbArg || dbArg === "-" ? findDatabase() : dbArg;
  if (!dbPath) {
    console.log(JSON.stringify({ error: "no database found" }));
    process.exitCode = 1;
    return;
  }
  const handle = new DatabaseSync(dbPath);
  try {
    if (action === "list") {
      console.log(JSON.stringify(listModels(handle), null, 2));
      return;
    }
    if (action === "get") {
      const schema = detectSchema(handle, { deep: false });
      const target = resolveTarget(handle, schema, a);
      const models = target.ids.map((id) => ({ id, model: readModel(handle, schema, id) }));
      console.log(JSON.stringify({ kind: target.kind, directory: target.directory, sessions: models }, null, 2));
      return;
    }
    if (action === "set") {
      if (!a || !b) throw new Error("set needs a target and a provider/model spec");
      console.log(JSON.stringify(setModel(handle, { target: a, spec: b, force: false }), null, 2));
      return;
    }
    console.log(JSON.stringify({ error: "unknown action: " + action }));
    process.exitCode = 2;
  } catch (error) {
    console.log(JSON.stringify({ error: String(error && error.message ? error.message : error) }));
    process.exitCode = 1;
  } finally {
    handle.close();
  }
}

if (require.main === module) main();

module.exports = { parseSpec, modelJson, setModel, listModels, loadRegistry, loadAuth, resolveTarget };
