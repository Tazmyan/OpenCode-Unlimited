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

function countRows(handle, table, column, value) {
  const sql = "select count(*) c from " + quoteIdent(table) + " where " + quoteIdent(column) + " = ?";
  const row = handle.prepare(sql).get(value);
  return Number(row && row.c ? row.c : 0);
}

function messageRef(schema) {
  const byName = (name) => schema.refs.find((ref) => ref.table === name) || null;
  return byName("session_message") || byName("message") || byName("messages");
}

function stats(handle, schema, value) {
  let refs = 0;
  for (const ref of schema.refs) refs += countRows(handle, ref.table, ref.column, value);
  const table = messageRef(schema);
  return { refs, messages: table ? countRows(handle, table.table, table.column, value) : 0 };
}

function messageSeqColumn(handle, table) {
  const info = handle.prepare("pragma table_info(" + quoteIdent(table) + ")").all();
  return info.some((field) => String(field.name) === "seq") ? "seq" : null;
}

function ensureSequence(handle, schema, value) {
  const sequence = schema.sequence;
  const message = messageRef(schema);
  if (!sequence || !message) return null;
  const seqName = messageSeqColumn(handle, message.table);
  if (!seqName) return null;
  const table = quoteIdent(sequence.table);
  const aggregate = quoteIdent(sequence.column);
  const seqColumn = quoteIdent(sequence.seqColumn);
  const row = handle.prepare("select " + seqColumn + " v from " + table + " where " + aggregate + " = ?").get(value);
  const top = handle
    .prepare(
      "select max(" +
        quoteIdent(seqName) +
        ") m from " +
        quoteIdent(message.table) +
        " where " +
        quoteIdent(message.column) +
        " = ?",
    )
    .get(value);
  const needed = top && top.m !== null && top.m !== undefined ? Number(top.m) : null;
  if (!row) {
    if (needed === null) return null;
    handle.prepare("insert into " + table + " (" + aggregate + ", " + seqColumn + ") values (?, ?)").run(value, needed);
    return needed;
  }
  if (needed !== null && Number(row.v) < needed) {
    handle.prepare("update " + table + " set " + seqColumn + " = ? where " + aggregate + " = ?").run(needed, value);
    return needed;
  }
  return null;
}

function reidOne(handle, oldId, schema, options) {
  const table = quoteIdent(schema.sessionTable);
  const row = handle.prepare("select id from " + table + " where id = ?").get(oldId);
  if (!row) throw new Error("session not found: " + oldId);

  const newId = options.newId || sessionId(options.now || Date.now());
  if (handle.prepare("select 1 from " + table + " where id = ?").get(newId)) {
    throw new Error("target id already exists: " + newId);
  }

  const sets = ["id = ?"];
  for (const name of schema.forkColumns) sets.push(quoteIdent(name) + " = null");
  const selfColumns = schema.forkColumns.filter((name) => ID_COLUMNS.includes(name));

  handle.exec("begin immediate");
  try {
    handle.exec("pragma defer_foreign_keys = ON");
    const before = stats(handle, schema, oldId);

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

    const after = stats(handle, schema, newId);
    const leftover = stats(handle, schema, oldId);
    if (after.refs !== before.refs || after.messages !== before.messages || leftover.refs !== 0 || moved !== before.refs) {
      throw new Error(
        "row count mismatch for " +
          oldId +
          ": before=" +
          before.refs +
          " after=" +
          after.refs +
          " leftover=" +
          leftover.refs +
          " moved=" +
          moved,
      );
    }

    const sequence = ensureSequence(handle, schema, newId);

    handle.exec("commit");
    return {
      oldId,
      newId,
      sessionTable: schema.sessionTable,
      moved,
      messages: before.messages,
      refs: before.refs,
      sequence,
      touched,
      refColumns: schema.refs.map((ref) => ref.table + "." + ref.column),
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

function reid(handle, oldId, options = {}) {
  const schema = detectSchema(handle, { deep: true });
  if (!schema.sessionTable) throw new Error("no session table in this database");
  return reidOne(handle, oldId, schema, options);
}

function normalizePath(value) {
  return String(value || "").replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();
}

function escapeLike(value) {
  return value.replace(/([%_!])/g, "!$1");
}

function sessionsUnder(handle, schema, target) {
  const table = quoteIdent(schema.sessionTable);
  const column = schema.directoryColumn;
  if (!column) throw new Error("no directory column in this database");
  const norm = "replace(lower(" + quoteIdent(column) + "), '\\', '/')";
  const want = normalizePath(target);
  if (!want) throw new Error("reidAll needs a folder");
  const sql =
    "select id from " +
    table +
    " where rtrim(" +
    norm +
    ", '/') = ? or rtrim(" +
    norm +
    ", '/') like ? escape '!' order by " +
    (schema.timeColumn ? quoteIdent(schema.timeColumn) : "rowid") +
    " asc";
  const rows = handle.prepare(sql).all(want, escapeLike(want) + "/%");
  return rows.map((row) => String(row.id));
}

function reidAll(handle, target, options = {}) {
  const schema = detectSchema(handle, { deep: true });
  if (!schema.sessionTable) throw new Error("no session table in this database");

  let ids = sessionsUnder(handle, schema, target);
  const total = ids.length;
  if (options.limit > 0) ids = ids.slice(0, Number(options.limit));

  if (options.dryRun) {
    const rows = [];
    for (const id of ids) {
      const value = stats(handle, schema, id);
      rows.push({ oldId: id, messages: value.messages, refs: value.refs, bytes: sessionBytes(handle, schema, id) });
    }
    return { dryRun: true, directory: normalizePath(target), total, selected: ids.length, results: rows, failed: [] };
  }

  const results = [];
  const failed = [];
  for (const id of ids) {
    try {
      results.push(reidOne(handle, id, schema, { now: options.now }));
    } catch (error) {
      failed.push({ oldId: id, error: String(error && error.message ? error.message : error) });
    }
  }
  return {
    dryRun: false,
    directory: normalizePath(target),
    total,
    selected: ids.length,
    reid: results.length,
    failed,
    messages: results.reduce((sum, item) => sum + item.messages, 0),
    refs: results.reduce((sum, item) => sum + item.refs, 0),
    rows: results.reduce((sum, item) => sum + item.moved, 0),
    results: results.map((item) => ({ oldId: item.oldId, newId: item.newId, messages: item.messages, refs: item.refs, moved: item.moved })),
  };
}

function sessionBytes(handle, schema, value) {
  let total = 0;
  for (const ref of schema.refs) {
    try {
      const sql = "select sum(length(cast(data as text))) s from " + quoteIdent(ref.table) + " where " + quoteIdent(ref.column) + " = ?";
      const row = handle.prepare(sql).get(value);
      total += Number(row && row.s ? row.s : 0);
    } catch {
      void 0;
    }
  }
  return total;
}

function scan(handle, sessionArg) {
  const schema = detectSchema(handle, { deep: true });
  let row = null;
  if (schema.sessionTable && sessionArg) {
    row = handle.prepare("select id from " + quoteIdent(schema.sessionTable) + " where id = ?").get(sessionArg) || null;
  }
  return { schema, found: row };
}

function readFlags(argv) {
  const flags = { dryRun: false, limit: 0 };
  const positional = [];
  for (const item of argv) {
    if (item === "--dry" || item === "-n") flags.dryRun = true;
    else if (item.startsWith("--limit=")) flags.limit = Number(item.slice(8)) || 0;
    else if (item) positional.push(item);
  }
  return { flags, positional };
}

function main() {
  const [dbArg, action, ...rest] = process.argv.slice(2);
  if (!action) {
    console.log(JSON.stringify({ error: "usage: session-reid.js <db|-> <reid|reid-all|list|scan|schema> [args]" }));
    process.exitCode = 2;
    return;
  }
  const { flags, positional } = readFlags(rest);
  const dbPath = !dbArg || dbArg === "-" ? findDatabase() : dbArg;
  if (!dbPath) {
    console.log(JSON.stringify({ error: "no database found" }));
    process.exitCode = 1;
    return;
  }

  if (action === "list") {
    console.log(JSON.stringify(listSessions(dbPath, positional[0]), null, 2));
    return;
  }

  const handle = new DatabaseSync(dbPath);
  try {
    handle.exec("pragma busy_timeout = 8000");
    if (action === "schema") {
      console.log(JSON.stringify(detectSchema(handle, { deep: true }), null, 2));
      return;
    }
    if (action === "scan") {
      console.log(JSON.stringify(scan(handle, positional[0]), null, 2));
      return;
    }
    if (action === "reid") {
      if (!positional[0]) throw new Error("reid needs a session id");
      console.log(JSON.stringify(reid(handle, positional[0], { newId: positional[1] }), null, 2));
      return;
    }
    if (action === "reid-all") {
      if (!positional[0]) throw new Error("reid-all needs a folder");
      console.log(JSON.stringify(reidAll(handle, positional[0], flags), null, 2));
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

module.exports = { sessionId, messageId, reid, reidAll, reidOne, sessionsUnder, scan };
