#!/bin/zsh
# Recompile mediaremote-adapter (si une mise à jour de macOS le casse) et le copie dans Vendor/.
set -euo pipefail
ROOT="${0:A:h:h}"
TMP="$(mktemp -d)"
git clone --depth 1 https://github.com/ungive/mediaremote-adapter.git "$TMP/mra"
cmake -S "$TMP/mra" -B "$TMP/mra/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$TMP/mra/build"
DEST="$ROOT/Vendor/MediaRemoteAdapter"
rm -rf "$DEST/MediaRemoteAdapter.framework"
cp -R "$TMP/mra/build/MediaRemoteAdapter.framework" "$DEST/"
cp "$TMP/mra/build/MediaRemoteAdapterTestClient" "$TMP/mra/bin/mediaremote-adapter.pl" "$DEST/"
cp "$TMP/mra/LICENSE" "$DEST/LICENSE-mediaremote-adapter"
codesign -f -s - "$DEST/MediaRemoteAdapter.framework" "$DEST/MediaRemoteAdapterTestClient"
/usr/bin/perl "$DEST/mediaremote-adapter.pl" "$DEST/MediaRemoteAdapter.framework" "$DEST/MediaRemoteAdapterTestClient" test \
  && echo "✅ adapter OK" || echo "⚠️ adapter KO : LockPlayer utilisera AppleScript Spotify"
rm -rf "$TMP"
