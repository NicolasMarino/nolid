<h1 align="center">NoLid</h1>

<p align="center">
  Turn off your MacBook's built-in display <strong>with the lid open</strong>,<br>
  so macOS uses your external monitors and nothing else.
</p>

<p align="center">
  <img alt="platform" src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple">
  <img alt="language" src="https://img.shields.io/badge/Swift-5-orange?logo=swift">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-green">
  <img alt="deps" src="https://img.shields.io/badge/dependencies-0-lightgrey">
</p>

<p align="center">
  <strong>English</strong> · <a href="README.es.md">Español</a>
</p>

<p align="center">
  <img src="docs/menu.gif" alt="The NoLid menu with the built-in display off and two external monitors connected" width="489">
</p>

---

## The problem

You plug in two external monitors and macOS insists on treating the MacBook
panel as a third desktop. The cursor escapes downward, windows open where you
didn't want them, and the only official fix is closing the lid — giving up the
keyboard, the trackpad, Touch ID and the cooling.

The well-known fix is **BetterDisplay Pro**, which charges $21.99 for what
amounts to a handful of CoreGraphics calls.

This is that one feature. Nothing else.

## Two things nothing else does

There are other open-source tools in this niche, and some are good. Two things
here are not in any of them.

**1. NoLid checks that the display actually turned off.**

The private symbol every tool relies on can return success and turn off
nothing. Most tools trust the return code. NoLid verifies against
`CGGetActiveDisplayList`, undoes the failed attempt, and falls back to the
public mirroring path automatically. That is the difference between "works on
my Mac" and "works on yours".

`nolid doctor` proves it on your machine in one command — it performs the real
disable, checks whether the panel vanished, and restores it immediately:

```
$ nolid doctor

System
  macOS               Version 26.5.1 (Build 25F80)
  Architecture        arm64
  Hard disable        symbol resolved (SLSConfigureDisplayEnabled)
  Brightness control  available (DisplayServices)
  App                 running

Displays
  built-in   Built-in Retina Display   00000000-1111-2222-3333-444444444444
  external   LG UltraFine              00000000-5555-6666-7777-888888888888

Live probe
  the built-in display left the active display list and came back

Verdict
  This Mac supports hard disable. NoLid will turn the backlight off.
```

**2. Recovery works when the app is dead.**

A watchdog inside the app cannot save you from the app crashing. `nolid panic`
and `nolid on` talk to CoreGraphics directly when the app doesn't answer — no
second app to launch, no Spotlight, and it works **over SSH from another
machine** while your screen is black.

Commands that *turn displays off* deliberately refuse to run without the app,
because disabling without the safety nets has no way to undo itself.

## What it does

- **Toggle** the built-in display from the menu bar, a global hotkey, or the CLI.
- **Configurable hotkey.** `⌃⌥⌘L` by default, changed from the menu.
- **Automatic mode**: turns the panel off when externals are connected and
  brings it back when they're unplugged.
- **Per-topology profiles**: remembers what you wanted at home and what you
  wanted at the office, keyed by display UUID.
- **Mirror master selection** when the fallback path is in use.
- **CLI**: `nolid on|off|toggle|panic|status|doctor`, with JSON output.
- **Shortcuts and Focus automations** through App Intents, plus a `nolid://`
  URL scheme for Raycast, Alfred and Keyboard Maestro.
- **Optional notice** whenever the built-in display flips state. Off by default.
- **Emergency recovery**: three independent safety nets, plus a CLI that works
  without the app (see [Safety nets](#safety-nets)).
- **Non-blocking notices.** No modal dialog can ever stall the app while you're
  fighting with your displays.
- **Launch at login**, optional, via `SMAppService`.
- Runs as an agent (`LSUIElement`): no Dock icon, no windows.

The whole menu:

```
  Built-in: active
  External monitors: 2
  ─────────────────────────────────
  Turn off built-in display  (⌃⌥⌘L)
  ─────────────────────────────────
  ✓ Automatic mode
    Per-monitor profiles           ▸
    Mirror master                  ▸
    Notify on change
    Launch at login
  ─────────────────────────────────
    Hotkey: ⌃⌥⌘L                   ▸
  ─────────────────────────────────
  Restore all displays
  Method: SkyLight (hard disable)
  ─────────────────────────────────
  Quit NoLid                      ⌘Q
```

## Requirements

- macOS 13 (Ventura) or later.
- Xcode **Command Line Tools**. Free, and you don't need full Xcode:
  `xcode-select --install`.
- **At least one external monitor connected.** NoLid refuses to disable the
  built-in panel when it's the only display you have. That isn't a bug — it's
  the first safety net.

Builds and runs on Apple Silicon and Intel. `build.sh` detects the architecture
with `uname -m`.

The Shortcuts actions need one extra thing: `appintentsmetadataprocessor`, which
ships with full Xcode and not with the Command Line Tools alone. `build.sh`
detects it and says so. Without it everything else still builds and works — only
the Shortcuts actions are missing.

## Install

```bash
git clone https://github.com/NicolasMarino/nolid.git && cd nolid
make install
```

That builds both binaries, installs them, launches the app, and checks that the
CLI gets an answer back from it before reporting success.

A laptop icon appears in the menu bar.

The app is **ad-hoc signed**, not signed with a paid developer account. The
first time, macOS may ask you to confirm it under **System Settings → Privacy &
Security → Open Anyway**.

> **Don't see the icon?** It's almost always behind the notch. See
> [Troubleshooting](#troubleshooting).

`make install` installs the `nolid` CLI alongside the app, into
`~/.local/bin`. Pass `PREFIX=` to put it elsewhere.

The two are installed together on purpose, and there is no target that does
half. They talk over a shared control channel whose shape can change between
versions, so upgrading one and leaving the other produces a pair that cannot
talk: the CLI reports "NoLid is not answering" while the app is plainly
running, which silently takes `nolid status` with it along with the checks the
other commands make before they act. It looks exactly like a crashed app, and
it is an easy trap to walk into by following two separate copy commands.

To start the app automatically: NoLid menu → **Launch at login**. Ad-hoc
signing changes the binary hash on every build, so you have to re-enable it
after each `make install`.

## Usage

### Per-monitor profiles

Without profiles there is a single global preference, and automatic mode
decides everything from the bare fact that externals exist. That can't tell
"at home, with two monitors, the built-in is in the way" apart from "at the
office, with one, the built-in is a useful secondary".

Enable them under **Per-monitor profiles → Enable profiles**. From then on,
every time you turn the built-in display on or off, NoLid stores that decision
against the set of monitors connected at that moment, and reapplies it when it
sees those monitors again.

Monitors are identified by UUID (`CGDisplayCreateUUIDFromDisplayID`), not by
`CGDirectDisplayID`, which is reassigned on every reconnect. Plug order doesn't
matter: the profile key is sorted.

Priority, strongest first:

1. Saved profile for this set of monitors.
2. Automatic mode.
3. The last global preference.

### Mirror master

Only matters when the mirroring fallback is active. By default NoLid uses the
first external the system returns, and that order isn't stable. With more than
one monitor, the **Mirror master** submenu lets you decide which one hosts the
mirror.

The choice is stored by UUID. Unplug that monitor and NoLid falls back to the
first available one without complaining.

### Hotkey

`⌃⌥⌘L` by default. **Hotkey → Change hotkey…** opens a panel that captures the
next combination you press. It requires at least one of `⌃`, `⌥` or `⌘` —
without a modifier you'd be hijacking a plain key system-wide.

If the combination you pick is already taken, NoLid says so and restores the
previous one. It won't leave you without a shortcut.

### CLI

```
$ nolid status
Built-in:        off
External:        2 (LG UltraFine, DELL U2720Q)
Method:          SkyLight (hard disable)
Automatic mode:  yes
Profiles:        yes
Topology:        DELL U2720Q + LG UltraFine
```

| Command | Effect | Works when the app can't |
|---|---|---|
| `nolid on` | Turn the built-in display on | ✅ direct |
| `nolid off` | Turn it off (needs an external monitor) | ❌ |
| `nolid toggle` | Toggle | ❌ |
| `nolid panic` | Restore every display | ✅ direct |
| `nolid status` | Current state, human readable | ❌ |
| `nolid doctor` | What this Mac actually supports | ✅ direct |

Exit codes: `0` success, `1` the app is required and isn't answering, `2` bad
usage, `3` the command had no effect — typically `nolid off` with no external
monitors — and `4` a display was left unusable and could not be recovered.
Every command verifies the result by reading state back after sending it, so a
script can tell "done" from "ignored".

`3` and `4` are deliberately separate. `3` is a benign no-op: nothing happened
and nothing is broken. `4` means something is actually wrong on screen right
now — `nolid doctor` returns it when its live probe disabled the built-in
display and could not bring it back, and `nolid panic` and `nolid on` return it
when recovery genuinely failed. A script can gate on `4` alone to page a human.

For normal operations the CLI **does not touch displays**. It asks the menu bar
app to do it, over `DistributedNotificationCenter`, so one process owns the
state and the safety nets live in one place. Recovery is the exception, by
design.

Options: `--json` for machine-readable output (`status` and `doctor`),
`--no-probe` to make `doctor` skip the live test.

```bash
nolid doctor --json | jq -r '.probe.outcome'
# hard-disable-works | reports-success-does-nothing | call-rejected | symbol-unavailable
```

### What the control channel can and can't do

`DistributedNotificationCenter` is a per-user, system-wide bus. Any process
running as the same user can post `dev.nolid.command.off` and turn the built-in
display off, exactly as the CLI does. The same is true of the `nolid://` scheme,
which a web page can trigger once you have answered the one-time "open in
NoLid?" prompt.

That is the deliberate trade-off for needing **no permissions, no open ports and
no XPC service**. The worst a hostile local process can do is toggle a display —
the same thing you can do from the menu — and every safety net still applies:
the watchdog, the reconfiguration callback and `nolid panic` all still bring the
screen back. The channel does not cross user accounts.

Replies are addressed, not broadcast. Each `nolid` invocation invents a random
token, sends it with the command, and listens on a channel derived from it. Two
`nolid` processes running at once can't read each other's answers, and a process
that never saw the token can't land a forged reply on the caller at all.

That is not a security boundary, and isn't sold as one. A process running as the
same user can observe the command, read the token and race the real reply. macOS
draws no line between same-user processes — one could equally attach a debugger
or replace the binary — so no token scheme closes that. Don't script a
privacy-sensitive decision, like starting a recording or sharing a screen, on
`nolid status` output alone.

`nolid status` also reports monitor names and topology, so treat its output the
way you would treat any other local system detail.

### Shortcuts and automations

NoLid ships four App Intents, so its actions appear in the Shortcuts app under
**NoLid** with no setup:

| Action | Effect |
|---|---|
| Toggle Built-in Display | Flips the current state |
| Turn Off Built-in Display | Fails with a real error when no external is connected |
| Turn On Built-in Display | Brings the panel back |
| Restore All Displays | The panic button |

They run inside the app's own process, so they go through the same
`DisplayManager` as the menu and inherit every safety net. If the app isn't
running, the system launches it first — it's an agent, so nothing appears on
screen.

The point is Focus mode automations: *when Work Focus turns on, turn off the
built-in display.* No competing tool in this niche does that.

For anything that speaks URLs instead — Raycast, Alfred, Keyboard Maestro,
Stream Deck — there is a scheme:

```
nolid://toggle    nolid://on    nolid://off    nolid://panic
```

Same routing as the CLI and the intents. A URL can never reach a code path that
skips the safety nets.

### Notifications

**Notify on change** in the menu posts a notification whenever the built-in
display is turned off or back on. It is off by default on purpose: automatic
mode is meant to be invisible, and a banner on every dock and undock would be
noise. Turn it on while you are still learning what automatic mode does, and
turn it off once you trust it.

Failures always notify, regardless of this setting.

## How it works

macOS exposes no public way to disconnect a display. What does exist is a
private symbol in `SkyLight.framework`:

```c
CGError SLSConfigureDisplayEnabled(CGDisplayConfigRef config,
                                   CGDirectDisplayID display,
                                   bool enabled);
```

It's called inside a `CGBeginDisplayConfiguration` /
`CGCompleteDisplayConfiguration` transaction, like any resolution change. Same
technique BetterDisplay and similar projects use.

It does **not** require disabling SIP or any special entitlement: the symbol is
resolved with `dlsym` at runtime. If Apple removes it in a future release,
`dlsym` returns nothing, NoLid loses the strong method and falls back cleanly —
that case is handled. If Apple instead keeps the name and changes the function's
signature, no runtime check can catch it and the behaviour is undefined. That is
the known limit of calling an unversioned private symbol.

`CGCompleteDisplayConfiguration` is called with `.forSession`, not
`.permanently`. The change is never written to system preferences and disappears
when you log out. Persistence is handled by the app, which is the thing that
knows how to undo it.

### The two methods

|   | Strong | Fallback |
|---|---|---|
| API | `SLSConfigureDisplayEnabled` (private) | `CGConfigureDisplayMirrorOfDisplay` (public) |
| Effect | The display vanishes from the system | Mirrors an external, brightness to 0 |
| Separate desktop | Gone | Gone |
| Backlight | Off | On at minimum |
| Availability | Depends on the macOS build | Always |

On some hardware and macOS combinations, `SLSConfigureDisplayEnabled` **returns
success and turns off nothing**. So NoLid doesn't trust the return code: after
calling it, it checks whether the display actually left
`CGGetActiveDisplayList`. If it's still there, the attempt is undone and the
fallback takes over.

The fallback doesn't "disconnect" the panel, but it stops being an independent
desktop — which is the actual annoyance — and the cursor can't wander onto it.

**The menu tells you which of the two is active**, and so does `nolid status`.
`nolid doctor` goes further and proves it.

## Safety nets

The failure that matters in an app like this is leaving you with no display and
no way back. There are three independent layers:

1. **Precondition.** The built-in display can't be disabled when no external is
   active. The menu item is greyed out and `nolid off` refuses.
2. **Reconfiguration callback.** `CGDisplayRegisterReconfigurationCallback`
   fires as soon as the topology changes. Unplug every external and the panel
   is back within ~1s.
3. **8s watchdog.** Runs in `.common` mode, so it stays alive with a menu open
   or a panel on screen — exactly when you need it. If it sees zero active
   displays it stops being surgical: rather than retrying the one built-in id
   it cached before disabling the panel, it re-enables everything the system
   still lists. An id that no longer names anything cannot be retried back to
   life, and a black screen is the wrong place to be precise.

On top of that:

- **`nolid panic` and `nolid on` work with the app dead — and with the app
  alive and failing.** The three nets above all live inside the process; this
  one doesn't. Direct recovery used to be reserved for an app that stayed
  silent, which left the worse case uncovered: an app that answers, tries, and
  cannot deliver puts you in exactly the same place, staring at nothing. Now
  either failure reaches the same CoreGraphics path. It runs over SSH too.
- `apply()` is idempotent and the enable path runs **unconditionally**: it also
  restores brightness if macOS tore the mirror set down on its own.
- **The way back is verified as strictly as the way out.** Turning the built-in
  display on re-reads the active display list rather than assuming the call
  worked, and warns you when the panel didn't actually come back. A failed
  restore is reported, not swallowed.
- **No notice blocks the run loop.** Messages go through
  `UNUserNotificationCenter` or, without permission, a floating panel that
  dismisses itself. A modal `NSAlert` fired from the watchdog would leave the
  app unable to answer anything — the CLI included — until someone clicked OK.
- State is reapplied 2s after waking from sleep.
- Quitting the app restores everything while keeping your preference for next
  launch.
- **Panic button**: "Restore all displays" in the menu. It does not touch your
  saved profile — it's an emergency exit, not a preference change.
- State is `.forSession`: logging out clears anything strange.

## Troubleshooting

<details>
<summary><strong>I don't see the menu bar icon</strong></summary>

<br>

It's almost certainly there, hidden behind the MacBook **notch**. macOS doesn't
reflow menu bar extras when the bar fills up — it just draws them under the
notch, where they're invisible.

Check whether the item actually exists:

```bash
osascript -e 'tell application "System Events" to tell process "NoLid" \
  to get properties of menu bar item 1 of menu bar 1'
```

If it answers with a `position` and `help: NoLid — ...`, the icon is loaded. If
the X coordinate falls inside the notch (on a 14" MacBook at 1512 pt wide,
roughly between 670 and 842), that's your problem.

Fix it with any of these:

- Hold **⌘** and drag the icon to the right, out of the notch.
- Quit another menu bar app: NoLid shifts over on its own.
- Use a menu bar manager ([Ice](https://github.com/jordanbaird/Ice) is free and
  open source).

The app works either way: `nolid toggle` doesn't need the icon.

</details>

<details>
<summary><strong>"Turn off built-in display" is greyed out</strong></summary>

<br>

You have no active external monitor. That's the first safety net: NoLid won't
let you end up with no displays. Connect the external and the item enables
itself.

Check what the system sees:

```bash
nolid doctor
```

</details>

<details>
<summary><strong>My screen went black</strong></summary>

<br>

In order, least to most drastic:

1. If it was the **mirroring fallback**, the panel is on at brightness 0. Turn
   it up with **F2**.
2. Wait 8 seconds. The watchdog should have restored it already.
3. `nolid panic` — from this machine blind, or over SSH from another one. It
   works even if the app crashed.
4. Close and open the lid, or unplug and replug a monitor: either fires the
   reconfiguration callback.
5. Log out with **⇧⌘Q**. State is `.forSession` and disappears.
6. Reboot. Nothing was ever written to system preferences.

</details>

<details>
<summary><strong>The hotkey does nothing</strong></summary>

<br>

Another app has it registered. The **Hotkey** submenu says so with a "taken by
another app" line.

Pick a different one under **Hotkey → Change hotkey…**. If the new combination
is also taken, NoLid tells you and keeps the previous one.

</details>

<details>
<summary><strong>`nolid` says the app isn't answering</strong></summary>

<br>

`off`, `toggle` and `status` need the app: it owns the state and the safety
nets.

```bash
open -a NoLid
nolid status
```

`panic`, `on` and `doctor` don't need it and will act directly.

If the app is running and it still fails, the channel is
`DistributedNotificationCenter`, which doesn't cross user accounts. Run the CLI
as the same user that owns the graphical session.

</details>

<details>
<summary><strong>Profiles aren't being applied</strong></summary>

<br>

Check they're enabled and which profile matches the current monitors:

```bash
nolid status --json | jq '{profilesEnabled, topology}'
```

A profile is stored the first time you turn the built-in display on or off
**with profiles already enabled**. Enabling them fills nothing in
retroactively: the submenu shows "not remembered yet" until you make a
decision.

</details>

<details>
<summary><strong>Launch at login keeps switching itself off</strong></summary>

<br>

A consequence of ad-hoc signing: the binary hash changes on every build and
`SMAppService` invalidates the previous registration. Re-enable it from the
menu after each `make install`.

If it fails without rebuilding, make sure the app is in `/Applications` and not
in the build folder.

</details>

<details>
<summary><strong>The menu says "mirroring (public fallback)"</strong></summary>

<br>

Either your Mac and macOS combination doesn't support hard disable, or
`SLSConfigureDisplayEnabled` returned success without doing anything and NoLid
caught it. Run `nolid doctor` to see which.

There's nothing to fix: the fallback works. You lose the backlight turning off,
you keep what matters — it stops being a separate desktop.

</details>

## Uninstall

```bash
make uninstall
```

It stops the app, removes both binaries and deletes the saved preferences.
Turn off **Launch at login** from the menu first, or clear it afterwards in
System Settings → General → Login Items.

Nothing else is left behind. No daemons, no hand-written LaunchAgents, no
permanent display configuration changes.

## Layout

| File | Responsibility |
|---|---|
| `Sources/DisplayAPI.swift` | Low level: `dlsym` into SkyLight and DisplayServices, transactions, mirroring, brightness, UUIDs. Shared with the CLI |
| `Sources/DisplayManager.swift` | State, automatic mode, profiles, watchdog, recovery, persistence |
| `Sources/MenuBarController.swift` | `NSStatusItem`, menu, submenus, login item |
| `Sources/Notifier.swift` | Non-blocking notices: notifications plus a floating panel fallback |
| `Sources/HotKey.swift` | Global hotkey via Carbon (no Accessibility permission) and its configuration |
| `Sources/HotKeyRecorder.swift` | Panel that captures a key combination |
| `Sources/DisplayProfiles.swift` | Per-topology profiles, keyed by UUID |
| `Sources/DisplayBackend.swift` | The seam the state machine is tested through |
| `Sources/CapabilityProbe.swift` | What `doctor` decides, kept out of the CLI so it can be tested |
| `Sources/Intents.swift` | App Intents exposed to Shortcuts |
| `Sources/RemoteControl.swift` | CLI channel (`DistributedNotificationCenter`) |
| `Sources/main.swift` | Agent startup |
| `CLI/main.swift` | Command line entry point and direct recovery |
| `CLI/Doctor.swift` | Live capability probe |
| `Tests/` | Fake display backend and the suite |
| `Tools/make-icon.swift` | Draws the app icon from code, run on demand |
| `Makefile` | Install, uninstall, and the rule that the app and the CLI move together |

`build.sh` compiles with `swiftc -O -wmo` straight against the SDK — no Xcode
project, no `Package.swift`, no dependencies. `test.sh` builds and runs the
suite the same way. The `Makefile` is a thin front door over both, and the one
place that knows the app and the CLI must never be installed apart.

The icon is generated, not hand-drawn:

```bash
swift Tools/make-icon.swift Resources/NoLid.icns
```

It renders every size natively rather than downscaling one canvas, so the
symbol stays crisp at 16pt. Committing the generator instead of only the
`.icns` means the icon is a thing you can read and change, not a binary blob.

## Tests

```bash
./test.sh
```

The safety machinery is the part worth testing: everything else is a thin
forwarder or AppKit wiring, but the state machine is what can silently leave
someone staring at a black screen.

`DisplayManager` takes its display system and its notice channel as protocols,
so the suite can put it into states real hardware won't reproduce on demand:

- the private symbol returns success and disables nothing
- the system rejects the call outright
- both methods fail, and the built-in has to stay usable
- a failed re-enable being reported instead of passing silently
- the last external is unplugged while the mirror is up
- the mirroring fallback surviving a crash, and a mirror the user set up
  themselves never being torn down
- the watchdog runs with no active display at all
- a saved profile competing with automatic mode, in both directions
- a display with no stable UUID still getting a key that survives reconnect
- the panic button, which must not overwrite a saved profile
- a failure to turn off never being persisted as a profile that retries forever
- `doctor`'s four verdicts, and its probe reporting a panel it couldn't restore
- the built-in display dropping off the system lists entirely
- `nolid://` URL parsing, and change notices firing on transitions only

No XCTest and no `Package.swift`, to match the rest of the project: a plain
binary that exits non-zero on the first failing expectation, which is all CI
needs. 147 expectations at the time of writing.

Every one of them has been checked by reverting the code it covers and
confirming it fails. A suite that has never failed proves nothing.

Every fix for a real bug gets a test that fails without it. The two profile
bugs found in review — panic overwriting a saved profile, and automatic mode
being reverted by a stale one — are both pinned that way.

## Known limitations

- It uses a private API. Apple can break it in any release; the mirroring
  fallback would keep working.
- Not notarized, and it can't ship on the Mac App Store, precisely because of
  that private API.
- **No Homebrew cask.** Homebrew ended support for casks that fail Gatekeeper
  checks on 2026-09-01, and an ad-hoc signed app fails them — `--no-quarantine`,
  which used to be the way around it, was removed in Homebrew 4.7. Notarizing
  would fix this and needs a paid Apple Developer account. Until then the
  download and `make install` are the ways in.
- `applicationWillTerminate` doesn't run on a crash or a Force Quit. That's what
  `.forSession` state and `nolid panic` are for.
- Built in Swift 5 language mode. Moving to Swift 6 requires marking
  `DisplayManager` and `MenuBarController` as `@MainActor`.
- `nolid doctor`'s live probe briefly disables the built-in display. It restores
  it immediately and retries, but it does flash.

## Contributing

One file per responsibility, no dependencies, and the intent is to keep it that
way. Before opening a PR:

- `./build.sh` and `./test.sh` must both pass with no warnings.
- A bug fix comes with a test that fails without it.
- Every new path that turns a display off needs its matching recovery path. The
  rule is a single one: **the user never ends up unable to see the screen.**
- No modal dialogs on automatic paths. A `runModal()` in the watchdog blocks the
  run loop and leaves the app unable to answer anything.
- Private symbols are resolved with `dlsym` and fail cleanly. No link-time
  dependency.

## License

MIT. See [LICENSE](LICENSE).

## Credits

The `CGSConfigureDisplayEnabled` / `SLSConfigureDisplayEnabled` technique has
been known in the macOS community for years: DisableMonitor, BetterDisplay,
InternalDisplayOff. This is an independent, minimal implementation written from
scratch.
