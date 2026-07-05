#!/bin/zsh
# Adds the local FT8Kit Swift package to machpsdr.xcodeproj:
#   - package reference (XCLocalSwiftPackageReference)
#   - FT8Kit product linked to the machpsdr app target
#   - FT8Kit product linked to the machpsdrTests target
#
# Run this with Xcode CLOSED, then reopen the project:
#   ./add-ft8kit.sh
#
# A timestamped backup of project.pbxproj is written next to the original.

set -euo pipefail
cd "$(dirname "$0")"

PBX="machpsdr.xcodeproj/project.pbxproj"

if [[ ! -f "$PBX" ]]; then
    echo "error: $PBX not found (run from the repo root)" >&2
    exit 1
fi

if grep -q 'FT8Kit' "$PBX"; then
    echo "FT8Kit is already referenced in $PBX — nothing to do."
    exit 0
fi

if pgrep -x Xcode >/dev/null; then
    echo "warning: Xcode appears to be running. Close it first, then re-run." >&2
    exit 1
fi

BACKUP="$PBX.backup-$(date +%Y%m%d-%H%M%S)"
cp "$PBX" "$BACKUP"
echo "Backup written to $BACKUP"

python3 - "$PBX" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    text = f.read()

# (anchor, replacement) pairs; every anchor must occur exactly once.
edits = [
    # 1. PBXBuildFile entries (one per target)
    (
        "\t\t7F8CA0AF2FF3228D003092CB /* CWDSP in Frameworks */ = {isa = PBXBuildFile; productRef = 7F8CA0AE2FF3228D003092CB /* CWDSP */; };\n",
        "\t\t7F8CA0AF2FF3228D003092CB /* CWDSP in Frameworks */ = {isa = PBXBuildFile; productRef = 7F8CA0AE2FF3228D003092CB /* CWDSP */; };\n"
        "\t\tF8000000000000000000A001 /* FT8Kit in Frameworks */ = {isa = PBXBuildFile; productRef = F8000000000000000000A002 /* FT8Kit */; };\n"
        "\t\tF8000000000000000000A003 /* FT8Kit in Frameworks */ = {isa = PBXBuildFile; productRef = F8000000000000000000A004 /* FT8Kit */; };\n",
    ),
    # 2. App target Frameworks build phase
    (
        "\t\t\t\t7F8CA0AF2FF3228D003092CB /* CWDSP in Frameworks */,\n",
        "\t\t\t\t7F8CA0AF2FF3228D003092CB /* CWDSP in Frameworks */,\n"
        "\t\t\t\tF8000000000000000000A001 /* FT8Kit in Frameworks */,\n",
    ),
    # 3. Test target Frameworks build phase (currently empty)
    (
        "\t\t000000000000000230000000 /* Frameworks */ = {\n"
        "\t\t\tisa = PBXFrameworksBuildPhase;\n"
        "\t\t\tfiles = (\n"
        "\t\t\t);\n",
        "\t\t000000000000000230000000 /* Frameworks */ = {\n"
        "\t\t\tisa = PBXFrameworksBuildPhase;\n"
        "\t\t\tfiles = (\n"
        "\t\t\t\tF8000000000000000000A003 /* FT8Kit in Frameworks */,\n"
        "\t\t\t);\n",
    ),
    # 4. App target packageProductDependencies
    (
        "\t\t\t\t7F8CA0AE2FF3228D003092CB /* CWDSP */,\n",
        "\t\t\t\t7F8CA0AE2FF3228D003092CB /* CWDSP */,\n"
        "\t\t\t\tF8000000000000000000A002 /* FT8Kit */,\n",
    ),
    # 5. Test target packageProductDependencies (new block)
    (
        "\t\t\tname = machpsdrTests;\n",
        "\t\t\tname = machpsdrTests;\n"
        "\t\t\tpackageProductDependencies = (\n"
        "\t\t\t\tF8000000000000000000A004 /* FT8Kit */,\n"
        "\t\t\t);\n",
    ),
    # 6. Project packageReferences
    (
        "\t\t\t\t7F8CA0AD2FF3228D003092CB /* XCLocalSwiftPackageReference \"WDSPKit\" */,\n",
        "\t\t\t\t7F8CA0AD2FF3228D003092CB /* XCLocalSwiftPackageReference \"WDSPKit\" */,\n"
        "\t\t\t\tF8000000000000000000A005 /* XCLocalSwiftPackageReference \"FT8Kit\" */,\n",
    ),
    # 7. XCLocalSwiftPackageReference section
    (
        "\t\t7F8CA0AD2FF3228D003092CB /* XCLocalSwiftPackageReference \"WDSPKit\" */ = {\n"
        "\t\t\tisa = XCLocalSwiftPackageReference;\n"
        "\t\t\trelativePath = WDSPKit;\n"
        "\t\t};\n",
        "\t\t7F8CA0AD2FF3228D003092CB /* XCLocalSwiftPackageReference \"WDSPKit\" */ = {\n"
        "\t\t\tisa = XCLocalSwiftPackageReference;\n"
        "\t\t\trelativePath = WDSPKit;\n"
        "\t\t};\n"
        "\t\tF8000000000000000000A005 /* XCLocalSwiftPackageReference \"FT8Kit\" */ = {\n"
        "\t\t\tisa = XCLocalSwiftPackageReference;\n"
        "\t\t\trelativePath = FT8Kit;\n"
        "\t\t};\n",
    ),
    # 8. XCSwiftPackageProductDependency section
    (
        "\t\t7F8CA0AE2FF3228D003092CB /* CWDSP */ = {\n"
        "\t\t\tisa = XCSwiftPackageProductDependency;\n"
        "\t\t\tproductName = CWDSP;\n"
        "\t\t};\n",
        "\t\t7F8CA0AE2FF3228D003092CB /* CWDSP */ = {\n"
        "\t\t\tisa = XCSwiftPackageProductDependency;\n"
        "\t\t\tproductName = CWDSP;\n"
        "\t\t};\n"
        "\t\tF8000000000000000000A002 /* FT8Kit */ = {\n"
        "\t\t\tisa = XCSwiftPackageProductDependency;\n"
        "\t\t\tproductName = FT8Kit;\n"
        "\t\t};\n"
        "\t\tF8000000000000000000A004 /* FT8Kit */ = {\n"
        "\t\t\tisa = XCSwiftPackageProductDependency;\n"
        "\t\t\tproductName = FT8Kit;\n"
        "\t\t};\n",
    ),
]

for i, (old, new) in enumerate(edits, 1):
    count = text.count(old)
    if count != 1:
        sys.exit(f"error: edit {i} anchor matched {count} times (expected 1) — "
                 "project file layout changed; aborting without writing.")
    text = text.replace(old, new)

with open(path, "w", encoding="utf-8") as f:
    f.write(text)

print("All 8 edits applied.")
PYEOF

# Sanity-check the plist still parses.
if plutil -lint "$PBX" >/dev/null; then
    echo "project.pbxproj lints OK."
else
    echo "error: project.pbxproj failed to lint — restoring backup." >&2
    cp "$BACKUP" "$PBX"
    exit 1
fi

echo
echo "Done. FT8Kit is now referenced by the project and linked to both the"
echo "machpsdr and machpsdrTests targets. Reopen Xcode and build."
