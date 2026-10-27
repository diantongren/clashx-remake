#!/bin/bash
# Downloads the mihomo release for both Mac architectures, builds a universal binary,
# gzips it into App/Resources/Core and writes the manifest the app verifies against.
#
#   scripts/fetch-core.sh            # latest stable release
#   scripts/fetch-core.sh v1.19.33   # specific tag
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/App/Resources/Core"
TAG="${1:-${MIHOMO_TAG:-}}"

if [ -z "$TAG" ]; then
  TAG=$(curl -sI https://github.com/MetaCubeX/mihomo/releases/latest | grep -i '^location:' | sed -E 's#.*/tag/##' | tr -d '\r\n')
fi
[ -n "$TAG" ] || { echo "could not resolve mihomo tag" >&2; exit 1; }
echo "mihomo tag: $TAG"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
for arch in arm64 amd64; do
  curl -fsSL -o "mihomo-$arch.gz" "https://github.com/MetaCubeX/mihomo/releases/download/$TAG/mihomo-darwin-$arch-$TAG.gz"
  gzip -d "mihomo-$arch.gz"
done
lipo -create -output mihomo mihomo-arm64 mihomo-amd64
SHA=$(shasum -a 256 mihomo | cut -d' ' -f1)
SIZE=$(stat -f%z mihomo)

mkdir -p "$OUT"
gzip -9 -c mihomo > "$OUT/mihomo.gz"
cat > "$OUT/core-manifest.json" <<JSON
{
  "name": "mihomo",
  "version": "$TAG",
  "archs": ["arm64", "x86_64"],
  "archive": "mihomo.gz",
  "sha256": "$SHA",
  "size": $SIZE,
  "source": "https://github.com/MetaCubeX/mihomo/releases/tag/$TAG"
}
JSON
echo "wrote $OUT/mihomo.gz ($(du -h "$OUT/mihomo.gz" | cut -f1)) and core-manifest.json"

# Geo databases, seeded into the profile folder on first run when missing.
for name in geosite.dat geoip.dat country.mmdb; do
  curl -fsSL -o "$name" "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/$name"
  gzip -9 -c "$name" > "$OUT/$name.gz"
  echo "wrote $OUT/$name.gz"
done
