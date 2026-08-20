# Handoff: Plainword Ink — full design system redesign

## Overview
A complete visual redesign of Plainword (macOS menu-bar writing assistant, SwiftUI). The new system — "Plainword Ink" — replaces the current lavender/glass identity with a warm editorial language: paper surfaces, forest-ink green accent, serif for prose, mono for machinery. It covers the correction popover and all its states/transitions, the entire Settings window, the menu bar item, and a new brand icon.

## About the Design Files
The `.dc.html` files in this bundle are **design references created in HTML** — interactive prototypes showing intended look and behavior, not production code. The task is to **recreate these designs in the existing SwiftUI codebase** (`Sources/PlainwordApp`), primarily by rewriting `DesignSystem.swift` (PlainwordTheme) tokens and restyling the existing views — the app's information architecture is unchanged.

## Fidelity
**High-fidelity.** Colors, typography, spacing, radii and motion are final. Recreate pixel-perfectly using the existing SwiftUI component patterns (`PlainwordButtonStyle`, `SettingsGroup`, `SettingsRow`, etc.).

## Design Tokens

### Color — Light ("paper")
| Token (PlainwordTheme) | Hex |
|---|---|
| canvas | #EFE9DD |
| surface | #FBF8F1 |
| raisedSurface | #F4EFE4 |
| fieldBackground | #F1EBDE |
| text (ink) | #26211A |
| textSecondary | #6F6759 |
| textTertiary | #9C937F |
| separator | #E3DCCB |
| strongSeparator (control borders) | #D2C9B4 |
| accent | #33684C |
| accentHover | #27543D |
| accentMuted (washes/badges) | #E3EBE0 |
| accentText (text on accent) | #F7F4EA |
| danger | #A6453E |
| dangerMuted | #F5E3DE |
| warning | #96690F |
| selectionWash | #E8E2D2 |
| shadow | 0 18px 44px rgba(72,56,28,.16) + 0 3px 8px rgba(72,56,28,.08) |

### Color — Dark ("lamplight")
| Token | Hex |
|---|---|
| canvas | #191612 |
| surface | #242019 |
| raisedSurface | #2B261E |
| fieldBackground | #1E1A14 |
| text | #EFE8DA |
| textSecondary | #A79D8A |
| textTertiary | #7E7562 |
| separator | #383227 |
| strongSeparator | #463E30 |
| accent | #8CBD9B |
| accentHover | #A5CFB2 |
| accentMuted | #2C3A2F |
| accentText | #161B15 |
| danger | #D08B80 |
| dangerMuted | #3C2823 |
| warning | #D9A84E |
| selectionWash | #332D23 |
| shadow | 0 18px 44px rgba(0,0,0,.5) + 0 3px 8px rgba(0,0,0,.3) |

Diff marks: removal = danger text on dangerMuted wash with line-through in danger; insertion = accent text (weight 500) on accentMuted wash. Both 3px corner radius, 1–2px horizontal padding.

### Typography (3 voices)
- **Newsreader (serif, weight 400–500)** — "the writing voice": panel titles, suggestion/diff text, page headings, empty-state asides (italic). Popover title 14.5px/500, suggestion text 15px/1.55–1.6, settings page title 26px/500, working aside 14px italic. macOS equivalent: `New York` (`.serif` design) is acceptable; Newsreader if bundled.
- **Nunito Sans (sans)** — "the interface voice": buttons/labels 11–13px weight 600–700, detail text 11px weight 400. macOS equivalent: SF Pro is acceptable if not bundling.
- **Fragment Mono** — "the machinery voice": shortcuts, section labels (9.5–11px, uppercase, .08–.12em tracking), timestamps, log/receipt lines, model names. macOS equivalent: SF Mono.

### Radii & spacing
- Popover panel 13px, cards/groups 11px, buttons 8px, small controls/pills 6–7px, fields 7–8px, app icon squircle ≈ 22.6% of size.
- Settings rows: min-height 48–52px, 16px horizontal card padding, hairline separators between rows (inset past the label column on Provider).
- Buttons: height 28px, padding 0 11–12px. Primary = accent bg + accentText; secondary = 1px strongSeparator border, transparent bg; quiet = borderless, hover raisedSurface; danger = danger text, hover dangerMuted wash. Shortcut hints inside buttons in mono 10px at 55–70% opacity.

### Motion rules
- **One duration: 180ms ease-out** for every content change; content rises 4px + fades (`pwRise`).
- Popover appear: 160ms scale .97 → 1 with -4px drop.
- Streaming text: last ~5 chars fade in behind a pulsing accent caret (▍, 1.1s pulse); when streaming finishes the same text stays in place and gains controls — never re-rendered.
- Processing: italic serif aside ("Reading it over…") with a 2px accent underline drawing itself left-to-right (1.3s loop).
- Apply: popover replaced by a small "✓ Applied" accent chip (1.9s), while a green wash sweeps word-by-word across the corrected field text (1.5s, 20ms stagger per word).
- Trigger chip: fades up 5px over 250ms, accent underline draws under the "p." over 500ms (250ms delay), full stop pulses twice. Pointer tab (12px triangle) merges seamlessly with the chip border.
- Reduce Motion: text appears whole, caret steady, panels cut.

## Screens / Views

### 1. Correction popover (`CorrectionPanelController.swift`)
352px wide floating panel: surface bg, 1px strongSeparator border, 13px radius, large soft shadow, pointer tab toward the text field. Header (42px): 20px brand icon, serif title, mono detail on the right (e.g. "3 fixes"), ✕ close. Footer (48px) above a hairline.
**States** (see Popover Simulator):
- **trigger** — small chip: serif "p." + self-drawing accent underline, pointer tab.
- **prompting** (Transform) — mono uppercase label "HOW SHOULD THIS TEXT CHANGE?", input field (fieldBackground, strongSeparator border; focus = accent border + 3px accentMuted ring), three quick-action ghost chips (Shorten / Friendlier / More formal). Footer: Cancel (esc) / Transform (↩, primary; disabled at 45% opacity when empty).
- **processing** — italic serif aside + drawing underline. Footer: mono "connecting…" left, Cancel right.
- **streaming** — mono label "SUGGESTED REVISION", serif text streaming with fading tail + caret. Footer: mono "writing…", Cancel.
- **ready** — mono label "PROPOSED EDIT" + Changes/Revised segmented control (Changes shows the inline diff, Revised shows clean text). Footer: context-receipt paperclip toggle (accentMuted bg when context attached; rotates -20° when open), Dismiss (esc), primary "Apply 3 fixes" / "Use suggestion" (⌘↩).
- **context receipt** — expands below on raisedSurface: switch "Attach context from Mail", then mono-labeled rows FIELD / DOCUMENT / NEARBY (rows at 45% opacity when the switch is off).
- **accepted** — panel closes → "✓ Applied" chip + field sweep (see motion).
- **unchanged** — italic serif "Looks good — nothing to change." Auto-dismisses ~2.2s.
- **failure** — danger message ("Couldn't reach your provider…"), footer Dismiss + primary Try again.

### 2. Settings window (860×600)
Sidebar 196px on raisedSurface: traffic lights, 32px icon + serif "Plainword"/"Writing assistant", nav items (General ⚙ / Provider ⌁ / Writing ✎ / Debug ⌗) — active = surface bg, subtle shadow, accent icon; mono version string bottom. Content pages (serif 26px title + secondary subtitle over a hairline, mono uppercase section labels, card groups):
- **General**: Suggestions card (toggle; ⌘F2 Review row; ⇧⌘F2 Transform row — shortcuts as mono keycaps on fieldBackground; Status row with Listening/Paused pill), Appearance segmented (Automatic/Light/Dark), Excluded apps card (app + mono bundle id, danger Remove, Add App…), Setup card (Provider/Accessibility with ✓ pills).
- **Provider** (mirrors `ProviderSettingsView.swift` exactly): provider picker (3 selectable cards: Ollama / Codex / OpenAI-compatible — selected = accentMuted bg + accent border + radio dot). Then per provider:
  - *Ollama*: Server row "localhost:11434" + "⌂ Local" pill; Model dropdown of installed models + reload button; "Loaded N local models." caption.
  - *Codex*: Account row (email, "ChatGPT Plus · via Codex CLI", recheck ⟳); Model dropdown ("Codex default", "Codex-Spark (Fastest)", …) + recommendation caption.
  - *OpenAI-compatible*: Endpoint field, Model field, Authentication dropdown (None/Bearer/Custom header), conditional Header field, conditional API key secure field; credential card below (pill: "No key saved" tertiary / "Unsaved changes" warning / "✓ Saved in Keychain" accent; Clear danger-quiet + Save primary).
  - Options: Thinking mode dropdown (no "Off" for Codex). Connection card: 32px status icon tile (⚡ idle / ⟳ testing / ✓ verified / △ failed on matching washes), title + detail line, Test Connection primary (disabled until canTest: endpoint+model+key as applicable). Any edit resets to idle.
- **Writing**: Tone (Neutral/Warm/Direct) and Style (Concise/Detailed/Playful) segmented rows; Additional instructions serif textarea.
- **Debug** (mirrors `LLMDebugSettingsView.swift`): header row "LLM CALLS" + All(n)/Failures(n) segmented + call count + quiet Clear; one-line privacy notice; call cards (status capsule "✓ HTTP 200"/"△ Failed", model bold, mono time, serif quoted subject preview, danger failure line, tertiary summary "Correct · Mail · TTFB 0.34 s · 1.42 s · 918 in · 64 out", chevron; hover = accent border). Card click opens **inspector sheet** (640px): header = status capsule + serif model + time + ✕; transport summary line; Request/Response panes (raisedSurface, title + char count + Copy→"✓ Copied", mono 10.5px wrapped scrolling payload, "Nothing was recorded for this section." when empty); footer Done (esc). Esc/backdrop closes.

### 3. Menu bar item
Template glyph: serif lowercase "p" with full stop, 15pt. Full stop = accent when idle, warning + pulse while a request is in flight, absent when paused ("p" tertiary). Dropdown menu keeps the paper card language: Suggestions toggle, Ignore <app>, Review text ⌘F2, Transform… ⇧⌘F2, Settings… ⌘,, Quit — mono shortcuts right-aligned.

### 4. Brand icon
Newsreader "p" (weight 500) + accent full stop on a paper gradient squircle (#FBF8F1→#F1EBDE, border #E3DCCB); dark variant on #2B261E→#191612 with #8CBD9B stop. `assets/pw-icon.png` (1032px) is included; `Brand Icon.dc.html` regenerates it at any size. Replaces the current red-violet gradient icon everywhere (app icon, popover header, settings sidebar).

## State Management
Popover phases: idle → trigger → prompting → processing → streaming → ready → accepted, with unchanged/failure endings (see the simulator's phase rail; jump targets map to existing controller states). Streaming must transition into ready without re-rendering the text. Esc dismisses in every phase; ⌘↩ applies in ready.

## Assets
- `assets/pw-icon.png` — new brand icon (light, 1032×1032)
- Fonts via Google Fonts: Newsreader, Nunito Sans, Fragment Mono (or the macOS system equivalents noted above)

## Files
- `Popover Simulator.dc.html` — popover, all states + transitions (interactive)
- `Settings.dc.html` — full settings window (interactive, incl. debug inspector sheet)
- `Design System.dc.html` — token/type/control/menu-bar reference sheet
- `Brand Icon.dc.html` — icon source
- `support.js` — prototype runtime (ignore)
