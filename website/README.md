# Plainword landing page

Marketing one-pager for Plainword, built with Vite + React 18 + Tailwind CSS v4.
It uses the app's own design system — **Plainword Ink** — and, instead of
screenshots, rebuilds the product's interface live on the page.

## Getting started

```sh
npm install
npm run dev      # local dev server
npm run build    # production build to dist/
```

## Structure

```
src/
  content.js            # All copy, links and data (edit text here)
  App.jsx               # Page composition
  components/
    Backdrop.jsx        # Paper gradient + one faint ink wash
    Nav.jsx
    Hero.jsx            # Headline, CTA, shortcut hint
    Demo.jsx            # Tab rail + the live product demo (see below)
    Features.jsx        # Three feature cards, menu-bar card, app chips
    VoiceSection.jsx    # "Teach it how you write" + a live Writing settings page
    ContextSection.jsx  # Privacy: the reading-area diagram
    Providers.jsx       # "Bring your own model"
    RecommendedModel.jsx
    DownloadCta.jsx
    Footer.jsx
  demo/
    scenes.js           # The three flows: Correct, Transform, Write
    useScenePlayer.js   # The timeline that plays one scene
    Stage.jsx           # Fixed-size stage, scaled to fit; anchors the popover
    DemoWindow.jsx      # Mail / Slack / browser chrome around the edited field
    Popover.jsx         # The correction popover itself, all phases
    hooks.js            # Media queries, reduced motion, in-view
og/
  og-cover.html         # The social share card, in HTML (see below)
  render.sh             # Renders it to public/images/og-cover.png
public/
  robots.txt            # Points at the sitemap
  sitemap.xml           # One URL, plus the share card as an image entry
  site.webmanifest
  images/               # Brand icon, favicons, share card, the OpenAI mark
```

## SEO and sharing

`index.html` carries the whole search and social surface, which is what
crawlers and unfurlers read from an SPA: title, description, canonical,
`robots`, Open Graph and Twitter cards, and one `SoftwareApplication` +
`WebSite` JSON-LD block. The canonical origin is **https://plainword.app** —
if it ever moves, change it there, in `public/sitemap.xml` and in
`public/robots.txt`.

The structured data only claims what the page backs up (free, macOS 14+,
open source). Don't add ratings or FAQ markup that isn't visible on the page;
Google treats that as spam.

## The share card

`og/og-cover.html` is the 1200x630 image every platform shows when the site is
linked. It is HTML rather than a drawing so it keeps using the Ink tokens, the
three type voices and the popover's real measurements — and so a copy change is
an edit, not a trip to a design tool.

```sh
npm run og    # renders og/og-cover.html -> public/images/og-cover.png
```

Chrome draws it at 2x and the script scales the result down to 1200x630, which
keeps the type crisp and the file around 340KB — small enough for the slower
unfurlers (WhatsApp, iMessage) and well under LinkedIn's and X's limits. After
changing it, re-run the script and commit the PNG; the `og:image:width/height`
tags in `index.html` assume 1200x630.

Its palette is the light "paper" theme, copied from `src/index.css`. Social
cards are shown as-is in both light and dark feeds, so it does not follow
`prefers-color-scheme` — keep the two copies of the tokens in sync by hand.

## The demo

`Demo.jsx` plays the app for real rather than showing pictures of it. The
popover is rebuilt to the handoff's measurements (352px panel, 42px header,
48px footer, 13px radius), the phases run in the app's order — shortcut →
processing → streaming → proposal → apply — and every user-visible string in
`scenes.js` is the string the shipped app actually shows. When a label changes
in `CorrectionPanelController.swift`, change it in `scenes.js` too.

Playback pauses when the stage scrolls out of view or the tab goes to the
background, auto-advances through the three flows until the reader picks a tab,
and under `prefers-reduced-motion` jumps straight to the proposal and holds it.

The panel is not a video. Changes/Revised, the context-receipt paperclip, ✕,
Dismiss and Apply are real buttons: pressing one stops the script and hands the
state to the reader (`manual` in `useScenePlayer`). Presses that end the flow —
Apply, Dismiss — hand control back after the app's own beat, so the scene picks
up again on its own. Controls the script is driving and the reader cannot act on
(the quick-action chips, the Transform button mid-typing) render as stills with
no hover affordance, so nothing offers a press it will not honour.

Below 640px the stage drops the app chrome and shows the field and the popover
alone, at close to full size, rather than scaling a whole window down to
illegibility.

## Design tokens

`src/index.css` holds the Ink palette as raw `--pw-*` custom properties on
`:root`, swapped wholesale under `prefers-color-scheme: dark` ("lamplight"),
and maps them onto Tailwind utilities in `@theme inline`. Components should
never hard-code a colour, radius or shadow.

Three type voices, matching the app: **Newsreader** (serif) writes, **Nunito
Sans** labels, **Fragment Mono** reports. Motion is one duration — 180ms
ease-out — with the app's `pwRise` / `pwPop` / `pwSweep` keyframes declared
once in `index.css`.

## Notes

- Set the real download and GitHub URLs in `src/content.js`.
- Provider logos for Ollama/Anthropic/Mistral load from cdn.simpleicons.org; the
  OpenAI mark is local (`public/images/openai.svg`, Bootstrap Icons, MIT). They
  are single-colour ink marks, so their chip stays paper-coloured in both themes.
- Fonts load from Google Fonts in `index.html`.
