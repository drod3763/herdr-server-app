# Herdr Server.app

A tiny macOS app bundle whose only job is to be the parent of `herdr server`, so that macOS
has something it can grant Local Network and TCC consent to.

Workaround for [herdrdev/herdr#808](https://github.com/herdrdev/herdr/issues/808). Not
affiliated with the herdr project.

## The problem

macOS records a *responsible process* for every process at spawn time (inherited from the
parent; launchd jobs are their own). Local Network Privacy and TCC resolve consent against
that process's identity: a bundle id or a signing identity. A `herdr server` started by
`brew services`, by launchd, or by an incoming `herdr --remote` attach over SSH is a bare,
ad-hoc-signed Mach-O with no bundle: it has no identity, never appears in System Settings,
and cannot be granted anything. Every pane under it inherits that. Symptoms:

- 1Password CLI (`op`) prompts on every call with no "Always Allow"
- non-Apple binaries (Homebrew `python3`, `kubectl`, `node`…) get `EHOSTUNREACH` on the LAN
  while `/usr/bin/curl` works, because Apple platform binaries are exempt

Two more facts shape the design (measured on macOS 26 / herdr 0.9.x):

- **Attribution reverts to self when the responsible process exits.** A server launched from
  a terminal app is fine only while that app runs; a helper that spawns the server and exits
  leaves it tainted.
- **`herdr server live-handoff` makes the old server spawn the new one**, so attribution is
  preserved across upgrades but can never be repaired by a handoff.

## What the launcher does

`herdr-server-launcher` lives in `Herdr Server.app` (bundle id `dev.rodriguez.herdr-server`,
`LSUIElement`, `NSLocalNetworkUsageDescription`) and:

- spawns `herdr server` as a **child** (never `exec`) and stays alive as its responsible
  parent, forwarding `SIGTERM`/`SIGINT`;
- respawns it if it dies, with a backoff when it fails immediately;
- if some other server already listens on the API socket (typically the replacement from a
  live handoff, which is still attributed to the launcher), **stands by** instead of racing
  it, and respawns only once that server is gone. This is what keeps a `KeepAlive`
  LaunchAgent from crash-looping on `herdr server is already running`.

It finds herdr at `/opt/homebrew/bin/herdr` or `/usr/local/bin/herdr` (override with
`HERDR_SERVER_BIN`) and probes `~/.config/herdr/herdr.sock` (override with
`HERDR_SOCKET_PATH`). Logs go to stderr.

## Install

```sh
brew install --cask drod3763/tap/herdr-server
```

or download `Herdr-Server-<version>.zip` from Releases and put `Herdr Server.app` in
`/Applications`.

Then run it from a user LaunchAgent, `~/Library/LaunchAgents/local.herdr-server.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>local.herdr-server</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Applications/Herdr Server.app/Contents/MacOS/herdr-server-launcher</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>StandardErrorPath</key>
	<string>/Users/YOU/Library/Logs/herdr-server.log</string>
</dict>
</plist>
```

```sh
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/local.herdr-server.plist
```

If a server is already running when the agent loads, the launcher stands by behind it. To
move onto the launcher-attributed server, stop the old one (this closes pane processes;
herdr restores the workspace layout):

```sh
herdr server stop
```

Do **not** `brew services start herdr` alongside this; that server is unattributable by
construction and the two would fight over the socket.

## Grant

The first time a program in a pane touches the LAN, macOS prompts for **Herdr Server**;
allow it. It can also be toggled later under System Settings › Privacy & Security › Local
Network. 1Password's "Always Allow" is offered on the next `op` call.

## Verify

```sh
tests/verify-attribution.sh
```

prints the running server's responsible process. Healthy output ends in
`/Applications/Herdr Server.app/Contents/MacOS/herdr-server-launcher`; a bare `herdr`,
`tailscaled` or `sshd` means the server was spawned outside the launcher.

## Caveats

- **Ad-hoc signature.** Without a Developer ID, the Local Network grant binds to this build's
  cdhash. That is why releases are built exactly once in CI and why the bundle must not be
  rebuilt in place on a granted machine; after upgrading the cask, re-grant it. Build with
  `make IDENTITY="Developer ID Application: …"` if you have a certificate, and the grant
  follows the identity instead.
- **Upgrading herdr** does not need a launcher restart: `herdr server live-handoff` moves
  panes to the new binary and the launcher stays the responsible parent.
- **Headless Macs** still need a GUI login for the LaunchAgent (`Aqua` session) and for the
  consent prompt to appear.

## Build

```sh
make check VERSION=0.1.0   # build, ad-hoc sign, lint plist, verify signature
make smoke                 # run the launcher against a fake herdr
make zip                   # release artifact + sha256
```

## License

MIT
