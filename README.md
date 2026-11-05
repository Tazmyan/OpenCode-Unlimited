# OpenCode-Unlimited

Fixes OpenCode's daily free-message limit from the command line: shows the real meter, clears the stale limit banner, rotates a local device id, and moves you onto a fresh network exit when you ask it to. Windows 10/11.

Nothing here writes to your registry, deletes a chat, or loses a message.

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
- No plugin installed unless you run `opencode-unlimited on`.

Needs Node.js 22.5 or newer, only because the session tools use Node's built-in SQLite reader.

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

If step 3 says `ip unchanged`, step 2 did not work. Same address means same bucket, and that bucket stays spent until 00:00 UTC. Change the connection again, then re-run `reset`.

Do not use a 121 MB chat for the first test message after a reset. A long session replays its whole history, which costs a lot more than a fresh one.

---

## Commands

| Command | What it does |
|---|---|
| `opencode-unlimited usage` | Meter state for today and the reset clock |
| `opencode-unlimited usage -check` | Same, plus one real message through the app |
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

From then on, `reset` moves to the next entry, applies it, restarts the background service, and measures the exit address. If the new address is the same as the old one, it tries the next proxy instead of pretending it worked. It gives up after the pool size or eight attempts, whichever is smaller, and says so.

```powershell
opencode-unlimited proxy next        # walk one step now
opencode-unlimited proxy pool clear  # forget the pool
```

SOCKS5 proxies go through a small local bridge, because the OpenCode service speaks HTTP proxies. HTTP proxies are used directly. Proxies are never set globally on the machine — only in the service environment.

---

## What `reset` rotates, and what it refuses to touch

`reset` does six things:

1. **Device id** — a virtual id stored in `~/.config/opencode/unlimited-identity.json` and `%LOCALAPPDATA%\opencode-unlimited\shim\machine-guid.txt`. It **never** writes `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid`. `identity restore` deletes the shim and your real machine guid is still exactly where it was.
2. **Stored limit errors** — removes the `provider.free-limit` rows a failed prompt left in your history, and flips the session outcome back to succeeded. No rows deleted.
3. **Session ids** — one transaction per session, every message and part row re-pointed, row counts compared before and after, rollback on mismatch.
4. **Egress route** — next proxy in the pool, if you have one.
5. **Egress block** — measures the address you are leaving from and records it in a local ledger.
6. **Database** — `verify -fix`: invalid idle flags, duplicate project folders.

Restarting the background service never touches sessions. `clear` never deletes a session or a message row. A re-id is not a refill; it gives the session a clean new identity and keeps its content.

---

## Troubleshooting

**`usage` says the block is spent but prompts still work.**
Remaining budget is not linear. A long session replays its whole history, so a heavy chat can burn dozens of calls for one visible turn while a fresh session still gets through.

**The banner is still there after `clear`.**
Restart the app so the session reloads from disk.

**`reset` says `ip unchanged`.**
Your VPN, hotspot, or router handed you the same address. Same block, same bucket. Change the connection and run it again, or wait for 00:00 UTC.

**`sessions` prints nothing for a folder.**
Run `opencode-unlimited doctor`. It prints the database path and the detected session table. Folder matching ignores case and slash direction.

**A re-id felt slow on a big folder.**
Each session is its own transaction and the history is rewritten in place. A 200 MB folder takes a few seconds. Use `-Dry` first.

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
