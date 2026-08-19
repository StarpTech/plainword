# Plainword landing page

Marketing one-pager for Plainword, built with Vite + React 18 + Tailwind CSS v4.

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
    Backdrop.jsx        # Ambient background glows
    Nav.jsx
    Hero.jsx            # Headline, CTA, floating popovers (>=1100px) + mobile strip
    HeroPopover.jsx     # Screenshot + caption pill
    Features.jsx        # Three feature cards + app chips
    VoiceSection.jsx    # "Make it sound like you" + settings screenshot
    Providers.jsx       # "Your AI. Your rules." provider list
    DownloadCta.jsx
    Footer.jsx
public/images/          # App icon + product screenshots
```

## Design tokens

Defined in `src/index.css` via Tailwind's `@theme` (taken from the macOS app's design system):
brand `#6256C4`, brand-strong `#5045A8`, brand-muted `#ECEAF8`, ink `#242428`,
ink-soft `#6F6F76`, ink-faint `#929299`, line `#E2E2E5`, canvas `#F7F7F8`,
plus lavender/sky ambient glow colors. Font: system SF Pro stack.

## Notes

- Set the real download and GitHub URLs in `src/content.js`.
- Provider logos for Ollama/Anthropic/Mistral load from cdn.simpleicons.org; the OpenAI mark is local (`public/images/openai.svg`, Bootstrap Icons, MIT).
```
