#!/usr/bin/env bash
#
# build.sh - build LCPDFR 1.1 from public source for GTA IV: Complete Edition.
#
# The Complete Edition fork of lcpdfr-1.1-audiofix. It builds against the Complete Edition
# install (1.2.0.59 with LCPDFR 1.1 Legacy Edition, whose LCPD First Response.dll is
# byte-identical to non-Legacy 1.1's) and applies these patches to LMS's public source:
#
#   soundengine-audio-fix.patch   the DirectSound device leak and two untimed waits, as in
#                                 lcpdfr-1.1-audiofix. See TODO.md item 2.
#
# See TODO.md item 5.
#
# LICENSING. The LCPDFR source is under an altered Boost licence that permits use,
# execution and derivative works, but **forbids distributing the compiled binary**. So this
# builds locally and the DLL is never committed or shipped. The patch itself is source and
# is kept here, which the licence requires of derivative works.
#
# Requires: git, mcs (mono-devel), and LCPDFR 1.1 Legacy installed on Complete Edition for
# the reference assemblies.
#
#   ./build.sh                 # clone, patch, build into this directory
#   ./build.sh --install       # also swap it into the game, backing up the original
#   ./build.sh --restore       # put the original LCPDFR dll back
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODDING_DIR="$(cd "$HERE/../.." && pwd)"

# lib/common.sh resolves STEAM_COMMON and STEAM_LIB_ROOTS from Steam's own library
# manifest, so neither drive names nor an appid need to be written down here.
. "$MODDING_DIR/lib/common.sh"

# Complete Edition is a Steam game with a fixed appid, so its prefix is found by that.
CE_APPID=12210

GAME_DIR="${GAME_DIR:-$STEAM_COMMON/Grand Theft Auto IV/GTAIV}"
PREFIX="${PREFIX:-$(find_prefix "$CE_APPID" || true)/pfx}"
REPO="https://github.com/LMSDev/lcpdfr_public.git"
WORK="$HERE/work"
TARGET="$GAME_DIR/LCPD First Response.dll"
BUILT="$HERE/LCPD First Response.dll"

die() { echo "error: $*" >&2; exit 1; }

# The stock DLL's hash, from the vendor manifest. Used to tell a genuine backup from one
# of our own builds: after the first install, the newest backup is a patched DLL, so
# "restore the newest" would quietly hand back a patched file and look like a revert.
stock_hash() {
    local manifest="$MODDING_DIR/manifests/lcpdfr-1.1.tsv"
    [ -f "$manifest" ] || return 1
    awk -F'\t' '$3 == "LCPD First Response.dll" { print $1; exit }' "$manifest"
}

restore() {
    local expected candidate found=""
    expected=$(stock_hash) || true

    # Newest first, so a hand-placed stock copy wins over an older one.
    while IFS= read -r candidate; do
        if [ -n "$expected" ]; then
            [ "$(sha256sum "$candidate" | cut -d' ' -f1)" = "$expected" ] || continue
        fi
        found="$candidate"
        break
    done < <(ls -t "$MODDING_DIR/backups"/LCPD\ First\ Response.dll.* 2>/dev/null)

    if [ -z "$found" ]; then
        if [ -n "$expected" ]; then
            die "no backup matching the stock 1.1 hash found; reinstall LCPDFR from vendor instead"
        fi
        die "no backup found in $MODDING_DIR/backups"
    fi

    cp -- "$found" "$TARGET"
    echo "restored stock LCPDFR from: ${found##*/}"
    exit 0
}

[ "${1:-}" = "--restore" ] && restore

command -v git >/dev/null || die "git is required"
command -v mcs >/dev/null || die "mcs is required (install mono-devel)"
[ -d "$GAME_DIR" ] || die "game directory not found: $GAME_DIR"

SPEECH="$PREFIX/drive_c/windows/Microsoft.NET/assembly/GAC_MSIL/System.Speech/v4.0_4.0.0.0__31bf3856ad364e35/System.Speech.dll"
[ -f "$SPEECH" ] || die "System.Speech.dll not found in the prefix; is .NET 4 installed there?"

# Reference assemblies all come from the installed LCPDFR, so it must be installed first.
for dll in "AdvancedHook.dll" "Lidgren.Network.dll" "Newtonsoft.Json.dll" "protobuf-net.dll" \
           "SlimDX.dll" "LCPDFR.Networking.dll" "scripts/LCPDFR Loader.net.dll" \
           "LCPDFR/API Example/References/ScriptHookDotNet.dll"; do
    [ -f "$GAME_DIR/$dll" ] || die "missing reference: $GAME_DIR/$dll (run setup-complete-edition.sh --with-lcpdfr first)"
done

if [ ! -d "$WORK/.git" ]; then
    echo "cloning LCPDFR public source..."
    rm -rf "$WORK"
    git clone --depth 1 -q "$REPO" "$WORK"
else
    echo "reusing existing clone, resetting to pristine..."
    git -C "$WORK" checkout -- . 2>/dev/null || true
fi

for patch in soundengine-audio-fix.patch; do
    echo "applying $patch..."
    git -C "$WORK" apply "$HERE/$patch" \
        || die "$patch did not apply; upstream source may have changed"
done

# The project's own file list, rather than every .cs on disk: the repo contains stray files
# that were never part of the build and do not compile, such as a second KeyHandler.cs and
# an unreferenced Protocol.cs.
SOURCES="$HERE/.sources.rsp"
python3 - "$WORK/LCPD First Response/LCPD First Response.csproj" "$SOURCES" <<'PY'
import html, re, sys
src = open(sys.argv[1], encoding="utf-8-sig").read()
files = [html.unescape(m).replace("\\", "/") for m in re.findall(r'<Compile Include="([^"]*)"', src)]
open(sys.argv[2], "w").write("\n".join(f'"{f}"' for f in files) + "\n")
print(f"  {len(files)} source files")
PY

# Embedded resources: translations, form layouts, images. Without them the build compiles
# but throws MissingManifestResourceException at runtime. See collect-resources.py.
# The two helpers are gitignored build output (*.exe), so a fresh clone has neither. Compile
# each from its .cs when missing or older than the source.
build_helper() {
    local name="$1"; shift
    local exe="$HERE/$name.exe"
    if [ ! -f "$exe" ] || [ "$HERE/$name.cs" -nt "$exe" ]; then
        echo "compiling $name.exe..."
        mcs -out:"$exe" "$@" "$HERE/$name.cs" >/dev/null || die "could not compile $name.exe"
    fi
}
build_helper ResxCompile -r:System.Windows.Forms.dll

echo "compiling embedded resources..."
RESARGS="$HERE/.resources.rsp"
command -v resgen >/dev/null || die "resgen is required (mono-devel)"
python3 "$HERE/collect-resources.py" \
    "$WORK/LCPD First Response/LCPD First Response.csproj" \
    "$WORK/LCPD First Response" \
    "$HERE/res" \
    "$RESARGS" || die "resource compilation failed"

echo "building..."
( cd "$WORK/LCPD First Response" && mcs -target:library -platform:x86 -sdk:4.5 -unsafe \
    -out:"$BUILT" \
    -r:"$GAME_DIR/AdvancedHook.dll" \
    -r:"$GAME_DIR/Lidgren.Network.dll" \
    -r:"$GAME_DIR/Newtonsoft.Json.dll" \
    -r:"$GAME_DIR/protobuf-net.dll" \
    -r:"$GAME_DIR/LCPDFR/API Example/References/ScriptHookDotNet.dll" \
    -r:"$GAME_DIR/SlimDX.dll" \
    -r:"$SPEECH" \
    -r:"$GAME_DIR/LCPDFR.Networking.dll" \
    -r:"$GAME_DIR/scripts/LCPDFR Loader.net.dll" \
    -r:System.dll -r:System.Core.dll -r:System.Drawing.dll -r:System.Management.dll \
    -r:System.Web.dll -r:System.Web.Extensions.dll -r:System.Windows.Forms.dll \
    -r:System.Xml.dll -r:System.Xml.Linq.dll -r:System.Data.dll -r:WindowsBase.dll \
    "@$RESARGS" "@$SOURCES" ) || die "build failed"

echo "built: $BUILT ($(stat -c%s "$BUILT") bytes)"

# Verify the resources LCPDFR reads at runtime. Three separate failures compiled cleanly
# and only surfaced in-game, so this checks them before the DLL can be installed.
if command -v mono >/dev/null; then
    echo "verifying resources..."
    DNLIB=$(ls /usr/lib/mono/gac/dnlib/*/dnlib.dll 2>/dev/null | head -1)
    if [ -n "$DNLIB" ]; then
        build_helper VerifyBuild -r:"$DNLIB"
        MONO_PATH="$(dirname "$DNLIB")" mono "$HERE/VerifyBuild.exe" "$BUILT" \
            || die "resource verification failed; not installing"
    else
        echo "  dnlib not found, skipping verification"
    fi
fi

if [ "${1:-}" = "--install" ]; then
    mkdir -p "$MODDING_DIR/backups"
    # Only back up a stock DLL. Backing up our own build on every reinstall fills the
    # directory with copies and makes it harder to find the one real original.
    expected=$(stock_hash) || true
    if [ -n "$expected" ] && [ "$(sha256sum "$TARGET" | cut -d' ' -f1)" != "$expected" ]; then
        echo "already patched; keeping the existing stock backup"
    else
        backup="$MODDING_DIR/backups/LCPD First Response.dll.$(date +%Y%m%d-%H%M%S)"
        cp -- "$TARGET" "$backup"
        echo "backed up original to: ${backup##*/}"
    fi
    cp -- "$BUILT" "$TARGET"
    echo "installed. Run with --restore to put the original back."
fi
