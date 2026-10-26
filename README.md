# OpenCode-Unlimited

**Gets you past OpenCode's free message limit, and tells you when it's back.**

OpenCode gives you a fixed number of free messages per day and then shows:

```
You've used today's free messages. They reset at 2:00 AM - 10/27/2026
```

This tool checks whether that limit is still biting, gives you a fresh project
identity when you need one, and can push OpenCode through a proxy if you want a
different connection.

---

## Install

```powershell
git clone https://github.com/Tazmyan/OpenCode-Unlimited.git
cd OpenCode-Unlimited
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Done. Open a new terminal window so the `opencode-unlimited` command is found.

Nothing needs admin rights, and your OpenCode settings are not modified.

---

## How to use it

### 1. You hit the limit

Just change your internet connection first — VPN, hotspot, router restart,
whatever you have. A new connection is what usually brings the messages back.

### 2. Check whether you're clear

```powershell
opencode-unlimited test -live
```

It asks the app for one tiny reply.

- `WORKING` — you're free to prompt again.
- `EMPTY` — the app is still blocked on this connection.

### 3. Want a new project identity too

```powershell
opencode-unlimited id
```

New id, applied within a second. No restart, no lost sessions.

That's the whole workflow. Everything else is optional.

---

## Commands

| Command | What it does |
|---|---|
| `opencode-unlimited test` | Free check of the direct API. Fast, but it does not see your app quota. |
| `opencode-unlimited test -live` | Real check through the app. Costs one message. |
| `opencode-unlimited id` | New project id |
| `opencode-unlimited status` | Project id, connection, plugin state |
| `opencode-unlimited reset` | New id + clears the stale "out of messages" error |
| `opencode-unlimited on` / `off` | Turn the plugin on or off |
| `opencode-unlimited proxy set socks5://host:port` | Route OpenCode through a proxy |
| `opencode-unlimited proxy off` | Back to a direct connection |
| `opencode-unlimited doctor` | Check node, service, plugin, identity |
| `opencode-unlimited uninstall` | Remove plugin, menu commands, state |

Inside OpenCode's chat you get the same thing as menu commands, just type `/`:

```
opencode-unlimited
opencode-unlimited:test
opencode-unlimited:reset
opencode-unlimited:id
```

---

## "It says EMPTY but my messages work"

That's expected, and it's the one confusing part.

`test` without `-live` sends a bare request to OpenCode's API. That endpoint
answers `429` for anything that isn't the OpenCode app itself — same answer for a
random project id, a valid key or no key at all. So it can't see your real quota.

The app is the only thing that knows. Use `test -live` when it matters, or simply
send a message and see if it lands.

---

## Sessions are safe

Your chats live in `opencode.db`, and this tool never opens that file.

- The plugin only sets one header on outgoing requests.
- `reset` deletes only the stored "you're out of messages" error rows, nothing else.
- Restarting the background service never touches sessions.

---

## Something broken? Want to help?

Open an issue on GitHub and describe what you saw — the command, the output, and
your Windows version is enough to start.

Pull requests are welcome, small ones especially: a clearer message, a
compatibility fix, a missing check.

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
