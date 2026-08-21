/** Central place for copy, links and data used across sections. */

export const DOWNLOAD_URL =
  'https://github.com/StarpTech/plainword/releases/download/v1.0.0-beta.6/Plainword-1.0.0-beta.6-unsigned.dmg';
export const GITHUB_URL = 'https://github.com/StarpTech/plainword';

export const APP_CHIPS = ['macOS apps', 'Browser', 'WhatsApp', 'Slack', 'LinkedIn', 'and more'];

export const VOICE_ROWS = [
  { label: 'Tone', text: 'Keep mine, friendly or professional.' },
  { label: 'Style', text: 'Keep mine, concise or detailed.' },
  { label: 'Language', text: 'Whatever you wrote in, or pin one.' },
  { label: 'Instructions', text: '\u201CBritish English, no semicolons.\u201D' },
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
    icons: [{ src: 'https://cdn.simpleicons.org/ollama/26211A', alt: 'Ollama' }],
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
      { src: 'https://cdn.simpleicons.org/anthropic/26211A', alt: 'Anthropic', small: true },
      { src: 'https://cdn.simpleicons.org/mistralai/26211A', alt: 'Mistral', small: true },
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
    text: 'Open weights, running on your own hardware. Good at phrasing, at replies, and at the language you wrote in, which is most of the job.',
    points: [
      'Under 0.5s to a suggestion',
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
    text: 'Smarter than anything that fits on a laptop, and a month of writing costs less than one coffee. Your text goes to Google.',
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
