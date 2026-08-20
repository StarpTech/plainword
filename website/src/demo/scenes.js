/**
 * The three flows the demo plays out, in the app's own vocabulary.
 *
 * Every label here is the string the shipped app actually shows
 * (CorrectionPanelController.swift): the header titles and details, the prompt
 * captions and placeholders, the section labels and the accept-button titles.
 * If a label changes in the app, change it here too rather than inventing a
 * marketing variant.
 */

/** Diff segments: ["u", text] unchanged, ["r", text] removed, ["i", text] inserted. */

export const SCENES = [
  {
    id: 'correct',
    tab: 'Correct',
    shortcut: ['⌘', 'F2'],
    kicker: 'Review text',
    blurb:
      'Marks every fix it would make, and changes nothing until you press Apply.',
    app: 'mail',
    pointer: 'top',
    flow: 'review',
    window: {
      title: 'Re: Q3 report — Mail',
      rows: [
        ['To:', 'Dana Whitfield'],
        ['Subject:', 'Re: Q3 report'],
      ],
      before: ['Hi Dana — thanks for the notes, I folded most of them in this afternoon.'],
      after: ['Best,', 'Sam'],
    },
    field: {
      text: 'I beleive the the report is finished, and I will send it tomorow morning.',
    },
    result: 'I believe the report is finished, and I will send it tomorrow morning.',
    segs: [
      ['u', 'I '],
      ['r', 'beleive'],
      ['i', 'believe'],
      ['u', ' '],
      ['r', 'the the'],
      ['i', 'the'],
      ['u', ' report is finished, and I will send it '],
      ['r', 'tomorow'],
      ['i', 'tomorrow'],
      ['u', ' morning.'],
    ],
    popover: {
      title: 'Small corrections',
      detail: '3 fixes',
      label: 'Proposed edit',
      accept: 'Apply 3 fixes',
      segmented: true,
    },
    defaultPreview: 'changes',
    showReceipt: true,
    receipt: {
      app: 'Mail',
      rows: [
        ['FIELD', 'Message body'],
        ['DOCUMENT', 'Re: Q3 report'],
        ['NEARBY', '2 earlier messages in thread'],
      ],
    },
  },

  {
    id: 'transform',
    tab: 'Transform',
    shortcut: ['⇧⌘', 'F2'],
    kicker: 'Transform…',
    blurb: 'Say what should change in your own words, or take one of the three shortcuts.',
    app: 'slack',
    pointer: 'bottom',
    flow: 'rewrite',
    window: {
      title: '#q3-launch — Acme',
      messages: [
        {
          initials: 'DW',
          name: 'Dana Whitfield',
          time: '14:02',
          text: 'Are we still good for the Wednesday deploy?',
        },
        {
          initials: 'MK',
          name: 'Milo Kranz',
          time: '14:06',
          text: 'Two reviews are still open on my side, so probably not.',
        },
        {
          initials: 'DW',
          name: 'Dana Whitfield',
          time: '14:07',
          text: 'Then someone should tell the channel before people start deploying.',
        },
      ],
      composer: 'Message #q3-launch',
    },
    field: {
      text: 'Per my previous message, the deployment window has been moved to Thursday and all outstanding review comments must be resolved prior to that date.',
    },
    prompt: 'friendlier, and half as long',
    result:
      'Heads up — the deploy moved to Thursday. Could you clear your open review comments before then?',
    segs: [
      [
        'r',
        'Per my previous message, the deployment window has been moved to',
      ],
      ['i', 'Heads up — the deploy moved to'],
      ['u', ' Thursday'],
      ['r', ' and all outstanding review comments must be resolved prior to that date.'],
      ['i', '. Could you clear your open review comments before then?'],
    ],
    prompting: {
      title: 'Transform entire field',
      caption: 'How should this text change?',
      placeholder: 'Make it shorter, friendlier, translate it…',
      submit: 'Transform',
      chips: ['Shorten', 'Friendlier', 'More formal'],
    },
    popover: {
      title: 'Clarity suggestion',
      detail: '1 rewrite',
      label: 'Proposed edit',
      accept: 'Use suggestion',
      segmented: true,
    },
    defaultPreview: 'revised',
    receipt: {
      app: 'Slack',
      rows: [
        ['FIELD', 'Message #q3-launch'],
        ['DOCUMENT', '#q3-launch'],
        ['NEARBY', '2 earlier messages in channel'],
      ],
    },
  },

  {
    id: 'write',
    tab: 'Write',
    shortcut: ['⇧⌘', 'F2'],
    kicker: 'Write something',
    blurb:
      'An empty field has nothing to correct, so it writes the reply — from your one-line note and the message above.',
    app: 'browser',
    pointer: 'bottom',
    flow: 'compose',
    window: {
      title: 'Messaging — LinkedIn',
      url: 'linkedin.com/messaging',
      messages: [
        {
          initials: 'RS',
          name: 'Rina Solá',
          time: 'Mon',
          text: 'Hi Sam — I came across Plainword last week and read the whole accessibility write-up. Lovely work.',
        },
        {
          initials: 'RS',
          name: 'Rina Solá',
          time: 'Tue',
          text: 'We’re hiring a staff engineer for our platform team and I think you’d fit it well. Any interest in a short call this week?',
        },
      ],
      composer: 'Write a message…',
    },
    field: { text: '', empty: true },
    prompt: 'thanks, happy where I am, stay in touch',
    result:
      'Thank you, Rina — that’s kind of you to say. I’m happy where I am right now, so I’ll pass on the call, but I’d be glad to stay in touch in case that changes.',
    prompting: {
      title: 'Write something',
      caption: 'What should Plainword write?',
      placeholder: 'A reply saying I am running late…',
      submit: 'Write',
      chips: null,
    },
    popover: {
      title: 'Draft',
      detail: 'New text',
      label: 'New text',
      accept: 'Insert',
      segmented: false,
    },
    defaultPreview: 'revised',
    receipt: {
      app: 'Chrome',
      rows: [
        ['FIELD', 'Write a message'],
        ['DOCUMENT', 'Messaging — LinkedIn'],
        ['NEARBY', "Rina Solá's message"],
      ],
    },
  },
];
