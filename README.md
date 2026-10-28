# OpenCode-Unlimited

**Tells you when OpenCode's free messages are back, and fixes the banner that lies about it.**

OpenCode gives every connection a free daily budget. When it runs out you get:

```
You've used today's free messages. They reset at 2:00 AM - 10/27/2026
```

Two different things are happening when you see that message, and this tool
separates them:

1. **The live budget** — metered by OpenCode's servers against the address your
   traffic leaves from. Nothing local can refill it.
2. **The stored banner** — a failed request was written into the session as an
   error row, and the app keeps showing it long after the budget reset.

`opencode-unlimited` reads the real state of the budget, clears the stale
banner without touching your messages, and tells you plainly whether you are
waiting on the clock or on your IP.

---

## Install

```powershell
git clone https://github.com/Tazmyan/OpenCode-Unlimited.git
cd OpenCode-Unlimited
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Open a new terminal so the `opencode-unlimited` command is found. No admin
rights, no changes to your OpenCode config, no proxy is set behind your back.

Requires Windows 10/11 and Node.js 22.5+ (only because the session tools use
Node's built-in SQLite reader).

---

## Quick start

```powershell
opencode-unlimited usage      # is the free tier open on this connection?
opencode-unlimited clear      # wipe the stored "out of messages" banner
opencode-unlimited test -live # ask the app for one tiny reply
```

`usage` answers the only question that matters:

```
==> free tier check
      egress ip : 95.42.79.22
  [!] SPENT - this connection has no free messages left until 1:59 am 10/29/2026
      free tier is metered per source address, not per project
      rotating the project id or session id does not refill it
      change your egress ip, or wait for the reset above
```

When it says `OPEN`, you can prompt right away.

---

## Why changing the project id does nothing

This is the part most guides get wrong.

The free budget is counted against your **source IP**, not against
`x-opencode-project`, not against your session id, not against your account.
Three requests with a real project id, a made-up project id, and no project
header at all return the same `429 FreeUsageLimitError` and the same
`Retry-After`. The bucket is the address.

So the only real refill is a different connection:

1. Change network — VPN, phone hotspot, router reconnect, new Wi-Fi.
2. Confirm it moved: `opencode-unlimited status` shows `egress ip`.
3. `opencode-unlimited clear` to drop the stale banner.
4. `opencode-unlimited test -live` for a real answer.

If the IP is identical, nothing changed and the limit holds.

The window resets daily at **00:00 UTC** (about 2:00 AM in central Europe). The
`Retry-After` header carries the exact number of seconds left, and this tool
turns that into a local clock time.

---

## The banner is history, not a live answer

When a prompt is refused, OpenCode stores the failure inside the session as a
row with `error.type = provider.free-limit`, plus a `retryAfterMs`. Reopening
that session shows the row again, so an old refusal looks like a fresh one.

`clear` removes exactly those errors and sets the row's outcome back to
`succeeded`. Rows are never deleted, so no message can end up pointing at a
missing id, and your chat history stays exactly where it was.

```
limit errors cleared: 24, idle flags reset: 1
```

If a **new** prompt still fails after that, the budget itself is spent on that
connection.

---

## Commands

| Command | What it does |
|---|---|
| `opencode-unlimited usage` | Free check: is the budget open on this connection, and when does it reset |
| `opencode-unlimited test` | Same direct probe, short form |
| `opencode-unlimited test -live` | Real check through the app. Costs one message |
| `opencode-unlimited status` | Runtime, identity, network, plugin, budget |
| `opencode-unlimited version` | Tool version plus the OpenCode version, API version and DB schema it detected |
| `opencode-unlimited clear` | Strip stored "free limit" errors from every session |
| `opencode-unlimited clear "C:\path\to\project"` | Same, scoped to one folder |
| `opencode-unlimited sessions` | List sessions with their ids and folders |
| `opencode-unlimited sessions "C:\path\to\project"` | List only that folder |
| `opencode-unlimited reid ses_abc...` | Mint a fresh session id, keep every message |
| `opencode-unlimited id` | New project id, all projects move to fresh ids |
| `opencode-unlimited id "C:\path\to\project"` | New project id for one folder |
| `opencode-unlimited reset` | Rotate every project, clear the stale banner, verify |
| `opencode-unlimited reset "C:\path\to\project"` | Same, but only that folder |
| `opencode-unlimited verify` | Check sessions for orphaned rows and invalid state |
| `opencode-unlimited verify -fix` | Repair what `verify` found |
| `opencode-unlimited repair` | Re-link projects to the sessions they own |
| `opencode-unlimited proxy set socks5://host:port` | Route OpenCode through a proxy |
| `opencode-unlimited proxy off` | Back to a direct connection |
| `opencode-unlimited warp on\|off\|rotate` | Optional Cloudflare WARP path |
| `opencode-unlimited doctor` | Check node, service, schema, identity, plugin |
| `opencode-unlimited uninstall` | Remove the slash commands and local state |

Inside OpenCode's chat, the same actions as menu commands:

```
opencode-unlimited
opencode-unlimited:test
opencode-unlimited:clear C:\Users\you\projects\my-app
opencode-unlimited:id C:\Users\you\projects\my-app
opencode-unlimited:reset
```

---

## Sessions are never damaged

Everything lives in `opencode.db`.

- `clear` and `verify -fix` only rewrite the rows they name. Nothing is deleted.
- `reid` moves one session to a new id and re-points every child row inside one
  transaction. On any error it rolls back, so a half-moved session cannot exist.
- `reset` rewrites project ids; sessions, messages and history follow the new id
  and stay attached to their folder.
- Restarting the background service never touches sessions.

---

## Works across OpenCode versions

Nothing about versions is hardcoded. On every run the tool detects:

- the `opencode` binary (PATH, npm global, bun, scoop, chocolatey, local install)
- its version from `--version`, the running service, or the package manifest
- the API generation from your `cli.json` schema (`v1`, `v2`, …)
- the gateway base URL and org id from the provider list, falling back to the
  known default when the service is not running
- the free models that exist right now, so probes always use a model you can
  actually reach
- the database location (XDG, `OPENCODE_DATA_HOME`, `%LOCALAPPDATA%`) and the
  live schema — the session table, message table, id columns and fork columns
  are discovered, not assumed

```
opencode-unlimited version
opencode-unlimited 1.0.1
      opencode   : v2.1.4
      api        : v2
      session t. : session_v2
      gateway    : https://opencode.ai/inference/openai/v1/chat/completions
```

Detected values are cached for five minutes in
`~/.config/opencode/unlimited-info.json`. Delete it, or pass `status`, to
refresh.

---

## Troubleshooting

**`usage` says SPENT but messages still work.**
Remaining budget is not linear: a long session replays its whole history, so a
heavy chat can burn far more than an empty one. If a fresh session works and the
old one does not, it is cost, not identity. `test -live` on the empty session is
the honest check.

**The banner still shows after `clear`.**
Restart the app so the session reloads from disk.

**`sessions` prints nothing.**
Check `opencode-unlimited doctor` — it prints the database path and the detected
session table.

**Everything looks fine but prompts fail.**
`opencode-unlimited usage` and compare `egress ip` with what your VPN reports.
Leaking DNS or an IPv6 route can keep you on the old address.

---

## Issues and help

Open an issue on GitHub with the command you ran and the output — that is enough
to start. Pull requests welcome, small ones especially.

> [!TIP]
> Faster answers in the Discord: **https://discord.gg/8RfQBJh5JZ**

---

## Disclaimer

Educational and research use only. Not affiliated with, endorsed by, or
supported by OpenCode or any of their partners; all trademarks belong to their
owners.

- It unlocks no entitlement. The free limit is enforced by OpenCode's servers and
  stays in force.
- Using it may break a provider's terms of service. You are responsible for that
  and for any consequence, including account restrictions.
- Provided "as is", with no warranty and no liability for damage, data loss or
  account action. Use at your own risk.
- Rights holder and want it gone? Open an issue and it gets removed promptly, no
  argument.
