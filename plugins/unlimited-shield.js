import { createHash } from "node:crypto"
import { readFileSync, statSync, writeFileSync, mkdirSync, existsSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"

const CONFIG_DIR = process.env.XDG_CONFIG_HOME
  ? join(process.env.XDG_CONFIG_HOME, "opencode")
  : join(homedir(), ".config", "opencode")

const IDENTITY_FILE = process.env.OPENCODE_UNLIMITED_IDENTITY || join(CONFIG_DIR, "identity.json")
const STATE_FILE = process.env.OPENCODE_UNLIMITED_STATE || join(CONFIG_DIR, "unlimited.json")
const MARKER_FILE = join(CONFIG_DIR, "unlimited-shield.state.json")

const PROJECT_ID_RE = /^[0-9a-f]{40}$/
const CACHE_MS = 1000
const AFFINITY_HEADERS = ["x-opencode-session-id", "x-opencode-session", "x-session-affinity", "x-session-id"]

let identityId = null
let identityAt = 0
let stateAt = 0
let salt = ""
let affinityOn = true
let overrides = {}
const affinityCache = new Map()

function readJson(file) {
  try {
    const stat = statSync(file)
    if (!stat.isFile()) return null
    return JSON.parse(readFileSync(file, "utf8").replace(/^\uFEFF/, ""))
  } catch {
    return null
  }
}

function projectId() {
  const now = Date.now()
  if (now - identityAt < CACHE_MS) return identityId
  identityAt = now
  const parsed = readJson(IDENTITY_FILE)
  const raw = typeof parsed?.projectId === "string" ? parsed.projectId.trim().toLowerCase() : ""
  identityId = PROJECT_ID_RE.test(raw) ? raw : null
  return identityId
}

function loadState() {
  const now = Date.now()
  if (now - stateAt < CACHE_MS) return
  stateAt = now
  const parsed = readJson(STATE_FILE)
  const affinity = parsed?.affinity
  affinityOn = affinity?.enabled !== false
  salt = typeof affinity?.salt === "string" ? affinity.salt : ""
  overrides = affinity?.overrides && typeof affinity.overrides === "object" ? affinity.overrides : {}
  affinityCache.clear()
}

function affinityFor(sessionID) {
  const pinned = overrides[sessionID]
  const seed = typeof pinned === "string" && pinned.startsWith("ses_") ? pinned : sessionID + "\u0000" + salt
  const cached = affinityCache.get(seed)
  if (cached) return cached
  const value = "ses_" + createHash("sha256").update(seed).digest("hex")
  if (affinityCache.size > 4096) affinityCache.clear()
  affinityCache.set(seed, value)
  return value
}

function stampHeaders(headers, sessionID) {
  if (!headers || typeof headers !== "object") return
  const id = projectId()
  if (id) headers["x-opencode-project"] = id
  loadState()
  if (!affinityOn || !salt || !sessionID) return
  const value = affinityFor(sessionID)
  for (const name of AFFINITY_HEADERS) headers[name] = value
}

function stampNative(headers, sessionID) {
  if (!headers || typeof headers.set !== "function") return
  const id = projectId()
  if (id) headers.set("x-opencode-project", id)
  loadState()
  if (!affinityOn || !salt || !sessionID) return
  const value = affinityFor(sessionID)
  for (const name of AFFINITY_HEADERS) headers.set(name, value)
}

function writeMarker(payload) {
  try {
    const dir = dirname(MARKER_FILE)
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true })
    writeFileSync(MARKER_FILE, JSON.stringify(payload, null, 2) + "\n", "utf8")
  } catch {
    return
  }
}

export default {
  id: "unlimited-shield",

  async setup(ctx) {
    const hooks = []

    try {
      await ctx.session.hook("model.request", (event) => {
        stampHeaders(event.headers, event.sessionID)
      })
      hooks.push("model.request")
    } catch {
      void 0
    }

    try {
      await ctx.session.hook("http.request", (event) => {
        stampNative(event.request?.headers, event.sessionID)
      })
      hooks.push("http.request")
    } catch {
      void 0
    }

    const marker = {
      plugin: "unlimited-shield",
      loaded: true,
      version: ctx.app?.version || "",
      directory: ctx.location?.directory || "",
      projectId: projectId(),
      affinity: affinityOn && salt ? "on" : "off",
      hooks,
      at: new Date().toISOString(),
    }

    writeMarker(marker)

    try {
      await ctx.storage.set("shield", marker)
    } catch {
      void 0
    }

    if (typeof console?.log === "function") {
      console.log("unlimited-shield loaded hooks=" + hooks.join(","))
    }

    return () => {
      writeMarker({ plugin: "unlimited-shield", loaded: false, at: new Date().toISOString() })
    }
  },
}
