const { DatabaseSync } = require("node:sqlite");
const { detectSchema, listSessions, quoteIdent, findDatabase } = require("./oc-info.js");

const ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const bytes = new Uint8Array(14);
const ID_COLUMNS = ["parent_id", "fork_session_id", "parentID", "forkID"];

let lastMs = 0;
let counter = 0;

function randomSuffix() {
  globalThis.crypto.getRandomValues(bytes);
  let out = "";
  for (const value of bytes) out += ALPHABET[value % 62];
  return out;
}

function makeId(prefix, inverted, ms) {
  const now = Number(ms) || Date.now();
  if (now !== lastMs) {
    lastMs = now;
    counter = 0;
  }
  counter += 1;
  const raw = BigInt(now) * 0x1000n + BigInt(counter);
  const value = inverted ? ~raw : raw;
  let hex = "";
  for (let index = 0; index < 6; index++) {
    const byte = Number((value >> BigInt(40 - 8 * index)) & 0xffn);
    hex += byte.toString(16).padStart(2, "0");
  }
  return prefix + hex + randomSuffix();
}

function sessionId(ms) {
  return makeId("ses_", true, ms);
}

function messageId(ms) {
  return makeId("msg_", false, ms);
}

function reid(handle, oldId, options = {}) {
  const schema = detectSchema(handle, { deep: true });
  if (!schema.sessionTable) throw new Error("no session table in this database");

  const table = quoteIdent(schema.sessionTable);
  const row = handle.prepare("select * from " + table + " where id = ?").get(oldId);
  if (!row) throw new Error("session not found: " + oldId);

  const newId = options.newId || sessionId(options.now || Date.now());
  if (handle.prepare("select 1 from " + table + " where id = ?").get(newId)) {
    throw new Error("target id already exists: " + newId);
  }

  const sets = ["id = ?"];
  for (const name of schema.forkColumns) sets.push(quoteIdent(name) + " = null");
  const selfColumns = schema.forkColumns.filter((name) => ID_COLUMNS.includes(name));

  handle.exec("begin");
  try {
    handle.exec("pragma defer_foreign_keys = ON");
    handle.prepare("update " + table + " set " + sets.join(", ") + " where id = ?").run(newId, oldId);
    let moved = 0;
    const touched = [];
    for (const ref of schema.refs) {
      const result = handle
        .prepare("update " + quoteIdent(ref.table) + " set " + quoteIdent(ref.column) + " = ? where " + quoteIdent(ref.column) + " = ?")
        .run(newId, oldId);
      const changes = Number(result.changes || 0);
      if (changes > 0) touched.push(ref.table + "." + ref.column + "=" + changes);
      moved += changes;
    }
    for (const column of selfColumns) {
      handle.prepare("update " + table + " set " + quoteIdent(column) + " = ? where " + quoteIdent(column) + " = ?").run(newId, oldId);
    }
    handle.exec("commit");
    return {
      oldId,
      newId,
      sessionTable: schema.sessionTable,
      moved,
      touched,
      refs: schema.refs.map((ref) => ref.table + "." + ref.column),
    };
  } catch (error) {
    try {
      handle.exec("rollback");
    } catch {
      void 0;
    }
    throw error;
  }
}

function scan(handle, sessionArg) {
  const schema = detectSchema(handle, { deep: true });
  let row = null;
  if (schema.sessionTable && sessionArg) {
    row = handle.prepare("select id from " + quoteIdent(schema.sessionTable) + " where id = ?").get(sessionArg) || null;
  }
  return { schema, found: row };
}

function main() {
  const [dbArg, action, sessionArg, extra] = process.argv.slice(2);
  if (!action) {
    console.log(JSON.stringify({ error: "usage: session-reid.js <db|-> <reid|list|scan|schema> [args]" }));
    process.exitCode = 2;
    return;
  }
  const dbPath = !dbArg || dbArg === "-" ? findDatabase() : dbArg;
  if (!dbPath) {
    console.log(JSON.stringify({ error: "no database found" }));
    process.exitCode = 1;
    return;
  }

  if (action === "list") {
    console.log(JSON.stringify(listSessions(dbPath, sessionArg), null, 2));
    return;
  }

  const handle = new DatabaseSync(dbPath);
  try {
    if (action === "schema") {
      console.log(JSON.stringify(detectSchema(handle, { deep: true }), null, 2));
      return;
    }
    if (action === "scan") {
      console.log(JSON.stringify(scan(handle, sessionArg), null, 2));
      return;
    }
    if (action === "reid") {
      if (!sessionArg) throw new Error("reid needs a session id");
      console.log(JSON.stringify(reid(handle, sessionArg, { newId: extra }), null, 2));
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

module.exports = { sessionId, messageId, reid, scan };
