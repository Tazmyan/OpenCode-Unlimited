# opencode-unlimited

**Bypass the OpenCode free-tier daily message limit.**

OpenCode keeps one free-message bucket per IP address, so the block below is
about where you connect from, not which project you are in. This tool checks the
bucket before you prompt, rotates your project id, and gives you an optional
proxy path when you need a different IP.

```
You've used today's free messages. They reset at 2:00 AM - 10/27/2026
```

---

## Install

```powershell
git clone https://github.com/Tazmyan/opencode-unlimited.git
cd opencode-unlimited
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Open a new terminal when it finishes. No admin rights, no edits to your OpenCode
config.

---

## Usage

Changed your IP? Ask the bucket:

```powershell
opencode-unlimited test
```

- `FRESH` — you can prompt again.
- `EMPTY` — this IP is still drained. Change it, test again.

The rest of the commands:

| Command | What it does |
|---|---|
| `status` | Project id, egress IP, bucket state |
| `id` | New project id, takes effect in a second, no restart |
| `reset` | New id, clears the stuck limit error, re-checks the bucket |
| `on` / `off` | Plugin on or off |
| `proxy set socks5://host:port` | Send OpenCode through a proxy |
| `proxy off` | Back to a direct connection |

`run <args>` and `warp` are there too if you want them. `help` lists everything.

The same thing is inside OpenCode's command menu:

```text
opencode-unlimited          status
opencode-unlimited:test     check the bucket
opencode-unlimited:reset    new id, clear stuck errors
opencode-unlimited:id       new project id only
```

---

## Why the id alone does nothing

Every request to the completion endpoint returns the same
`429 FreeUsageLimitError` whether the project id is random, real, missing, or
paired with a fake key, and every free model shares the bucket. The limit is
bound to your egress IP.

So rotation keeps sessions unlinked and the IP change is what actually refills
the bucket.

---

## Will it eat my sessions?

No. Conversations live in `opencode.db`, and this never opens that file unless
you pass `-Db`. `reset` only deletes rows containing a stored
`FreeUsageLimitError`.

---

## If something breaks

| Symptom | Fix |
|---|---|
| command not found | open a new terminal |
| `test` says `UNKNOWN` | run `opencode api get /api/provider` once, retry |
| TUI still shows the limit | `opencode-unlimited reset` |
| anything else | `opencode-unlimited off`, then `proxy off` |

Supported on **Windows 10 (1809+) and Windows 11 only**, with PowerShell 5.1 or
7+. Node.js is needed only for the SOCKS5 bridge.

---

## Disclaimer

Educational and research use only. Not affiliated with, endorsed by, or
supported by OpenCode or any of their partners; all trademarks belong to their
owners.

- It unlocks no entitlement. Free-tier limits are enforced server-side and stay
  in force.
- Using it may break a provider's terms of service. You are responsible for that
  and for any consequence, including account restrictions.
- Provided "as is", with no warranty and no liability for damage, data loss or
  account action. Use at your own risk.
- Rights holder and want it gone? Open an issue and it gets removed promptly, no
  argument.
