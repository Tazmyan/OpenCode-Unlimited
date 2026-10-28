import { createHash } from "node:crypto"
import { readFileSync, statSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const IDENTITY_PATHS = [
  process.env.OPENCODE_UNLIMITED_IDENTITY || "",
  join(homedir(), ".config", "opencode", "identity.json"),
  process.env.XDG_CONFIG_HOME ? join(process.env.XDG_CONFIG_HOME, "opencode", "identity.json") : "",
  join(homedir(), ".opencode", "identity.json"),
].filter(Boolean)

const STATE_PATHS = [
  process.env.OPENCODE_UNLIMITED_STATE || "",
  join(homedir(), ".config", "opencode", "unlimited.json"),
  process.env.XDG_CONFIG_HOME ? join(process.env.XDG_CONFIG_HOME, "opencode", "unlimited.json") : "",
].filter(Boolean)

const PROJECT_ID_RE = /^[0-9a-f]{40}$/
const CACHE_MS = 1000

const SESSION_HEADERS = [
  "x-opencode-session-id",
  "x-opencode-session",
  "x-session-affinity",
  "X-Session-Id",
]

let identityId = null
let identityPath = null
let identityMtime = 0
let identityStat = 0
let identityWarned = false

let stateSalt = ""
let stateEnabled = true
let stateOverrides = {}
let statePath = null
let stateMtime = 0
let stateStat = 0

const affinityCache = new Map()

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
    if (file === identityPath && stat.mtimeMs === identityMtime && identityId) return identityId

    let parsed
    try {
      parsed = JSON.parse(readFileSync(file, "utf8").replace(/^\uFEFF/, ""))
    } catch {
      continue
    }
    const raw = typeof parsed?.projectId === "string" ? parsed.projectId.trim().toLowerCase() : ""
    if (!PROJECT_ID_RE.test(raw)) continue

    identityId = raw
    identityPath = file
    identityMtime = stat.mtimeMs
    return raw
  }
  return null
}

function readState() {
  for (const file of STATE_PATHS) {
    let stat
    try {
      stat = statSync(file)
    } catch {
      continue
    }
    if (!stat.isFile()) continue
    if (file === statePath && stat.mtimeMs === stateMtime) return

    let parsed
    try {
      parsed = JSON.parse(readFileSync(file, "utf8").replace(/^\uFEFF/, ""))
    } catch {
      continue
    }
    const affinity = parsed?.affinity
    stateEnabled = affinity?.enabled !== false
    stateSalt = typeof affinity?.salt === "string" ? affinity.salt : ""
    const map = affinity?.overrides
    stateOverrides = map && typeof map === "object" ? map : {}
    statePath = file
    stateMtime = stat.mtimeMs
    affinityCache.clear()
    return
  }
}

function currentProjectId() {
  const now = Date.now()
  if (identityId && now - identityStat < CACHE_MS) return identityId
  identityStat = now
  return readIdentity() ?? identityId
}

function currentState() {
  const now = Date.now()
  if (now - stateStat >= CACHE_MS) {
    stateStat = now
    readState()
  }
}

function syntheticAffinity(sessionID) {
  const override = stateOverrides[sessionID]
  const seed = typeof override === "string" && override.slice(0, 4) === "ses_" ? override : `${sessionID}\u0000${stateSalt}`
  const cached = affinityCache.get(seed)
  if (cached) return cached
  const digest = createHash("sha256").update(seed).digest("hex")
  const value = "ses_" + digest
  if (affinityCache.size > 4096) affinityCache.clear()
  affinityCache.set(seed, value)
  return value
}

function setHeader(headers, name, value) {
  if (typeof headers?.set === "function") {
    headers.set(name, value)
    return
  }
  if (!headers || typeof headers !== "object") return
  const existing = Object.keys(headers).find((key) => key.toLowerCase() === name.toLowerCase())
  if (existing) {
    headers[existing] = value
    return
  }
  headers[name] = value
}

function applyHeaders(headers, sessionID, ctx) {
  try {
    const projectId = currentProjectId()
    if (!projectId) {
      if (!identityWarned) {
        identityWarned = true
        emit(ctx, "warn", "identity.json missing or invalid; x-opencode-project untouched", {
          looked: IDENTITY_PATHS,
        })
      }
    } else {
      identityWarned = false
      setHeader(headers, "x-opencode-project", projectId)
    }

    currentState()
    if (!stateEnabled || !stateSalt || !sessionID) return
    const affinity = syntheticAffinity(sessionID)
    for (const name of SESSION_HEADERS) setHeader(headers, name, affinity)
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
          applyHeaders(event?.headers, event?.sessionID, ctx)
        })
        registered.push("model.request")
      }
    } catch (error) {
      emit(ctx, "warn", "model.request hook unavailable", { error: String(error) })
    }

    try {
      if (typeof ctx?.session?.hook === "function") {
        await ctx.session.hook("http.request", (event) => {
          const headers = event?.request?.headers
          applyHeaders(headers, event?.sessionID, ctx)
        })
        registered.push("http.request")
      }
    } catch (error) {
      emit(ctx, "warn", "http.request hook unavailable", { error: String(error) })
    }

    readState()
    emit(ctx, "info", "unlimited-shield loaded", {
      projectId: currentProjectId(),
      affinity: stateEnabled && stateSalt ? "on" : "off",
      hooks: registered,
    })
  },
}
