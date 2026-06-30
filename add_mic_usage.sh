#!/bin/bash
#
# add_mic_usage.sh
#
# Adds INFOPLIST_KEY_NSMicrophoneUsageDescription to the app target's
# Debug and Release build configurations in project.pbxproj.
#
# Safe to run: refuses to run while Xcode is open, backs up the file first,
# and is idempotent (does nothing if the key is already present).
#
set -euo pipefail

PROJ="/Users/justinmann/Documents/Untitled Project/Untitled Project.xcodeproj/project.pbxproj"
USAGE_STRING="This app uses the microphone to capture your voice for SSB, AM, and FM transmission through your connected radio."

# 1. Refuse to run while Xcode is open (editing the file under it can corrupt the project).
if pgrep -x Xcode >/dev/null 2>&1; then
    echo "❌ Xcode is still running. Please fully quit Xcode (Cmd-Q) and run this script again."
    exit 1
fi

# 2. Sanity check the project file exists.
if [ ! -f "$PROJ" ]; then
    echo "❌ Could not find project file at:"
    echo "   $PROJ"
    exit 1
fi

# 3. Idempotency: bail out if the key is already there.
if grep -q "INFOPLIST_KEY_NSMicrophoneUsageDescription" "$PROJ"; then
    echo "✅ INFOPLIST_KEY_NSMicrophoneUsageDescription is already present. Nothing to do."
    exit 0
fi

# 4. Back up the original.
BACKUP="${PROJ}.bak.$(date +%Y%m%d-%H%M%S)"
cp "$PROJ" "$BACKUP"
echo "🗄  Backup written to: $BACKUP"

# 5. Insert the key right after each 'GENERATE_INFOPLIST_FILE = YES;' line
#    (this line appears only in the two app-target configs), preserving indentation.
TMP="$(mktemp)"
USAGE_STRING="$USAGE_STRING" awk '
/GENERATE_INFOPLIST_FILE = YES;/ {
    print
    match($0, /^[ \t]*/)
    indent = substr($0, 1, RLENGTH)
    printf "%sINFOPLIST_KEY_NSMicrophoneUsageDescription = \"%s\";\n", indent, ENVIRON["USAGE_STRING"]
    next
}
{ print }
' "$PROJ" > "$TMP"

# 6. Verify we actually inserted it (expect 2 occurrences, one per config).
COUNT=$(grep -c "INFOPLIST_KEY_NSMicrophoneUsageDescription" "$TMP" || true)
if [ "$COUNT" -lt 1 ]; then
    echo "❌ Insertion failed (no key written). Leaving original untouched."
    rm -f "$TMP"
    exit 1
fi

mv "$TMP" "$PROJ"
echo "✅ Added INFOPLIST_KEY_NSMicrophoneUsageDescription to $COUNT build configuration(s)."
echo "   You can now reopen Xcode."
