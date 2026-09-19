# lcpdfr-1.1-audiofix

A source patch for LCPDFR 1.1 that fixes the DirectSound device leak, plus the tooling to
rebuild `LCPD First Response.dll` from LMS's public source with the patch applied.

**No binaries are distributed here, by licence.** See *Licence* below. You build it
yourself; everything needed to do that is in this repository.

## The defect

`Engine/IO/SoundEngine.cs` `PlayExternalSound` creates a fresh DirectSound device and a
`SecondarySoundBuffer` for every sound played, and disposes neither. SlimDX roots every
`ComObject` in a static `ObjectTable`, so nothing is ever finalised.

Under Wine each device is a WASAPI endpoint that keeps a mixer thread alive, and each
thread reserves about 1 MB of address space. A 32-bit process exhausts its address space
after roughly 330 sounds, and the constructor then throws
`AUDCLNT_E_ENDPOINT_CREATE_FAILED` (`0x8889000F`) on a bare thread with no handler, which
terminates the game.

The same method also contains two untimed wait loops:

    while (!secondarySoundBuffer.Status.HasFlag(BufferStatus.Playing)) { Thread.Sleep(1); }

If a buffer never starts, whichever thread called that wedges forever. Because
`AudioHelper` guards all audio behind a single static `isBusy` flag, a wedged thread means
every later sound is skipped, so audio dies silently for the rest of the session.

`soundengine-audio-fix.patch` fixes all three: the device is shared rather than created per
sound, buffers are disposed, and both wait loops get timeouts.

## Building

Requires `git`, `mcs` (mono-devel), and an installed LCPDFR 1.1 for its reference
assemblies.

    ./build.sh                 # clone, patch, build into this directory
    ./build.sh --install       # also swap it into the game, backing up the original
    ./build.sh --restore       # put the original DLL back

The build verifies what it produced rather than trusting it, and knows the stock DLL's hash
so `--restore` cannot hand back one of its own builds by mistake.

`collect-resources.py` extracts the resources the build needs from the installed assembly;
`ResxCompile.cs` and `VerifyBuild.cs` are small helpers used by `build.sh`.

Note that every build produces a different hash: `mcs` stamps a fresh MVID into each
assembly, so even a comment-only edit changes it. The patched build identifies itself with
a marker string instead, which is what tooling should match on.

## Licence

LCPDFR's source is under the **LCPDFR Software License 1.0**, an altered Boost licence. It
permits use, execution and derivative works, and it *requires* that derivative works be
made available publicly, free of charge, under the same licence. It does not permit
distributing compiled binaries without explicit permission.

This repository therefore contains source only. `LCPD First Response.dll` and the extracted
`res/` resources are deliberately excluded and gitignored. `LICENSE.md` carries the
upstream licence text in full, including the SlimDX, Lidgren, protobuf-net and Hazard
notices it incorporates, as the licence requires.

Upstream source: https://github.com/LMSDev/lcpdfr_public

## Scope

GTA IV 1.0.7.0 with LCPDFR 1.1 non-Legacy, under Proton. The leak exists on Windows too,
but the address-space ceiling is reached far sooner under Wine because of the per-endpoint
mixer threads.
