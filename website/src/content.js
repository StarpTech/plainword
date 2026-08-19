/** Central place for copy, links and data used across sections. */

export const DOWNLOAD_URL =
  'https://github.com/StarpTech/plainword/releases/download/v1.0.0-beta.2/Plainword-1.0.0-beta.2-unsigned.dmg';
export const GITHUB_URL = 'https://github.com/StarpTech/plainword';

export const HERO_POPOVERS = [
  {
    id: 'correction',
    src: '/images/popover-correction.png',
    alt: "Plainword small correction popover suggesting That's with an Apply fix button",
    caption: 'One-keystroke fixes',
  },
  {
    id: 'rewrite',
    src: '/images/popover-rewrite.png',
    alt: 'Plainword clarity suggestion showing a proposed edit with tracked changes',
    caption: 'Rewrites you approve first',
  },
  {
    id: 'transform',
    src: '/images/popover-transform.png',
    alt: 'Plainword transform popover where you type your own instruction',
    caption: 'Your own prompts',
  },
];

export const APP_CHIPS = ['macOS apps', 'Browser', 'WhatsApp', 'Slack', 'LinkedIn', 'and more'];

export const VOICE_ROWS = [
  { label: 'Tone', text: 'The emotional character of suggestions.' },
  { label: 'Style', text: 'How suggestions are phrased and structured.' },
  { label: 'Language', text: 'Works in any language — detected automatically.' },
  { label: 'Instructions', text: '\u201CPrefer British English and avoid semicolons.\u201D' },
];

export const PROVIDERS = [
  {
    name: 'Ollama — fully local',
    text: 'Your writing never leaves your Mac.',
    icons: [{ src: 'https://cdn.simpleicons.org/ollama/242428', alt: 'Ollama' }],
  },
  {
    name: 'Codex subscription',
    text: 'Reuse the subscription you already pay for.',
    icons: [{ src: '/images/openai.svg', alt: 'Codex (OpenAI)' }],
  },
  {
    name: 'Any compatible provider',
    text: 'Connect the OpenAI-compatible service you trust.',
    icons: [
      { src: 'https://cdn.simpleicons.org/anthropic/242428', alt: 'Anthropic', small: true },
      { src: 'https://cdn.simpleicons.org/mistralai/242428', alt: 'Mistral', small: true },
    ],
  },
];
