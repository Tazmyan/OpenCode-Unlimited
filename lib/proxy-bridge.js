const net = require("node:net")
const fs = require("node:fs")
const { URL } = require("node:url")

const CONNECT_TIMEOUT_MS = 15000
const IDLE_TIMEOUT_MS = 120000
const MAX_HEADER_BYTES = 64 * 1024

function parseArgs(argv) {
  const out = { listen: "127.0.0.1:8899", upstream: "", log: "" }
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i]
    if (arg === "--listen") out.listen = argv[++i] ?? out.listen
    else if (arg === "--upstream") out.upstream = argv[++i] ?? ""
    else if (arg === "--log") out.log = argv[++i] ?? ""
    else if (arg === "--help" || arg === "-h") out.help = true
  }
  return out
}

function splitHostPort(value) {
  const trimmed = String(value ?? "").trim()
  if (!trimmed) return null
  const lastColon = trimmed.lastIndexOf(":")
  if (lastColon < 0) return { host: trimmed, port: 80 }
  const host = trimmed.slice(0, lastColon).replace(/^\[|\]$/g, "")
  const port = Number(trimmed.slice(lastColon + 1))
  if (!Number.isInteger(port) || port < 1 || port > 65535) return null
  return { host, port }
}

function makeLogger(path) {
  let fd = null
  if (path) {
    try {
      fd = fs.openSync(path, "a")
    } catch {
      fd = null
    }
  }
  return (line) => {
    const stamped = `${new Date().toISOString()} ${line}`
    if (fd !== null) {
      try {
        fs.writeSync(fd, stamped + "\n")
      } catch {

      }
    }
    process.stdout.write(stamped + "\n")
  }
}

function socks5Connect(upstream, target, log) {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host: upstream.host, port: upstream.port })
    let settled = false

    const fail = (error) => {
      if (settled) return
      settled = true
      socket.destroy()
      reject(error)
    }
    const done = () => {
      if (settled) return
      settled = true
      resolve(socket)
    }

    socket.setTimeout(CONNECT_TIMEOUT_MS, () => fail(new Error("socks5 connect timeout")))
    socket.once("error", fail)

    const hasAuth = Boolean(upstream.username || upstream.password)
    const methods = hasAuth ? [0x00, 0x02] : [0x00]

    socket.once("connect", () => {
      socket.write(Buffer.from([0x05, methods.length, ...methods]))
      let stage = "greeting"
      let buffer = Buffer.alloc(0)

      const onData = (chunk) => {
        buffer = Buffer.concat([buffer, chunk])

        const need = (n) => buffer.length >= n
        const take = (n) => {
          const slice = buffer.subarray(0, n)
          buffer = buffer.subarray(n)
          return slice
        }

        while (!settled) {
          if (stage === "greeting") {
            if (!need(2)) return
            const [version, method] = take(2)
            if (version !== 0x05) return fail(new Error("socks5: bad version in greeting"))
            if (method === 0xff) return fail(new Error("socks5: no acceptable auth method"))
            if (method === 0x02) {
              if (!hasAuth) return fail(new Error("socks5: upstream demanded auth, none configured"))
              const user = Buffer.from(upstream.username ?? "", "utf8")
              const pass = Buffer.from(upstream.password ?? "", "utf8")
              socket.write(
                Buffer.concat([
                  Buffer.from([0x01, user.length]),
                  user,
                  Buffer.from([pass.length]),
                  pass,
                ]),
              )
              stage = "auth"
              continue
            }
            stage = "connect"
            continue
          }

          if (stage === "auth") {
            if (!need(2)) return
            const [, status] = take(2)
            if (status !== 0x00) return fail(new Error(`socks5: auth rejected (${status})`))
            stage = "connect"
            continue
          }

          if (stage === "connect") {
            if (buffer.length === 0) {
              const hostBuf = Buffer.from(target.host, "utf8")
              if (hostBuf.length > 255) return fail(new Error("socks5: hostname too long"))
              socket.write(
                Buffer.concat([
                  Buffer.from([0x05, 0x01, 0x00, 0x03, hostBuf.length]),
                  hostBuf,
                  Buffer.from([(target.port >> 8) & 0xff, target.port & 0xff]),
                ]),
              )
              stage = "reply"
              continue
            }
            return
          }

          if (stage === "reply") {
            if (!need(2)) return
            const head = buffer.subarray(0, 2)
            const [, rep] = head
            if (rep !== 0x00) {
              const codes = {
                1: "general failure",
                2: "connection not allowed",
                3: "network unreachable",
                4: "host unreachable",
                5: "connection refused",
                6: "ttl expired",
                7: "command not supported",
                8: "address type not supported",
              }
              return fail(new Error(`socks5: ${codes[rep] ?? `error ${rep}`}`))
            }
            if (!need(5)) return
            const addrType = buffer[3]
            const addrLen = addrType === 0x01 ? 4 : addrType === 0x04 ? 16 : buffer[4] + 1
            const total = 4 + addrLen + 2
            if (!need(total)) return
            take(total)
            socket.removeListener("data", onData)
            socket.setTimeout(0)
            log(`socks5 ok -> ${target.host}:${target.port}`)
            done()
            return
          }
        }
      }

      socket.on("data", onData)
    })
  })
}

function httpUpstreamConnect(upstream, target, log) {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host: upstream.host, port: upstream.port })
    let settled = false
    const fail = (error) => {
      if (settled) return
      settled = true
      socket.destroy()
      reject(error)
    }
    socket.setTimeout(CONNECT_TIMEOUT_MS, () => fail(new Error("http upstream connect timeout")))
    socket.once("error", fail)
    socket.once("connect", () => {
      const auth =
        upstream.username || upstream.password
          ? "Proxy-Authorization: Basic " +
            Buffer.from(`${upstream.username ?? ""}:${upstream.password ?? ""}`).toString("base64") +
            "\r\n"
          : ""
      socket.write(
        `CONNECT ${target.host}:${target.port} HTTP/1.1\r\nHost: ${target.host}:${target.port}\r\n${auth}\r\n`,
      )
      let buffer = Buffer.alloc(0)
      const onData = (chunk) => {
        buffer = Buffer.concat([buffer, chunk])
        const end = buffer.indexOf("\r\n\r\n")
        if (end < 0) {
          if (buffer.length > MAX_HEADER_BYTES) fail(new Error("http upstream: header too large"))
          return
        }
        const head = buffer.subarray(0, end).toString("latin1")
        const status = Number(head.split(" ")[1])
        if (status !== 200) return fail(new Error(`http upstream: CONNECT ${status}`))
        socket.removeListener("data", onData)
        socket.setTimeout(0)
        log(`http upstream tunnel ok -> ${target.host}:${target.port}`)
        settled = true
        resolve({ socket, leftover: buffer.subarray(end + 4) })
      }
      socket.on("data", onData)
    })
  })
}

function dialUpstream(upstream, target, log) {
  if (upstream.protocol === "socks5:" || upstream.protocol === "socks5h:") {
    return socks5Connect(upstream, target, log).then((socket) => ({ socket, leftover: null }))
  }
  return httpUpstreamConnect(upstream, target, log)
}

function start({ listen, upstream, logPath }) {
  const log = makeLogger(logPath)
  const listenAddr = splitHostPort(listen)
  if (!listenAddr) throw new Error(`bad --listen value: ${listen}`)

  let upstreamUrl
  try {
    upstreamUrl = new URL(upstream)
  } catch {
    throw new Error(`bad --upstream value: ${upstream}`)
  }
  if (!["socks5:", "socks5h:", "http:", "https:"].includes(upstreamUrl.protocol)) {
    throw new Error(`unsupported upstream protocol: ${upstreamUrl.protocol}`)
  }
  if (upstreamUrl.protocol === "https:") {
    throw new Error("https:// upstreams are not supported; use socks5:// or http://")
  }

  const upstreamAddr = {
    host: upstreamUrl.hostname,
    port: Number(upstreamUrl.port || (upstreamUrl.protocol === "http:" ? 80 : 1080)),
    username: decodeURIComponent(upstreamUrl.username || ""),
    password: decodeURIComponent(upstreamUrl.password || ""),
    protocol: upstreamUrl.protocol,
  }
  if (!Number.isInteger(upstreamAddr.port) || upstreamAddr.port < 1) {
    throw new Error(`bad upstream port in ${upstream}`)
  }

  const server = net.createServer({ allowHalfOpen: true }, (client) => {
    client.on("error", () => client.destroy())
    client.setTimeout(IDLE_TIMEOUT_MS, () => client.destroy())

    let buffer = Buffer.alloc(0)
    let started = false

    const fail = (socket, status, text) => {
      const body = `proxy bridge: ${text}\n`
      socket.end(
        `HTTP/1.1 ${status}\r\n` +
          "Content-Type: text/plain\r\n" +
          `Content-Length: ${Buffer.byteLength(body)}\r\n` +
          "Connection: close\r\n\r\n" +
          body,
      )
    }

    const relay = (upstreamSocket, clientSocket) => {
      const kill = () => {
        upstreamSocket.destroy()
        clientSocket.destroy()
      }
      upstreamSocket.pipe(clientSocket)
      clientSocket.pipe(upstreamSocket)
      upstreamSocket.once("error", kill)
      clientSocket.once("error", kill)
      upstreamSocket.once("close", () => clientSocket.destroy())
      clientSocket.once("close", () => upstreamSocket.destroy())
    }

    const handle = (head, rest) => {
      const lines = head.split("\r\n")
      const requestLine = lines.shift() ?? ""
      const [method = "", target = "", version = "HTTP/1.1"] = requestLine.split(" ")
      if (!method || !target) {
        fail(client, 400, "malformed request line")
        return
      }

      if (method.toUpperCase() === "CONNECT") {
        const destination = splitHostPort(target)
        if (!destination) {
          fail(client, 400, "malformed CONNECT target")
          return
        }
        dialUpstream(upstreamAddr, destination, log)
          .then(({ socket, leftover }) => {
            socket.setTimeout(IDLE_TIMEOUT_MS, () => socket.destroy())
            client.write("HTTP/1.1 200 Connection Established\r\n\r\n")
            if (leftover && leftover.length) client.write(leftover)
            if (rest.length) socket.write(rest)
            relay(socket, client)
          })
          .catch((error) => {
            log(`tunnel failed ${destination.host}:${destination.port} ${error.message}`)
            fail(client, 502, error.message)
          })
        return
      }

      let url
      try {
        url = new URL(target)
      } catch {
        fail(client, 400, "absolute-URI required")
        return
      }
      if (url.protocol !== "http:") {
        fail(client, 400, "only http:// is proxyable; use CONNECT for https")
        return
      }

      const destination = { host: url.hostname, port: Number(url.port || 80) }
      const forwarded = [`${method} ${url.pathname}${url.search} ${version}`]
      const forbidden = new Set(["host", "connection", "proxy-connection", "proxy-authorization"])
      for (const line of lines) {
        if (!line) continue
        const split = line.indexOf(":")
        if (split < 1) continue
        const name = line.slice(0, split).trim().toLowerCase()
        if (forbidden.has(name)) continue
        forwarded.push(`${name}: ${line.slice(split + 1).trim()}`)
      }

      forwarded.push(`host: ${url.host}`, "connection: close")

      dialUpstream(upstreamAddr, destination, log)
        .then(({ socket, leftover }) => {
          socket.setTimeout(IDLE_TIMEOUT_MS, () => socket.destroy())
          socket.write(forwarded.join("\r\n") + "\r\n\r\n")
          if (leftover && leftover.length) client.write(leftover)
          if (rest.length) socket.write(rest)
          relay(socket, client)
        })
        .catch((error) => {
          log(`request failed ${destination.host}:${destination.port} ${error.message}`)
          fail(client, 502, error.message)
        })
    }

    const onData = (chunk) => {
      if (started) return
      buffer = Buffer.concat([buffer, chunk])
      if (buffer.length > MAX_HEADER_BYTES) {
        client.removeListener("data", onData)
        fail(client, 431, "request head too large")
        return
      }
      const end = buffer.indexOf("\r\n\r\n")
      if (end < 0) return
      started = true
      client.removeListener("data", onData)
      client.setTimeout(0)
      handle(buffer.subarray(0, end).toString("latin1"), buffer.subarray(end + 4))
    }

    client.on("data", onData)
  })

  server.listen(listenAddr.port, listenAddr.host, () => {
    log(`bridge listening on ${listenAddr.host}:${listenAddr.port} -> ${upstream}`)
  })

  server.on("error", (error) => {
    log(`bridge fatal: ${error.message}`)
    process.exitCode = 1
  })

  const shutdown = (signal) => {
    log(`bridge stopping (${signal})`)
    server.close(() => process.exit(0))
    setTimeout(() => process.exit(0), 2000).unref()
  }
  process.on("SIGINT", () => shutdown("SIGINT"))
  process.on("SIGTERM", () => shutdown("SIGTERM"))

  return server
}

if (require.main === module) {
  const args = parseArgs(process.argv)
  if (args.help || !args.upstream) {
    process.stdout.write(
      "usage: node proxy-bridge.js --listen 127.0.0.1:8899 --upstream socks5://host:port [--log file]\n",
    )
    process.exit(args.help ? 0 : 2)
  }
  try {
    start(args)
  } catch (error) {
    process.stderr.write(`proxy bridge: ${error.message}\n`)
    process.exit(1)
  }
}

module.exports = { start, socks5Connect, splitHostPort }

