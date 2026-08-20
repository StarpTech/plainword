# README artwork

Plainword Ink renders used in the top-level README. Tokens are copied from
`Sources/PlainwordApp/DesignSystem.swift` (and match `website/src/index.css`) — keep them in sync.

Regenerate after editing:

```sh
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
  --window-size=1280,440 --virtual-time-budget=6000 \
  --screenshot=docs/images/readme-hero.png docs/design/readme-hero.html
"$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
  --window-size=1240,470 --virtual-time-budget=6000 \
  --screenshot=docs/images/readme-shortcuts.png docs/design/readme-shortcuts.html
```

`--virtual-time-budget` gives the Google Fonts (Newsreader, Nunito Sans, Fragment Mono) time to load.
