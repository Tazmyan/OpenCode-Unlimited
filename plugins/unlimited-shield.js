import { readFileSync, statSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const IDENTITY_PATHS = [
  process.env.OPENCODE_UNLIMITED_IDENTITY || "",
  join(homedir(), ".config", "opencode", "identity.json"),
  process.env.XDG_CONFIG_HOME ? join(process.env.XDG_CONFIG_HOME, "opencode", "identity.json") : "",
  join(homedir(), ".opencode", "identity.json"),
].filter(Boolean)

const PROJECT_ID_RE = /^[0-9a-f]{40}$/
const MTIME_CHECK_MS = 1000

let cachedId = null
let cachedPath = null
let cachedMtime = 0
let lastStat = 0
let warnedMissing = false

function emit(ctx, level, message, extra) {
  try {
    if (ctx?.app?.log) {
      ctx.app.log({ body: { service: "unlimited-shield", level, message, extra } })
    }
  } catch {
    return
  }
}

function readIdentity() {
  for (const file of IDENTITY_PATHS) {
    let stat
    try {
      stat = statSync(file)
    } catch {
      continue
    }
    if (!stat.isFile()) continue
    if (file === cachedPath && stat.mtimeMs === cachedMtime && cachedId) return cachedId

    let parsed
    try {
      parsed = JSON.parse(readFileSync(file, "utf8").replace(/^\uFEFF/, ""))
    } catch {
      continue
    }
    const raw = typeof parsed?.projectId === "string" ? parsed.projectId.trim().toLowerCase() : ""
    if (!PROJECT_ID_RE.test(raw)) continue

    cachedId = raw
    cachedPath = file
    cachedMtime = stat.mtimeMs
    return raw
  }
  return null
}

function currentProjectId() {
  const now = Date.now()
  if (cachedId && now - lastStat < MTIME_CHECK_MS) return cachedId
  lastStat = now
  return readIdentity() ?? cachedId
}

function applyHeaders(target, ctx) {
  try {
    const id = currentProjectId()
    if (!id) {
      if (!warnedMissing) {
        warnedMissing = true
        emit(ctx, "warn", "identity.json missing or invalid; x-opencode-project untouched", {
          looked: IDENTITY_PATHS,
        })
      }
      return
    }
    warnedMissing = false

    if (target && typeof target.set === "function") {
      target.set("x-opencode-project", id)
      return
    }
    if (target && typeof target === "object") {
      target["x-opencode-project"] = id
    }
  } catch (error) {
    emit(ctx, "error", "header injection failed", { error: String(error) })
  }
}

export default {
  id: "unlimited-shield",

  async setup(ctx) {
    const registered = []

    try {
      if (typeof ctx?.session?.hook === "function") {
        await ctx.session.hook("model.request", (event) => {
          applyHeaders(event?.headers, ctx)
        })
        registered.push("model.request")
      }
    } catch (error) {
      emit(ctx, "warn", "model.request hook unavailable", { error: String(error) })
    }

    try {
      if (typeof ctx?.session?.hook === "function") {
        await ctx.session.hook("http.request", (event) => {
          applyHeaders(event?.request?.headers, ctx)
        })
        registered.push("http.request")
      }
    } catch (error) {
      emit(ctx, "warn", "http.request hook unavailable", { error: String(error) })
    }

    const id = currentProjectId()
    emit(ctx, id ? "info" : "warn", "unlimited-shield loaded", {
      projectId: id,
      hooks: registered,
      identityPaths: IDENTITY_PATHS,
    })
  },
}
