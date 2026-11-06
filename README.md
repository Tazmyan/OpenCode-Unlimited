# OpenCode-Unlimited

Fixes OpenCode's daily free-message limit from the command line: shows the real meter, watches the log for the exact moment a limit lands, clears the stale limit banner, rotates a local device id, and moves you onto a fresh network exit when you ask it to. Windows 10/11.

Nothing here writes to your registry, deletes a chat, or loses a message.

```powershell
opencode-unlimited on        # one command, then forget about it
```

Or drive it by hand:

```powershell
opencode-unlimited usage
opencode-unlimited reset "C:\my\project"
```

---

## Install

```powershell
git clone https://github.com/Tazmyan/OpenCode-Unlimited.git
cd OpenCode-Unlimited
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Open a new terminal afterwards so `opencode-unlimited` is on PATH.

- No admin rights.
- No registry writes.
- No proxy set behind your back.
- The plugin is only installed by `opencode-unlimited on`, and `off` takes it back out.

Needs Node.js 22.5 or newer, only because the session tools use Node's built-in SQLite reader.

---

## One command: `on`

```powershell
opencode-unlimited on
```

It runs one pass and leaves the machine in a working state:

1. Checks Node and finds your OpenCode install and database.
2. Mints a fresh virtual device id, in a local file only.
3. Picks a free model so you are not paying for the retry.
4. Loads a proxy list if the pool is empty.
5. Hunts for an exit whose address block is not spent, screening every candidate before it touches OpenCode.
6. Clears the stored "free limit" rows in **every** session, not just the current folder, then re-ids the sessions in this folder without touching messages.
7. Installs the shield plugin, starts the background watcher, and registers it to start at logon.

Then it prints the address you are leaving from and stops. From that point the watcher reads the log and rotates on its own when a limit line lands.

```powershell
opencode-unlimited on -KeepId      # keep the current device id
opencode-unlimited on -NoProbe     # do not spend a probe message on the route
opencode-unlimited on -NoStart     # set everything up, do not start the watcher
opencode-unlimited on -KeepRoute   # leave the network path alone
opencode-unlimited off             # stop watcher, remove autostart, direct egress
```

`off` stops the watcher, removes the logon task, unlists the plugin and puts the service back on a direct connection. It does not touch sessions, messages, or the identity file.

---

## Auto mode, honestly

What runs by itself:

- The watcher tails `opencode.log` and only reacts to a real `level=ERROR` limit line, so it spends zero messages while idle.
- On a hit it walks the pool, screens each candidate, and restarts the service once at the end.
- Each proxy keeps a health record: failures, last latency, and a quarantine. Two failures in a row park a proxy for 5 minutes, doubling up to 6 hours.
- A route slower than 3500 ms is treated as bad even when it answers.
- Ranking is fast-healthy first, then untested, then slow, then parked.

What it will not do: invent an exit address. Public proxy lists are mostly dead, so a hunt can walk a dozen entries and come up empty. When that happens it says so and leaves you on the direct connection instead of silently half-applying a dead proxy.

---

## Hit the message limit? Do this

You get this in the chat:

```
You've used today's free messages. They reset at 2:00 AM - 10/27/2026
```

Step by step:

1. **Close OpenCode.** The desktop app, the TUI, and `opencode serve` if it is running. Anything still open keeps the old connection warm.
2. **Change your IP.** Pick one:
   - Disconnect and reconnect your VPN, and pick a different server.
   - Turn your phone hotspot on and connect to it.
   - Power-cycle your router until the ISP hands you a new address.

   Check that it actually changed with `opencode-unlimited block` — it prints the address you are leaving from right now.
3. **Run the reset.**

   ```powershell
   opencode-unlimited reset "C:\my\project"
   ```

   That rotates the local device id, removes the stored limit errors, re-ids the sessions in that folder without touching their messages, and switches to the next proxy in your pool if you added one. It also prints the egress address before and after, so you can see whether the IP really moved.
4. **Open OpenCode again.** The banner is gone and you are on the new block.

If step 3 says `same egress block`, step 2 did not work. Same block means same bucket, and that bucket stays spent until 00:00 UTC. Change the connection again, then re-run `reset`.

Do not use a 121 MB chat for the first test message after a reset. A long session replays its whole history, which costs a lot more than a fresh one.

### Or let it watch for you

You do not have to notice the limit yourself:

```powershell
opencode-unlimited watch            # read the log once, spend nothing
opencode-unlimited watch -follow    # keep tailing it
opencode-unlimited watch -follow -auto   # tail, and rotate the moment it lands
```

`watch` reads OpenCode's own log, so it costs zero messages. It only treats a line as a real limit when the line starts with `level=ERROR` — the log also records command text, and a naive text match would fire on any command that mentions the phrase. `-auto` verifies the new route with one probe message, deletes the probe session afterwards, and stops once the route is open. Rotation is capped at five moves per thirty minutes.

Running `opencode-unlimited on` starts exactly this watcher in the background and adds the logon task, so you do not have to keep a terminal open.

### The shield plugin

`on` installs one small plugin and lists it in `~/.config/opencode/opencode.jsonc`. It hooks the two places OpenCode builds an outgoing request and stamps the virtual project id and a stable session affinity on it.

It is not a quota lever — the limit is per address block, as the section below explains. What it does is keep the request identity consistent with the identity file the CLI rotates, so a freshly minted device id is actually the one on the wire.

Check it directly instead of trusting a file on disk:

```powershell
opencode-unlimited plugin          # state, path, config entry, live hook list
opencode-unlimited plugin install  # install and list it again
opencode-unlimited plugin off      # unlist it and park the file
```

OpenCode reloads its config on save, so the plugin appears without a restart. `plugin status` asks the running server, and the answer includes the hook names it registered.

---

## Commands

| Command | What it does |
|---|---|
| `opencode-unlimited on` | Full auto: identity, model, pool, verified route, sessions, plugin, watcher, autostart |
| `opencode-unlimited on -KeepId -NoProbe` | Same, but keep the identity and skip the probe message |
| `opencode-unlimited off` | Stop watcher, remove autostart, unlist plugin, direct egress |
| `opencode-unlimited usage` | Meter state for today and the reset clock |
| `opencode-unlimited usage -check` | Same, plus one real message through the app |
| `opencode-unlimited watch` | Read the log for a limit line, no message spent |
| `opencode-unlimited watch -follow` | Keep tailing the log |
| `opencode-unlimited watch -follow -auto` | Tail, then rotate when a limit lands |
| `opencode-unlimited hunt` | Rotate until the probe says the route is open |
| `opencode-unlimited hunt -Country DE -Prefix 2a00:` | Steer the search |
| `opencode-unlimited token` | Show the local `auth.json` snapshot state |
| `opencode-unlimited token save` | Keep a local copy of `auth.json` |
| `opencode-unlimited token restore` | Put it back after the app drops it |
| `opencode-unlimited block` | Egress addresses seen today and which are spent |
| `opencode-unlimited block check` | Is the address you are on now still usable |
| `opencode-unlimited reset` | New device id, clear stored errors, verify |
| `opencode-unlimited reset "C:\path"` | Same, plus re-id every session in that folder |
| `opencode-unlimited reset "C:\path" -Dry` | Preview everything, write nothing |
| `opencode-unlimited reset "C:\path" -KeepIds` | Rotate the device id only |
| `opencode-unlimited identity` | Show the virtual device id and its generation |
| `opencode-unlimited identity rotate` | Mint a new virtual device id |
| `opencode-unlimited identity restore` | Remove the shim file, registry untouched |
| `opencode-unlimited sessions` | List sessions with ids, folders and sizes |
| `opencode-unlimited sessions "C:\path"` | Only that folder |
| `opencode-unlimited reid ses_abc...` | New session id, every message kept |
| `opencode-unlimited reid "C:\path"` | Re-id every session in that folder |
| `opencode-unlimited reid "C:\path" -Dry` | Show old ids, sizes and row counts |
| `opencode-unlimited model` | Providers with credentials and their free models |
| `opencode-unlimited model provider/model` | Switch this folder |
| `opencode-unlimited model ses_abc... provider/model` | Switch one session |
| `opencode-unlimited clear` | Strip stored "free limit" errors everywhere |
| `opencode-unlimited clear "C:\path"` | Same, scoped to a folder |
| `opencode-unlimited verify` | Check for orphaned rows and invalid state |
| `opencode-unlimited verify -fix` | Repair what it found |
| `opencode-unlimited status` | Runtime, identity, network, ledger |
| `opencode-unlimited doctor` | Node, service, schema, plugin, egress |
| `opencode-unlimited version` | Tool version plus detected OpenCode version |
| `opencode-unlimited proxy set socks5://host:port` | Route OpenCode through a proxy |
| `opencode-unlimited proxy off` | Back to a direct connection |
| `opencode-unlimited proxy pool add socks5://host:port` | Queue a proxy for `reset` to cycle to |
| `opencode-unlimited proxy pool fetch <url>` | Pull a free proxy list into the pool |
| `opencode-unlimited proxy pool refresh` | Refetch the list now |
| `opencode-unlimited proxy stats` | Per-proxy health, latency, failure count, quarantine |
| `opencode-unlimited proxy test -Top 20` | Probe the pool and park the dead ones |
| `opencode-unlimited proxy healthreset` | Forget every health record |
| `opencode-unlimited plugin` | Is the shield loaded, and where it lives |
| `opencode-unlimited plugin install\|off` | List or unlist it in the OpenCode config |
| `opencode-unlimited proxy next` | Jump to the next pooled proxy now |
| `opencode-unlimited warp on\|off\|rotate` | Optional Cloudflare WARP path |
| `opencode-unlimited run <args...>` | Run OpenCode, record a free-limit hit |
| `opencode-unlimited uninstall` | Remove slash commands, plugin and local state |

Inside the chat, the same actions as slash commands:

```
opencode-unlimited
opencode-unlimited:reset C:\Users\you\projects\my-app
opencode-unlimited:identity rotate
opencode-unlimited:block
opencode-unlimited:usage
opencode-unlimited:watch -follow -auto
opencode-unlimited:hunt -Country DE
opencode-unlimited:token save
opencode-unlimited:reid C:\Users\you\projects\my-app
opencode-unlimited:model openrouter/deepseek/deepseek-v4.1-flash
opencode-unlimited:clear C:\Users\you\projects\my-app
```

Colon separator, so they sort together and do not collide with other plugins.

---

## The limit is per IP, not per account or device

The free budget is counted per egress block, per UTC day:

- IPv4: one address, `/32`
- IPv6: one prefix, `/64`
- Resets at exactly **00:00 UTC** — 2:00 AM in central Europe, 1:00 AM in the UK, 7:00 PM the previous day on the US east coast.

It is not per project, not per session, not per model, not per device and not per machine id. Rotating `x-opencode-project` or the session id changes nothing. The refusal is about the address you leave from.

So the two honest levers are:

1. Leave through a different address block — VPN, hotspot, router reconnect, or `proxy pool`.
2. Switch the session to a provider that does not bill through this gateway: `opencode-unlimited model`.

The window is a wall clock, not a rolling one. `Retry-After` always lands on the next midnight UTC.

---

## Proxy pool

Manual IP changes work fine. If you have a few proxies and want `reset` to walk them for you:

```powershell
opencode-unlimited proxy pool add socks5://127.0.0.1:1080
opencode-unlimited proxy pool add http://user:pass@10.0.0.1:3128
opencode-unlimited proxy pool
```

From then on, `reset` and `hunt` walk it: each candidate is measured through the proxy *before* OpenCode is touched, so a dead entry costs about six seconds and no service restart. Only the working one is applied, and the service is restarted once at the end. If the new address lands in the same block as the old one it moves to the next proxy instead of pretending it worked.

Every proxy also carries a health record:

```powershell
opencode-unlimited proxy stats        # ranking, latency, failures, quarantine
opencode-unlimited proxy test -Top 20 # probe now, park what is dead
opencode-unlimited proxy healthreset  # clean slate
```

Two failures in a row park a proxy for five minutes, and the wait doubles on every further failure up to six hours. Anything slower than 3500 ms counts as bad even when it answers. The order is: fast and healthy, then untested, then slow, then parked at the back.

You can also point it at a public list and let it shuffle:

```powershell
opencode-unlimited proxy pool fetch https://example.com/proxies.txt
opencode-unlimited proxy pool refresh
```

The list is parsed for every `ip:port` in it, capped at 200 candidates, cached for six hours, and health-tested one at a time as rotation walks it. An empty or truncated response is rejected instead of poisoning the pool.

```powershell
opencode-unlimited proxy next        # walk one step now
opencode-unlimited proxy pool clear  # forget the pool and the cached list
```

SOCKS5 proxies go through a small local bridge, because the OpenCode service speaks HTTP proxies. HTTP proxies are used directly. Proxies are never set globally on the machine — only in the service environment.

---

## What `reset` rotates, and what it refuses to touch

`reset` does six things:

1. **Device id** — a virtual id stored in `~/.config/opencode/unlimited-identity.json` and `%LOCALAPPDATA%\opencode-unlimited\shim\machine-guid.txt`. It **never** writes `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid`. `identity restore` deletes the shim and your real machine guid is still exactly where it was.
2. **Stored limit errors** — removes the `provider.free-limit` rows a failed prompt left in your history, and flips the session outcome back to succeeded. No rows deleted.
3. **Session ids** — one transaction per session, every message and part row re-pointed, the event counter moved along with the id so the app keeps numbering above the messages it kept, row counts compared before and after, rollback on mismatch.
4. **Egress route** — next proxy in the pool, if you have one. With `-Hunt`, it keeps rotating until a probe answers, instead of taking the next entry on trust.
5. **Egress block** — measures the address you are leaving from, records it with its country in a local ledger, and compares the `/32` or `/64` block, not the literal string. Two addresses in one IPv6 `/64` are the same bucket and are now reported as such.
6. **Database** — `verify -fix`: invalid idle flags, duplicate project folders.

Restarting the background service never touches sessions. `clear` never deletes a session or a message row. A re-id is not a refill; it gives the session a clean new identity and keeps its content.

---

## Troubleshooting

**`usage` says the block is spent but prompts still work.**
Remaining budget is not linear. A long session replays its whole history, so a heavy chat can burn dozens of calls for one visible turn while a fresh session still gets through.

**The banner is still there after `clear`.**
Restart the app so the session reloads from disk.

**`reset` says `same egress block`.**
Your VPN, hotspot, or router handed you an address inside the same block — for IPv6 that means the same `/64`, which string comparison would have missed. Same block, same bucket. Change the connection and run it again, or wait for 00:00 UTC.

**`watch` finds nothing.**
It starts at the end of the log on the first run, so it only sees what happens next. Pass `-all` to rescan the recent backlog, and make sure OpenCode has written a log at least once.

**`watch -auto` rotated but the prompt still fails.**
The watcher moved the route and verified it with a probe. If the chat was open the whole time, it kept the old connection; send the prompt again or restart the app.

**`sessions` prints nothing for a folder.**
Run `opencode-unlimited doctor`. It prints the database path and the detected session table. Folder matching ignores case and slash direction.

**A re-id felt slow on a big folder.**
Each session is its own transaction and the history is rewritten in place. A 200 MB folder takes a few seconds. Use `-Dry` first.

**An old session fails with a SQLite `insert into "session_message"` error after a re-id.**
A re-id from an older build moved the session id but left its event counter behind, so the app restarted numbering at 1 and collided with a message it had already kept. Close OpenCode, run `opencode-unlimited verify -fix`, then reopen the chat. `verify` alone shows the drift without writing anything.

**Everything looks fine but prompts fail.**
Compare `opencode-unlimited usage` with the exit address your VPN reports. Leaking DNS or an IPv6 route can keep you on the old block.

**I want my machine id back.**
Nothing was changed. `opencode-unlimited identity restore` deletes the shim and the state file.

---

## Issues and help

Open an issue with the command you ran and the output. That is enough to start. Small pull requests are welcome.

> [!TIP]
> Faster answers in the Discord: **https://discord.gg/8RfQBJh5JZ**

---

## Disclaimer

Educational and research use only. Not affiliated with, endorsed by, or supported by OpenCode or any of their partners; all trademarks belong to their owners.

- It unlocks no entitlement. The free limit is enforced by OpenCode's servers and stays in force.
- It does not modify your machine id, your registry, or any system identifier. The identity it rotates is a local file the tool owns.
- Using it may break a provider's terms of service. That is your responsibility, and so is any consequence, including account restrictions.
- Provided "as is", with no warranty and no liability for damage, data loss or account action. Use at your own risk.
- Rights holder and want it gone? Open an issue and it gets removed promptly, no argument.
