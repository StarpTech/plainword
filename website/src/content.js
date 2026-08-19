/** Central place for copy, links and data used across sections. */

export const DOWNLOAD_URL =
  'https://github.com/StarpTech/plainword/releases/download/v1.0.0-beta.5/Plainword-1.0.0-beta.5-unsigned.dmg';
export const GITHUB_URL = 'https://github.com/StarpTech/plainword';

export const HERO_POPOVERS = [
  {
    id: 'correction',
    src: '/images/popover-correction.png',
    alt: "Plainword small correction popover suggesting That's with an Apply fix button",
    caption: 'Small fixes, one keystroke',
  },
  {
    id: 'rewrite',
    src: '/images/popover-rewrite.png',
    alt: 'Plainword clarity suggestion showing a proposed edit with tracked changes',
    caption: 'Rewrites shown before applying',
  },
  {
    id: 'transform',
    src: '/images/popover-transform.png',
    alt: 'Plainword transform popover where you type your own instruction',
    caption: 'Or just tell it what to do',
  },
];

export const APP_CHIPS = ['macOS apps', 'Browser', 'WhatsApp', 'Slack', 'LinkedIn', 'and more'];

export const VOICE_ROWS = [
  { label: 'Tone', text: 'How warm, direct or formal a suggestion sounds.' },
  { label: 'Style', text: 'How it phrases and structures a sentence.' },
  { label: 'Language', text: 'Any language, detected from what you wrote.' },
  { label: 'Instructions', text: '\u201CBritish English, no semicolons, never start with \u2018I hope\u2019.\u201D' },
];

export const CONTEXT_NEVER = [
  'password fields',
  'other windows or apps',
  'anything before you press the shortcut',
];

export const PROVIDERS = [
  {
    name: 'Ollama, fully local',
    text: 'Nothing leaves your Mac. No account, no API key.',
    icons: [{ src: 'https://cdn.simpleicons.org/ollama/242428', alt: 'Ollama' }],
  },
  {
    name: 'Codex subscription',
    text: 'Reuses your Codex CLI login. No second bill.',
    icons: [{ src: '/images/openai.svg', alt: 'Codex (OpenAI)' }],
  },
  {
    name: 'Any compatible provider',
    text: 'Your own key, any OpenAI-compatible endpoint.',
    icons: [
      { src: 'https://cdn.simpleicons.org/anthropic/242428', alt: 'Anthropic', small: true },
      { src: 'https://cdn.simpleicons.org/mistralai/242428', alt: 'Mistral', small: true },
    ],
  },
];

/** The two models we point people at, one for each thing people optimise for. */
export const RECOMMENDED_MODELS = [
  {
    id: 'local',
    eyebrow: 'If nothing may leave the Mac',
    name: 'Gemma 4 E2B',
    via: 'Ollama',
    text: 'Google\u2019s smallest Gemma 4, open weights, running on your own hardware. It is good at phrasing, at conversational replies and at the language you wrote in, which is most of what a writing assistant is asked to do.',
    points: [
      'Under 0.5s to a suggestion on a MacBook Pro',
      'No account, no API key, works offline',
      'Free to run, 7.2GB to download',
    ],
    setup: 'ollama pull gemma4:e2b',
    mono: true,
    accent: true,
  },
  {
    id: 'hosted',
    eyebrow: 'If privacy is not the constraint',
    name: 'Gemini 2.5 Flash-Lite',
    via: 'Any OpenAI-compatible key',
    text: 'Clearly smarter than anything that fits on a laptop, and a full month of writing costs less than one Starbucks coffee. Your text goes to Google, so pick this for the writing you would not mind sending.',
    points: [
      'Better at long threads and awkward rewrites',
      'Around $0.10 per million input tokens',
      'Still fast enough to feel instant',
    ],
    setup: 'Paste your key under Models',
    mono: false,
    accent: false,
  },
];
