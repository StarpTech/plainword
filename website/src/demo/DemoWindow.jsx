/**
 * The host applications the demo types into: a Mail compose window, a Slack
 * channel and a browser on LinkedIn. They exist to make one point — Plainword
 * works in the field you are already in — so they are deliberately quiet:
 * paper surfaces, hairline borders, no logos, no chrome the eye has to parse.
 */

/** The field being edited: washed while Plainword is working, swept when applied. */
function FieldText({ scene, phase }) {
  if (phase === 'accepted') {
    const words = scene.result.split(' ');
    return (
      <span>
        {words.map((word, i) => (
          <span
            // eslint-disable-next-line react/no-array-index-key
            key={i}
            style={{ animation: `pwSweep 1.5s ease-out ${i * 0.02}s both`, borderRadius: '3px' }}
          >
            {word}
            {i < words.length - 1 ? ' ' : ''}
          </span>
        ))}
      </span>
    );
  }

  if (scene.field.empty) {
    return <span className="inline-block h-[1.1em] w-px translate-y-[3px] animate-pulse-caret bg-accent" />;
  }

  return (
    <span
      className={
        phase === 'idle' ? '' : 'rounded-[3px] bg-selection [box-decoration-break:clone]'
      }
    >
      {scene.field.text}
    </span>
  );
}

function TitleBar({ title, children }) {
  return (
    <div className="flex items-center gap-[7px] border-b border-line px-3.5 py-3">
      <span className="h-[11px] w-[11px] rounded-full bg-line-strong" />
      <span className="h-[11px] w-[11px] rounded-full bg-line-strong" />
      <span className="h-[11px] w-[11px] rounded-full bg-line-strong" />
      {children ?? (
        <>
          <span className="flex-1 text-center text-[12px] font-semibold text-ink-soft">
            {title}
          </span>
          <span className="w-[51px]" />
        </>
      )}
    </div>
  );
}

function Avatar({ initials }) {
  return (
    <span className="grid h-[30px] w-[30px] shrink-0 place-items-center rounded-[9px] bg-accent-muted text-[11px] font-bold text-accent">
      {initials}
    </span>
  );
}

function Message({ initials, name, time, text }) {
  return (
    <div className="flex gap-2.5">
      <Avatar initials={initials} />
      <div className="min-w-0">
        <div className="flex items-baseline gap-2">
          <span className="text-[12.5px] font-bold text-ink">{name}</span>
          <span className="font-mono text-[9.5px] text-ink-faint">{time}</span>
        </div>
        <div className="font-serif text-[14.5px] leading-[1.55] text-ink-soft">{text}</div>
      </div>
    </div>
  );
}

function MailWindow({ scene, phase, fieldRef }) {
  const { window: win } = scene;
  return (
    <>
      <TitleBar title={win.title} />
      <div className="flex flex-col gap-2 px-[22px] pt-3.5 pb-1.5 text-[12.5px] text-ink-soft">
        {win.rows.map(([label, value]) => (
          <div key={label} className="flex gap-2 border-b border-line pb-2">
            <span className="w-[52px] text-ink-faint">{label}</span>
            <span className="text-ink">{value}</span>
          </div>
        ))}
      </div>
      <div className="px-[22px] pt-[18px] font-serif text-[16.5px] leading-[1.65] text-ink">
        {win.before.map((line) => (
          <p key={line} className="mb-3.5">
            {line}
          </p>
        ))}
        <p ref={fieldRef} className="mb-3.5">
          <FieldText scene={scene} phase={phase} />
        </p>
        <p className="m-0">
          {win.after.map((line) => (
            <span key={line}>
              {line}
              <br />
            </span>
          ))}
        </p>
      </div>
    </>
  );
}

function SlackWindow({ scene, phase, fieldRef }) {
  const { window: win } = scene;
  return (
    <>
      <TitleBar title={win.title} />
      <div className="flex flex-col gap-4 px-[22px] pt-5 pb-4">
        {win.messages.map((message) => (
          <Message key={`${message.name}-${message.time}`} {...message} />
        ))}
      </div>
      <div className="mt-auto px-[22px] pb-[22px]">
        <div className="rounded-tile border border-line-strong bg-surface p-3 shadow-paper">
          <p
            ref={fieldRef}
            className="m-0 font-serif text-[14.5px] leading-[1.6] text-ink"
          >
            <FieldText scene={scene} phase={phase} />
          </p>
          <div className="mt-2.5 flex items-center gap-3 border-t border-line pt-2 text-[12px] text-ink-faint">
            <span>B</span>
            <span className="italic">I</span>
            <span className="line-through">S</span>
            <span className="flex-1" />
            <span className="grid h-[22px] w-[22px] place-items-center rounded-md bg-accent text-[10px] text-accent-ink">
              ➤
            </span>
          </div>
        </div>
      </div>
    </>
  );
}

function BrowserWindow({ scene, phase, fieldRef }) {
  const { window: win } = scene;
  return (
    <>
      <TitleBar>
        <span className="ml-2 rounded-t-[9px] border-t border-r border-l border-line bg-raised px-3 py-[7px] text-[11.5px] font-semibold text-ink">
          {win.title}
        </span>
        <span className="flex-1" />
      </TitleBar>
      <div className="border-b border-line px-3.5 py-2.5">
        <div className="flex items-center gap-2 rounded-full bg-field px-3 py-[6px]">
          <span className="text-[11px] leading-none text-accent">⌁</span>
          <span className="font-mono text-[11px] text-ink-soft">{win.url}</span>
        </div>
      </div>
      <div className="flex flex-col gap-4 px-[22px] pt-5 pb-4">
        {win.messages.map((message) => (
          <Message key={`${message.name}-${message.time}`} {...message} />
        ))}
      </div>
      <div className="mt-auto px-[22px] pb-[22px]">
        <div className="rounded-tile border border-line-strong bg-surface p-3 shadow-paper">
          <p ref={fieldRef} className="m-0 min-h-[23px] font-serif text-[14.5px] leading-[1.6] text-ink">
            <FieldText scene={scene} phase={phase} />
          </p>
          <div className="mt-2.5 flex items-center gap-3 border-t border-line pt-2 text-[12px] text-ink-faint">
            <span>Aa</span>
            <span>☺</span>
            <span className="flex-1" />
            <span className="rounded-full bg-accent px-3 py-[3px] text-[11px] font-bold text-accent-ink">
              Send
            </span>
          </div>
        </div>
      </div>
    </>
  );
}

const CHROME = { mail: MailWindow, slack: SlackWindow, browser: BrowserWindow };


export default function DemoWindow({ scene, phase, fieldRef, className = '', style }) {
  const Chrome = CHROME[scene.app];
  return (
    <div
      className={`flex flex-col overflow-hidden rounded-[12px] border border-line bg-surface shadow-float ${className}`}
      style={style}
    >
      <Chrome scene={scene} phase={phase} fieldRef={fieldRef} />
    </div>
  );
}

/** The bare field, for the narrow layout that drops the app chrome. */
DemoWindow.Field = FieldText;
