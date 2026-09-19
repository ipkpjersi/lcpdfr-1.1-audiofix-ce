#!/usr/bin/env python3
"""Compile and name the embedded resources for a local LCPDFR build.

Without these the build compiles but throws MissingManifestResourceException at runtime:
CultureHelper and the WinForms designers look their resources up by name when loaded.

.resx files are compiled to .resources with ResxCompile.exe rather than resgen, which
drops external file references and gets line endings wrong. The manifest name is RootNamespace
plus the project-relative path with separators turned into dots, which is what the
compiled code expects. The shipped DLL's own resource names are obfuscated, but a local
build is not, so the natural names are the correct ones here.

    collect-resources.py <csproj> <project-dir> <output-dir> <response-file>
"""

import html
import os
import re
import subprocess
import sys

ROOT_NAMESPACE = "LCPD_First_Response"

# <data ... type="System.Resources.ResXFileRef ...><value>PATH;TYPE;ENCODING</value>
def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__.strip().splitlines()[-1].strip(), file=sys.stderr)
        return 2

    csproj, project_dir, out_dir, response_file = sys.argv[1:5]
    os.makedirs(out_dir, exist_ok=True)

    source = open(csproj, encoding="utf-8-sig").read()
    items = [html.unescape(m) for m in re.findall(r'<EmbeddedResource Include="([^"]*)"', source)]

    lines = []
    missing = 0
    for item in items:
        relative = item.replace("\\", "/")
        full = os.path.join(project_dir, relative)
        if not os.path.isfile(full):
            print(f"  missing resource, skipped: {relative}", file=sys.stderr)
            missing += 1
            continue

        name = ROOT_NAMESPACE + "." + relative.replace("/", ".")
        if relative.lower().endswith(".resx"):
            name = name[: -len(".resx")] + ".resources"
            compiled = os.path.join(out_dir, name)
            # ResxCompile rather than resgen: it resolves ResXFileRef entries and
            # normalises line endings to CRLF, both of which resgen gets wrong here.
            compiler = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ResxCompile.exe")
            result = subprocess.run(["mono", compiler, full, compiled],
                                    capture_output=True, text=True)
            if result.returncode != 0:
                print(f"  resource compile failed for {relative}: {result.stderr.strip()[:140]}",
                      file=sys.stderr)
                return 1
            lines.append(f'-resource:"{compiled}","{name}"')
        else:
            lines.append(f'-resource:"{full}","{name}"')

    with open(response_file, "w") as stream:
        stream.write("\n".join(lines) + "\n")

    print(f"  {len(lines)} resources" + (f", {missing} missing" if missing else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
