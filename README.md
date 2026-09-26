# lcpdfr-1.1-audiofix-ce

The GTA IV: Complete Edition fork of
[lcpdfr-1.1-audiofix](https://github.com/ipkpjersi/lcpdfr-1.1-audiofix). Source patches for
LCPDFR 1.1, plus the tooling to rebuild `LCPD First Response.dll` from LMS's public source
with them applied, for Complete Edition 1.2.0.59 running LCPDFR 1.1 Legacy Edition and the
Complete Edition compatibility patch.

It carries the original's DirectSound leak fix unchanged and adds fixes for problems that
only appear on Complete Edition. The Original Edition (1.0.7.0) should keep using
lcpdfr-1.1-audiofix.

**No binaries are distributed here, by licence.** See *Licence* below. You build it
yourself; everything needed to do that is in this repository.

## The patches

| Patch | Fixes |
|---|---|
| `soundengine-audio-fix.patch` | The DirectSound device leak and two untimed waits, as in lcpdfr-1.1-audiofix |
| `helpbox-key-names.patch` | Help boxes showing `,` and `.` instead of the real keys |
| `ped-untracked-vehicle.patch` | Hotkeys and aiming dying mid-session on a ped whose vehicle LCPDFR does not track |

`build.sh` applies them in that order.

### The DirectSound leak

`Engine/IO/SoundEngine.cs` `PlayExternalSound` creates a fresh DirectSound device and a
`SecondarySoundBuffer` for every sound played, and disposes neither. SlimDX roots every
`ComObject` in a static `ObjectTable`, so nothing is ever finalised.

Under Wine each device is a WASAPI endpoint that keeps a mixer thread alive, and each
thread reserves about 1 MB of address space. A 32-bit process exhausts its address space
after roughly 330 sounds, and the constructor then throws on a bare thread with no handler,
which terminates the game. On Complete Edition it has been seen surfacing as `E_FAIL`
rather than `AUDCLNT_E_ENDPOINT_CREATE_FAILED` (`0x8889000F`).

The same method also contains two untimed wait loops:

    while (!secondarySoundBuffer.Status.HasFlag(BufferStatus.Playing)) { Thread.Sleep(1); }

If a buffer never starts, whichever thread called that wedges forever. Because
`AudioHelper` guards all audio behind a single static `isBusy` flag, a wedged thread means
every later sound is skipped, so audio dies silently for the rest of the session.

`soundengine-audio-fix.patch` fixes all three: the device is shared rather than created per
sound, buffers are disposed, and both wait loops get timeouts.

### Key names in help boxes

LCPDFR does not draw a key name itself. `LCPDFR/GUI/TextHelper.cs` swaps `~KEY_ARREST~` in
a hint for one of eight of the game's replay prompts, such as
`~INPUT_FRONTEND_REPLAY_CYCLEMARKERLEFT~`, and overwrites that prompt's text in memory with
the real key through `AdvancedHookManaged.AGame.RegisterReplacementText`. On Complete
Edition the overwrite no longer lands, a known issue of the compatibility patch, so the
prompt shows the replay editor's own key and hints read "press , to open door".

`helpbox-key-names.patch` writes the key name into the help text instead, as plain text in
the help box's own white, with any modifier as `Alt + E`. It still reads the game's file
version once and keeps the original path on 1.0.x, so the DLL stays harmless if it ever
lands on the Original Edition. `LCPDFR.log` records which was chosen, under `TextHelper`.
Arrow keys and controller buttons already use the game's real `PAD_` icons and are not
touched.

### Peds in vehicles LCPDFR does not track

`CPed.CurrentVehicle` looks the game's vehicle up in LCPDFR's own vehicle pool. On Complete
Edition some peds are in a vehicle the pool does not hold, so `IsInVehicle` is true while
`CurrentVehicle` is null. Code that assumed a vehicle is always found then throws, and
LCPDFR's `ScriptManager` removes the script that threw for the rest of the session. Seen
removing `AimingManager` (aiming interactions) and `KeyBindings` (every hotkey, Alt+E
included).

`ped-untracked-vehicle.patch` guards the places seen failing and the one other unchecked
lookup in the same two scripts: the aimed-at ped's vehicle speed and the order to leave a
vehicle in `AimingManager`, the suspect transporter check in `CPed.IsPedValid`, and the
pursuit suspect's is-it-a-bike check in `KeyBindings`. It also logs each such ped once, to
find out which vehicles the pool misses:

    [WARNING] [CPed] CurrentVehicle: ped <handle> (<model>, <group>) is in a vehicle the vehicle
    pool does not track: handle <n>, model 0x<hash>, exists <bool>. Pool holds <n> vehicles.

LCPDFR reads `CurrentVehicle.` without a check in about 200 other places, so more may turn
up; the log line is how they would be found.

**The likely root cause, and a fix for it.** After startup, LCPDFR learns about new vehicles
and peds only through AdvancedHook: `PoolUpdaterUnmanaged` hooks the game's creation
functions with `AVehicle.HookCreateVehicle` and `APed.HookCreatePed`, then each frame adds
whatever those report. LCPDFR's own DLL is byte-identical between the Original and Complete
Edition packages; what differs is AdvancedHook, rebuilt for Complete Edition and documented
by its author as having functions that "don't operate correctly due to changed offsets". A
creation hook that misses some of Complete Edition's spawn paths would leave exactly these
untracked vehicles.

So the patch also makes `UpdatePools` reconcile the pools against the game's own lists
through ScriptHookDotNet every two seconds, as the constructor does once at startup, adding
anything the hooks missed and logging the count:

    [WARNING] [PoolUpdater] ReconcileWithGame: creation hooks missed <n> vehicle(s) and <n>
    ped(s), added now. Session total: <n> vehicle(s), <n> ped(s). ...

They do appear, heavily: 1510 vehicles and 1213 peds missed in one ten-minute session.

The deletion hook misses as well, so vehicles the game removed stayed in the pool: 1546
entries against about 100 real vehicles, until the game crashed on LCPDFR's thread reading
through a null entity pointer. So each pass also prunes pool vehicles the game no longer
lists, compared against the game's own list so that no native is ever called with a stale
handle. Peds are only counted, since their pool stays a normal size. The log line reports
added, pruned and the pool sizes against the game's:

    ... pruned <n> vehicle(s) the game no longer has. Session total: ... Pools hold <n>
    vehicles (game <n>), <n> peds (game <n>, <n> not in game).

## Building

Requires `git`, `mcs` and `resgen` (mono-devel), and **LCPDFR 1.1 Legacy installed on
Complete Edition**, because every reference assembly comes from the install rather than from
this repository:

    AdvancedHook.dll                              Lidgren.Network.dll
    Newtonsoft.Json.dll                           protobuf-net.dll
    SlimDX.dll                                    LCPDFR.Networking.dll
    scripts/LCPDFR Loader.net.dll                 LCPDFR/API Example/References/ScriptHookDotNet.dll

plus `System.Speech.dll` from the Complete Edition Proton prefix (appid 12210), so .NET 4
must be installed there. The script checks all of them up front and names whichever is
missing. `GAME_DIR` and `PREFIX` override the locations.

The source itself is cloned from upstream automatically; nothing is vendored here.

    ./build.sh                 # clone, patch, build into this directory
    ./build.sh --install       # also swap it into the game, backing up the original
    ./build.sh --restore       # put the original DLL back

The build verifies what it produced rather than trusting it, and knows the stock DLL's hash
so `--restore` cannot hand back one of its own builds by mistake.

`collect-resources.py` compiles the embedded resources the build needs. Without them the
build compiles but throws `MissingManifestResourceException` at runtime, because
`CultureHelper` and the WinForms designers look their resources up by name. It reads the
`.resx` files from the upstream source clone and compiles them with `ResxCompile.exe`
rather than `resgen`, which drops external file references and gets line endings wrong.
The manifest name is the root namespace plus the project-relative path with separators
turned into dots, which is what the compiled code expects. The shipped DLL's resource names
are obfuscated; a local build's are not, so the natural names are the correct ones.

You do not need to do any of that by hand. `build.sh` runs it, and the generated `res/`
folder is gitignored as build output. `ResxCompile.cs` and `VerifyBuild.cs` are small
helpers it compiles itself when their `.exe` is missing or older than the source.

Note that every build produces a different hash: `mcs` stamps a fresh MVID into each
assembly, so even a comment-only edit changes it. The patched build identifies itself with
a marker string instead, which is what tooling should match on.

## Licence

LCPDFR's source is under the **LCPDFR Software License 1.0**, an altered Boost licence. It
permits use, execution and derivative works, and it *requires* that derivative works be
made available publicly, free of charge, under the same licence. It does not permit
distributing compiled binaries without explicit permission.

This repository therefore contains source only. `LCPD First Response.dll` is deliberately
excluded and gitignored, as is the generated `res/` folder, which is build output.
`LICENSE.md` carries the upstream licence text in full, including the SlimDX, Lidgren,
protobuf-net and Hazard notices it incorporates, as the licence requires.

Upstream source: https://github.com/LMSDev/lcpdfr_public

## Scope

GTA IV: Complete Edition 1.2.0.59 with LCPDFR 1.1 Legacy Edition and the Complete Edition
compatibility patch 0.4, under Proton. Legacy Edition's `LCPD First Response.dll` is
byte-identical to non-Legacy 1.1's, so the same source applies.
