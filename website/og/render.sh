#!/usr/bin/env bash
# Renders the social share card to public/images/og-cover.png.
#
# The card is HTML rather than a drawing so it keeps using the app's own tokens,
# type and popover measurements. Chrome draws it at 2x and the result is scaled
# down to the 1200x630 every platform expects, which keeps the text crisp and
# the file small enough for the slower scrapers (WhatsApp, iMessage).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/../public/images/og-cover.png"
tmp="$(mktemp -d)"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

if [[ ! -x "$chrome" ]]; then
  echo "Chrome not found at $chrome — set CHROME=/path/to/chrome" >&2
  exit 1
fi

# The card loads its fonts from Google Fonts, so give the render time to settle.
"$chrome" --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=1200,630 \
  --virtual-time-budget=6000 \
  --screenshot="$tmp/og@2x.png" "$here/og-cover.html" >/dev/null 2>&1

sips -z 630 1200 -s format png "$tmp/og@2x.png" --out "$out" >/dev/null
rm -rf "$tmp"
echo "wrote $out"
