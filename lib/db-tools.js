const { DatabaseSync } = require("node:sqlite");

const q = (name) => '"' + String(name).replace(/"/g, '""') + '"';
const norm = (value) => String(value || "").replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();

function tables(db) {
  return db
    .prepare("select name from sqlite_master where type = 'table'")
    .all()
    .map((row) => String(row.name))
    .filter((name) => !name.startsWith("sqlite_"));
}

function columns(db, table) {
  return db.prepare("pragma table_info(" + q(table) + ")").all().map((row) => String(row.name));
}

function firstIndexed(db, names, test) {
  const known = tables(db);
  for (const name of names) {
    if (!known.includes(name)) continue;
    if (test && !test(name)) continue;
    return name;
  }
  return null;
}

function detect(db) {
  const sessionTable = firstIndexed(db, ["session_v2", "session", "sessions"], (name) => columns(db, name).includes("id"));
  const messageTable = firstIndexed(db, ["session_message", "message"], (name) => {
    const cols = columns(db, name);
    return cols.includes("session_id") && cols.includes("data");
  });
  const out = { sessionTable, messageTable, tables: tables(db) };
  if (sessionTable) out.sessionColumns = columns(db, sessionTable);
  if (messageTable) out.messageColumns = columns(db, messageTable);
  return out;
}

function clear(db, scope) {
  const schema = detect(db);
  if (!schema.sessionTable || !schema.messageTable) return "schema not recognised, nothing cleared";

  const session = q(schema.sessionTable);
  const message = q(schema.messageTable);
  const sessionColumns = schema.sessionColumns;
  const messageColumns = schema.messageColumns;
  const projectColumn = sessionColumns.find((name) => /^project_?id$/i.test(name)) || null;
  const idleColumn = sessionColumns.find((name) => /^idle_outcome$/i.test(name)) || null;
  const typeColumn = messageColumns.find((name) => /^type$/i.test(name)) || null;
  const idColumn = messageColumns.find((name) => /^id$/i.test(name)) || null;

  let sessionIds = null;
  if (scope && schema.tables.includes("project_directory") && projectColumn) {
    const dirs = columns(db, "project_directory");
    const dirColumn = dirs.find((name) => /^directory$/i.test(name));
    const projectDirColumn = dirs.find((name) => /^project_?id$/i.test(name));
    if (dirColumn && projectDirColumn) {
      const row = db.prepare(`select ${q(projectDirColumn)} as project_id from project_directory where lower(${q(dirColumn)}) = ?`).get(norm(scope));
      if (row && row.project_id) {
        sessionIds = db
          .prepare(`select ${q("id")} from ${session} where ${q(projectColumn)} = ?`)
          .all(row.project_id)
          .map((entry) => String(entry.id));
      }
    }
  }

  const rows = db.prepare(`select * from ${message} where cast(data as text) like '%provider.free-limit%'`).all();
  const targets = sessionIds ? rows.filter((row) => sessionIds.includes(String(row.session_id))) : rows;

  let cleaned = 0;
  let skipped = 0;
  db.exec("begin");
  try {
    for (const row of targets) {
      let payload;
      try {
        payload = JSON.parse(row.data);
      } catch {
        skipped += 1;
        continue;
      }
      if (!payload || !payload.error || payload.error.type !== "provider.free-limit") {
        skipped += 1;
        continue;
      }
      delete payload.error;
      if (payload.outcome === "failed") payload.outcome = "succeeded";
      if (payload.finish === "error") payload.finish = "stop";
      if (payload.content === undefined) payload.content = [];
      if (!idColumn) {
        skipped += 1;
        continue;
      }
      db.prepare(`update ${message} set data = ? where ${q(idColumn)} = ?`).run(JSON.stringify(payload), row[idColumn]);
      cleaned += 1;
    }

    for (const name of ["session_inbox", "session_pending"]) {
      if (!schema.tables.includes(name)) continue;
      const cols = columns(db, name);
      const jsonCols = cols.filter((column) => /payload|data$/i.test(column));
      for (const column of jsonCols) {
        const bad = db
          .prepare(`select rowid as rid, ${q(column)} as body from ${q(name)} where cast(${q(column)} as text) like '%provider.free-limit%'`)
          .all();
        for (const entry of bad) {
          if (sessionIds && !String(entry.body).includes("ses_")) continue;
          db.prepare(`delete from ${q(name)} where rowid = ?`).run(entry.rid);
        }
      }
    }

    let idleReset = 0;
    if (idleColumn) {
      const stale = db
        .prepare(`select ${q("id")} as id from ${session} where ${q(idleColumn)} = 'failed'`)
        .all()
        .filter((row) => !sessionIds || sessionIds.includes(String(row.id)));
      for (const row of stale) {
        const pending = db
          .prepare(`select count(*) c from ${message} where session_id = ? and cast(data as text) like '%provider.free-limit%'`)
          .get(row.id).c;
        if (pending) continue;
        db.prepare(`update ${session} set ${q(idleColumn)} = 'succeeded' where id = ?`).run(row.id);
        idleReset += 1;
      }
    }
    void typeColumn;
    db.exec("commit");
    return "limit errors cleared: " + cleaned + ", idle flags reset: " + idleReset + (skipped ? ", skipped: " + skipped : "");
  } catch (error) {
    try {
      db.exec("rollback");
    } catch {
      void 0;
    }
    return "clear failed: " + String(error && error.message ? error.message : error);
  }
}

function projectGroups(db) {
  const parent = new Map();
  const find = (value) => {
    let root = value;
    while (parent.get(root) !== root) root = parent.get(root);
    let cursor = value;
    while (parent.get(cursor) !== cursor) {
      const next = parent.get(cursor);
      parent.set(cursor, root);
      cursor = next;
    }
    return root;
  };
  const union = (a, b) => {
    const ra = find(a);
    const rb = find(b);
    if (ra !== rb) parent.set(rb, ra);
  };

  const byDir = new Map();
  const register = (dir, id) => {
    if (!parent.has(id)) parent.set(id, id);
    if (!byDir.has(dir)) byDir.set(dir, []);
    byDir.get(dir).push(id);
  };

  let projects = [];
  try {
    projects = db.prepare("select id, worktree from project").all();
  } catch {
    return [];
  }
  for (const row of projects) {
    const id = String(row.id);
    parent.set(id, id);
    register(norm(row.worktree), id);
  }
  try {
    for (const row of db.prepare("select project_id, directory from project_directory").all()) {
      register(norm(row.directory), String(row.project_id));
    }
  } catch {
    void 0;
  }
  for (const ids of byDir.values()) {
    for (let index = 1; index < ids.length; index++) union(ids[0], ids[index]);
  }

  const groups = new Map();
  for (const id of [...parent.keys()]) {
    const root = find(id);
    if (!groups.has(root)) groups.set(root, []);
    groups.get(root).push(id);
  }
  return [...groups.values()].filter((group) => group.length > 1);
}

function repairProjects(db, schema) {
  const groups = projectGroups(db);
  if (!groups.length || !schema.sessionTable) return { groups: 0, merged: 0, moved: 0 };

  const sessions = q(schema.sessionTable);
  const hasDirs = schema.tables.includes("project_directory");
  const hasWorktrees = schema.tables.includes("worktree");
  const now = Date.now();
  let merged = 0;
  let moved = 0;

  db.exec("begin immediate");
  try {
    for (const group of groups) {
      const scored = group.map((id) => {
        const row = db.prepare("select id, worktree, time_created from project where id = ?").get(id);
        const count = db.prepare(`select count(*) c from ${sessions} where project_id = ?`).get(id).c;
        return { id, count: Number(count) || 0, worktree: row ? String(row.worktree || "") : "", created: Number(row && row.time_created) || 0 };
      });
      scored.sort((a, b) => b.count - a.count || a.created - b.created);
      const keeper = scored[0];
      if (!keeper) continue;

      for (const other of scored.slice(1)) {
        const result = db.prepare(`update ${sessions} set project_id = ? where project_id = ?`).run(keeper.id, other.id);
        moved += Number(result.changes || 0);
        if (hasDirs) {
          db.prepare("update or ignore project_directory set project_id = ? where project_id = ?").run(keeper.id, other.id);
          db.prepare("delete from project_directory where project_id = ?").run(other.id);
        }
        if (hasWorktrees) {
          db.prepare("update or ignore worktree set project_id = ? where project_id = ?").run(keeper.id, other.id);
          db.prepare("delete from worktree where project_id = ?").run(other.id);
        }
        const left = db.prepare(`select count(*) c from ${sessions} where project_id = ?`).get(other.id).c;
        if (Number(left) === 0) {
          db.prepare("delete from project where id = ?").run(other.id);
          merged += 1;
        }
      }

      if (hasDirs && keeper.worktree) {
        const present = db
          .prepare("select count(*) c from project_directory where project_id = ? and lower(directory) = ?")
          .get(keeper.id, keeper.worktree.toLowerCase()).c;
        if (!Number(present)) {
          db.prepare("insert or ignore into project_directory (project_id, directory, time_created) values (?, ?, ?)").run(keeper.id, keeper.worktree, now);
        }
      }
    }
    db.exec("commit");
    return { groups: groups.length, merged, moved };
  } catch (error) {
    try {
      db.exec("rollback");
    } catch {
      void 0;
    }
    throw error;
  }
}

function verify(db, apply) {
  const schema = detect(db);
  if (!schema.sessionTable || !schema.messageTable) return ["schema not recognised, nothing checked"];
  const session = q(schema.sessionTable);
  const message = q(schema.messageTable);
  const sessionColumns = schema.sessionColumns;
  const messageColumns = schema.messageColumns;
  const one = (sql, ...args) => db.prepare(sql).get(...args);
  const problems = [];
  const append = (kind, count, fixed) => problems.push({ kind, count, fixed: fixed || 0 });

  const projectColumn = sessionColumns.find((name) => /^project_?id$/i.test(name));
  if (projectColumn && schema.tables.includes("project")) {
    const orphans = one(`select count(*) c from ${session} where ${q(projectColumn)} not in (select id from project)`).c;
    if (orphans) append("orphan sessions", orphans, 0);
  }

  const typeColumn = messageColumns.find((name) => /^type$/i.test(name));
  const idColumn = messageColumns.find((name) => /^id$/i.test(name));
  if (typeColumn && idColumn) {
    const badIdle = db
      .prepare(`select ${q(idColumn)} as id, data from ${message} where ${q(typeColumn)} = 'idle'`)
      .all()
      .filter((row) => {
        try {
          return !["succeeded", "failed"].includes(JSON.parse(row.data).outcome);
        } catch {
          return true;
        }
      });
    let fixed = 0;
    if (badIdle.length && apply) {
      db.exec("begin");
      for (const row of badIdle) {
        let payload = {};
        try {
          payload = JSON.parse(row.data);
        } catch {
          payload = {};
        }
        payload.outcome = "succeeded";
        delete payload.error;
        db.prepare(`update ${message} set data = ? where ${q(idColumn)} = ?`).run(JSON.stringify(payload), row.id);
        fixed += 1;
      }
      db.exec("commit");
    }
    if (badIdle.length) append("invalid idle outcome", badIdle.length, fixed);
  }

  const revertColumn = sessionColumns.find((name) => /^revert$/i.test(name));
  if (revertColumn && idColumn) {
    const dangling = db
      .prepare(`select id, ${q(revertColumn)} as revert from ${session} where ${q(revertColumn)} is not null`)
      .all()
      .filter((row) => {
        try {
          const target = JSON.parse(row.revert).messageID;
          return !one(`select count(*) c from ${message} where ${q(idColumn)} = ?`, target).c;
        } catch {
          return true;
        }
      });
    let fixed = 0;
    if (dangling.length && apply) {
      db.exec("begin");
      for (const row of dangling) {
        db.prepare(`update ${session} set ${q(revertColumn)} = null where id = ?`).run(row.id);
        fixed += 1;
      }
      db.exec("commit");
    }
    if (dangling.length) append("revert points at a missing message", dangling.length, fixed);
  }

  const limitRows = db.prepare(`select data from ${message} where cast(data as text) like '%provider.free-limit%'`).all();
  let stuck = 0;
  for (const row of limitRows) {
    try {
      const payload = JSON.parse(row.data);
      if (payload && payload.error && payload.error.type === "provider.free-limit") stuck += 1;
    } catch {
      void 0;
    }
  }
  if (stuck) append("stored free-limit errors, run clear", stuck, 0);

  const folderGroups = projectGroups(db);
  if (folderGroups.length) {
    let fixed = 0;
    if (apply) {
      const result = repairProjects(db, schema);
      fixed = result.merged;
    }
    append("duplicate project folders", folderGroups.length, fixed);
  }

  if (!problems.length) return ["no problems found"];
  return problems.map((item) => item.kind + ": " + item.count + (apply ? " (fixed " + item.fixed + ")" : ""));
}

function main() {
  const [action, dbPath, extra] = process.argv.slice(2);
  if (!action || !dbPath) {
    console.log(JSON.stringify({ error: "usage: db-tools.js <clear|verify> <db> [scope|fix]" }));
    process.exitCode = 2;
    return;
  }
  const db = new DatabaseSync(dbPath);
  try {
    db.exec("pragma busy_timeout = 8000");
    if (action === "clear") {
      console.log(clear(db, extra || ""));
      return;
    }
    if (action === "verify") {
      const lines = verify(db, String(extra || "") === "fix");
      for (const line of lines) console.log(line);
      return;
    }
    console.log(JSON.stringify({ error: "unknown action: " + action }));
    process.exitCode = 2;
  } catch (error) {
    console.log("error: " + String(error && error.message ? error.message : error));
    process.exitCode = 1;
  } finally {
    db.close();
  }
}

if (require.main === module) main();

module.exports = { clear, verify, detect, repairProjects, projectGroups };
