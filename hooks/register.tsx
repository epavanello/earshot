import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { History, SpeechLine, SpeechProgress, SpeechWord, VoiceMode } from '../types'

const PANE = 'earshot-voice'
const STORE_KEY = 'mode'
const DICTATED_ONLY_STORE_KEY = 'isDictatedOnly'
// Before 0.5 the switch was a boolean under this key.
const LEGACY_STORE_KEY = 'isVoiceOn'
const QUEUE_POLL_MS = 2000
const ACTIVE_SESSION_FILE = '/tmp/earshot.active-session'
const mode = atom({ plugin: 'earshot', key: 'mode' } as const, 'off', { shape: 'mode-1' })
const isDictatedOnly = atom({ plugin: 'earshot', key: 'isDictatedOnly' } as const, false, { shape: 'dictated-1' })
const isRemoteRunning = atom({ plugin: 'earshot', key: 'isRemoteRunning' } as const, false, { shape: 'remote-1' })
const queued = atom({ plugin: 'earshot', key: 'queued' } as const, 0, { shape: 'queued-1' })
const queuedHere = atom({ plugin: 'earshot', key: 'queuedHere' } as const, 0, { shape: 'queued-here-1' })
const EMPTY_HISTORY: History = { total: 0, items: [] }
const history = atom({ plugin: 'earshot', key: 'history' } as const, EMPTY_HISTORY, { shape: 'history-1' })
const HISTORY_PAGE = 5
// The inline player: earshot's speaker writes where it is, word by word; the transcript follows it.
const PROGRESS_FILE = '/tmp/earshot.progress'
const PROGRESS_POLL_MS = 120
// Two values, so a new word redraws only the box being read, and nothing redraws while nothing changes.
const IDLE_LINE: SpeechLine = { text: '', state: 'idle' }
const NO_WORD: SpeechWord = { start: 0, length: 0 }
const line = atom({ plugin: 'earshot', key: 'line' } as const, IDLE_LINE, { shape: 'line-1' })
const word = atom({ plugin: 'earshot', key: 'word' } as const, NO_WORD, { shape: 'word-1' })
// Reading speed, a multiplier of the base rate; kept across sessions and in a file the player reads.
const SPEEDS = [0.75, 1, 1.25, 1.5, 1.75, 2]
const SPEED_STORE_KEY = 'speed'
const SPEED_FILE = '.config/earshot/speed'
const speed = atom({ plugin: 'earshot', key: 'speed' } as const, 1, { shape: 'speed-1' })
// A word of the spoken line is a link to its offset; the press is the plugin's, nothing opens.
const WORD_LINK = 'https://earshot.invalid/word/'
const historyLimit = atom({ plugin: 'earshot', key: 'historyLimit' } as const, HISTORY_PAGE, { shape: 'history-limit-1' })

const MODES: { value: VoiceMode; label: string; hint: string }[] = [
  { value: 'off', label: 'Off', hint: 'Normal written replies, nothing is read aloud.' },
  { value: 'auto', label: 'Auto', hint: 'AirPods as output: read at once. Otherwise: chime, wait for Play.' },
  { value: 'now', label: 'Now', hint: 'Every reply is read aloud as soon as it lands.' },
  { value: 'ask', label: 'On demand', hint: 'A chime when a reply lands; it waits in the queue until Play.' },
]

const LAST_ON_STORE_KEY = 'lastOnMode'

const isVoiceMode = (value: unknown): value is VoiceMode => MODES.some(one => one.value === value)

// The voice skill is the one source of the rules; the switch sends its body along each prompt.
async function loadVoiceRules(root: string, readFile: (path: string) => Promise<string>): Promise<string> {
  const skill = await readFile(`${root}/skills/voice/SKILL.md`)
  const body = skill.replace(/^---[\s\S]*?---\s*/, '')
  return body.slice(body.indexOf('The user mostly listens'))
}

// One place for the pane and the commands: atom for the pane, store across sessions, file for the scripts.
async function setMode($: EngineInterface, value: VoiceMode): Promise<void> {
  await update($, mode, () => value)
  await $.store.set(STORE_KEY, value)
  if (value !== 'off') await $.store.set(LAST_ON_STORE_KEY, value)
  await $.process.run([`${$.plugin.root}/scripts/set-mode.sh`, value])
}

const isHistory = (value: unknown): value is History =>
  typeof value === 'object' && value !== null && Array.isArray((value as History).items)

// This session's spoken lines, newest first, as many as the pane shows.
async function refreshHistory($: EngineInterface): Promise<void> {
  const sessionId = await $.session.id()
  const limit = await read($, historyLimit)
  const ran = await $.process.run([`${$.plugin.root}/scripts/history.sh`, sessionId, String(limit)])
  let next: unknown
  try {
    next = JSON.parse(ran.stdout)
  } catch {
    return
  }
  if (!isHistory(next)) return
  const fresh = next
  await update($, history, previous => (JSON.stringify(previous) === JSON.stringify(fresh) ? previous : fresh))
}

const isProgress = (value: unknown): value is SpeechProgress =>
  typeof value === 'object' &&
  value !== null &&
  typeof (value as SpeechProgress).text === 'string' &&
  typeof (value as SpeechProgress).start === 'number'

// The reply's spoken line, as the skill writes it (`⁣*text*`, last one wins), and the rest of the reply.
const SPOKEN_LINE = /^\s*\u2063[*_]*\s*(.+?)\s*[*_]*\s*$/gm
// As speak.sh: emoji, with their joiners and marks, are dropped; whitespace collapsed.
const EMOJI = /[\u{1F000}-\u{1FAFF}\u2600-\u27BF\u2B00-\u2BFF\u2300-\u23FF\u{E0020}-\u{E007F}\u200D\uFE0E\uFE0F\u20E3]+/gu
const speakable = (text: string) => text.replace(EMOJI, ' ').replace(/\s+/g, ' ').trim()

function splitSpoken(text: string): { rest: string; spoken: string } | undefined {
  const found = [...text.matchAll(SPOKEN_LINE)].at(-1)
  if (!found || found.index === undefined) return undefined
  const rest = (text.slice(0, found.index) + text.slice(found.index + found[0].length)).trim()

  return { rest, spoken: speakable(found[1] ?? '') }
}

// The line's words with their UTF-16 offsets, spaces kept, so the speaker's word range finds its word.
function tokenize(text: string): { word: string; start: number; end: number }[] {
  const tokens: { word: string; start: number; end: number }[] = []
  for (const match of text.matchAll(/\S+|\s+/g)) {
    const start = match.index ?? 0
    tokens.push({ word: match[0], start, end: start + match[0].length })
  }

  return tokens
}

// Writes only what changed: a write redraws its readers, even with the same value.
async function pollProgress($: EngineInterface): Promise<void> {
  let found: SpeechProgress | undefined
  try {
    const parsed: unknown = JSON.parse(await $.fs.read(PROGRESS_FILE))
    if (isProgress(parsed)) found = parsed
  } catch {
    // No file yet: nothing has been read.
  }
  const nextLine: SpeechLine = found ? { text: found.text, state: found.state } : IDLE_LINE
  const nextWord: SpeechWord = found ? { start: found.start, length: found.length } : NO_WORD
  const previousLine = await read($, line)
  if (previousLine.text !== nextLine.text || previousLine.state !== nextLine.state) {
    await update($, line, () => nextLine)
  }
  const previousWord = await read($, word)
  if (previousWord.start !== nextWord.start || previousWord.length !== nextWord.length) {
    await update($, word, () => nextWord)
  }
}

const escapeMarkdown = (text: string) => text.replace(/[\\`*_[\]()<>#|~]/g, '\\$&')

async function setSpeed($: EngineInterface, value: number): Promise<void> {
  await update($, speed, () => value)
  await $.store.set(SPEED_STORE_KEY, value)
  await $.process.run(['/bin/sh', '-c', 'mkdir -p "$HOME/.config/earshot" && printf %s "$1" > "$HOME/$2"', 'sh', String(value), SPEED_FILE])
}

const formatTime = (at: number) => {
  const date = new Date(at * 1000)
  const pad = (one: number) => String(one).padStart(2, '0')
  return `${pad(date.getHours())}:${pad(date.getMinutes())}`
}

export const register: Register = on => {
  let voiceRules = ''

  on('session.start', async ($, e, next) => {
    // The mode is remembered across sessions; the scripts read it from ~/.config/earshot/mode.
    const stored = await $.store.get(STORE_KEY)
    const legacy = await $.store.get(LEGACY_STORE_KEY)
    const initial: VoiceMode = isVoiceMode(stored) ? stored : legacy === true ? 'auto' : 'off'
    await update($, mode, () => initial)
    const dictatedOnly = (await $.store.get(DICTATED_ONLY_STORE_KEY)) === true
    await update($, isDictatedOnly, () => dictatedOnly)
    await $.process.run([`${$.plugin.root}/scripts/set-mode.sh`, initial])
    void $.process.run([`${$.plugin.root}/scripts/hotkeys.sh`])
    const storedSpeed = await $.store.get(SPEED_STORE_KEY)
    await setSpeed($, typeof storedSpeed === 'number' && SPEEDS.includes(storedSpeed) ? storedSpeed : 1)
    // Builds the speaker now (a few seconds, once) rather than at the first reply.
    void $.process.run([`${$.plugin.root}/speaker/build.sh`])
    voiceRules = await loadVoiceRules($.plugin.root, path => $.fs.read(path)).catch(() => '')
    await $.command.register({ name: 'voice-panel', description: 'Open the earshot voice pane' })
    await $.command.register({ name: 'voice-on', description: 'Turn earshot voice on (last mode, Now by default)' })
    await $.command.register({ name: 'voice-off', description: 'Turn earshot voice off' })
    const sessionId = await $.session.id()
    void refreshHistory($)
    $.clock.every(QUEUE_POLL_MS, () => {
      // Two counts: every session's queue, and the lines of this session in it.
      const countScript = 'ls /tmp/earshot.queue 2>/dev/null | wc -l; ls /tmp/earshot.queue 2>/dev/null | grep -cF -- "-$1.txt"'
      void $.process.run(['/bin/sh', '-c', countScript, 'sh', sessionId]).then(ran => {
        const [all = 0, here = 0] = ran.stdout.trim().split(/\s+/).map(one => Number.parseInt(one, 10) || 0)
        void update($, queued, previous => (previous === all ? previous : all))
        void update($, queuedHere, previous => (previous === here ? previous : here))
      })
      void refreshHistory($)
      void $.process.run(['/usr/bin/pgrep', '-x', 'earshot-remote']).then(ran => {
        const isRunning = ran.exitCode === 0
        void update($, isRemoteRunning, previous => (previous === isRunning ? previous : isRunning))
      })
    })

    $.clock.every(PROGRESS_POLL_MS, () => void pollProgress($))

    return next(e)
  })

  on('command.run', { command: 'voice-panel' }, async $ => {
    await $.ui.open({ id: PANE, title: 'Voice' })

    return { text: 'Voice pane opened.' }
  })

  // Switch voice without the pane: /voice-on brings back the last mode that wasn't Off.
  on('command.run', { command: 'voice-on' }, async $ => {
    const last = await $.store.get(LAST_ON_STORE_KEY)
    const value: VoiceMode = isVoiceMode(last) && last !== 'off' ? last : 'now'
    await setMode($, value)

    return { text: `Voice on (${MODES.find(one => one.value === value)?.label}).` }
  })

  on('command.run', { command: 'voice-off' }, async $ => {
    await setMode($, 'off')

    return { text: 'Voice off.' }
  })

  // Rules ride along each prompt as hidden context (a prompt.compose section can be passed over by
  // plugins seated above). Switched off, the next prompt says so once, since earlier turns had them.
  let hasSentRules = false
  on('prompt.submit', async ($, e, next) => {
    // The session you last wrote or spoke to is the one you are on: speak.sh reads its reply at once.
    const sessionId = await $.session.id()
    await $.process.run(['/bin/sh', '-c', 'printf %s "$1" > "$2"', 'sh', sessionId, ACTIVE_SESSION_FILE])
    const context = [...(e.context ?? [])]
    const isOn = voiceRules !== '' && (await read($, mode)) !== 'off'
    const isWanted =
      isOn &&
      (!(await read($, isDictatedOnly)) ||
        (await $.process.run([`${$.plugin.root}/scripts/was-dictated.sh`])).stdout.trim() === 'yes')
    if (isWanted) {
      context.push(`# Voice mode (on)\n${voiceRules}`)
      hasSentRules = true
    } else if (hasSentRules) {
      context.push('Voice mode is now off: write normal replies, with no spoken line.')
      hasSentRules = false
    }

    return next({ ...e, context })
  })

  // A reply with a spoken line: the line becomes an inline player under the rest of the reply, with
  // Play / Pause / Stop, a speed picker and the word being spoken in bold while earshot reads it. Each
  // word is a link: a click reads from that word on.
  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    const parts = splitSpoken(e.props.text)
    if (!parts || !parts.spoken) return next(e)
    const spoken = parts.spoken
    const { Box, Text, Button, Select, Markdown } = $.ui.resolve(e)
    const playing = await read($, line)
    const currentSpeed = await read($, speed)
    const sessionId = await $.session.id()
    const isThis = playing.text === spoken && (playing.state === 'speaking' || playing.state === 'paused')
    const isPaused = isThis && playing.state === 'paused'
    // Only the box being read follows the words.
    const now = isThis ? await read($, word) : NO_WORD
    const playFrom = (offset?: number) =>
      void $.process.run([
        `${$.plugin.root}/scripts/replay.sh`,
        sessionId,
        '--text',
        spoken,
        ...(offset ? [String(offset)] : []),
      ])
    const handlePause = () => void $.process.run([`${$.plugin.root}/scripts/pause.sh`])
    const handleStop = () => void $.process.run([`${$.plugin.root}/scripts/stop.sh`])
    const handleWord = (href: string) => {
      const offset = Number.parseInt(href.slice(WORD_LINK.length), 10)
      if (Number.isFinite(offset)) playFrom(offset)
    }
    // A new speed holds for every later line; the line being read goes on from its word at that speed.
    const handleSpeed = (value: string) => {
      const picked = Number.parseFloat(value)
      if (!Number.isFinite(picked)) return
      void setSpeed($, picked).then(async () => {
        if (!isThis) return
        const current = await read($, word)
        playFrom(current.start)
      })
    }
    const words = tokenize(spoken)
      .map(token => {
        if (/^\s+$/.test(token.word)) return token.word
        const isCurrent = isThis && now.length > 0 && token.start <= now.start && now.start < token.end
        const label = escapeMarkdown(token.word)

        return `[${isCurrent ? `**${label}**` : label}](${WORD_LINK}${token.start})`
      })
      .join('')
    const above = parts.rest ? await next({ ...e, props: { ...e.props, text: parts.rest } }) : undefined
    const id = `earshot-${spoken.length}-${spoken.slice(0, 24)}`

    return (
      <Box flexDirection="column" gap={1}>
        {above}
        <Box flexDirection="column" borderStyle="round" borderColor={isThis ? 'cyan' : 'gray'} paddingX={1} gap={1}>
          <Box flexDirection="row" gap={1} alignItems="center">
            {isThis ? (
              <Button key={`${id}-pause`} variant="primary" onPress={handlePause}>
                {isPaused ? '▶ Resume' : '❚❚ Pause'}
              </Button>
            ) : (
              <Button key={`${id}-play`} variant="secondary" onPress={() => playFrom()}>
                ▶ Play
              </Button>
            )}
            {isThis && (
              <Button key={`${id}-stop`} variant="secondary" onPress={handleStop}>
                ■ Stop
              </Button>
            )}
            <Select
              // Keyed by the speed: a change made in another box shows here too, as a new control.
              key={`${id}-speed-${currentSpeed}`}
              label="Speed"
              value={String(currentSpeed)}
              options={SPEEDS.map(one => ({ value: String(one), label: `${one}×` }))}
              onSelect={handleSpeed}
            />
            {isThis && <Text dimColor>{isPaused ? 'Paused' : 'Speaking…'}</Text>}
          </Box>
          <Markdown key={`${id}-words`} text={`*${words}*`} onLinkPress={link => handleWord(link.href)} />
        </Box>
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const current = await read($, mode)
    const count = await read($, queued)
    const countHere = await read($, queuedHere)
    const spoken = await read($, history)
    const sessionId = await $.session.id()
    const dictatedOnly = await read($, isDictatedOnly)
    const hasRemote = await read($, isRemoteRunning)
    const handleDictatedOnly = (value: boolean) => {
      void update($, isDictatedOnly, () => value)
      void $.store.set(DICTATED_ONLY_STORE_KEY, value)
    }
    const handleSelect = (value: VoiceMode) => void setMode($, value)
    const handlePlay = () => void $.process.run([`${$.plugin.root}/scripts/player.sh`, '--one', sessionId])
    const handleReplay = (id: string) => void $.process.run([`${$.plugin.root}/scripts/replay.sh`, sessionId, id])
    const handleMore = () => {
      void update($, historyLimit, previous => previous + HISTORY_PAGE).then(() => refreshHistory($))
    }
    const handleLess = () => {
      void update($, historyLimit, () => HISTORY_PAGE).then(() => refreshHistory($))
    }

    return (
      <Box flexDirection="column">
        <Text bold>Mode</Text>
        <Box flexDirection="row" gap={1}>
          {MODES.map(one => (
            <Button
              key={`mode-${one.value}`}
              variant={one.value === current ? 'primary' : 'secondary'}
              onPress={() => handleSelect(one.value)}
            >
              {one.label}
            </Button>
          ))}
        </Box>
        <Text dimColor>{MODES.find(one => one.value === current)?.hint}</Text>

        <Text> </Text>
        <Text bold>Reply by voice</Text>
        <Box flexDirection="row" gap={1}>
          <Button key="reply-always" variant={dictatedOnly ? 'secondary' : 'primary'} onPress={() => handleDictatedOnly(false)}>
            Always
          </Button>
          <Button key="reply-dictated" variant={dictatedOnly ? 'primary' : 'secondary'} onPress={() => handleDictatedOnly(true)}>
            Only when dictated
          </Button>
        </Box>
        <Text dimColor>
          {dictatedOnly
            ? 'A typed prompt gets a written reply; a dictated one (AirPods, Cmd+D, mic button) a spoken one.'
            : 'Every reply has a spoken line, typed or dictated.'}
        </Text>
        {dictatedOnly && !hasRemote && (
          <Text color="yellow">The AirPods remote is not running: it is what notices dictation (airpods/install.sh).</Text>
        )}
        {!voiceRules && <Text color="red">Voice rules not found (skills/voice/SKILL.md).</Text>}

        <Text> </Text>
        <Text bold>Queue</Text>
        <Box flexDirection="row" gap={1}>
          <Text>
            {countHere === 0 ? 'Nothing waiting from this session' : `${countHere} waiting from this session`}
            {count > countHere ? ` · ${count - countHere} from others.` : '.'}
          </Text>
          {countHere > 0 && (
            <Button key="play-next" onPress={handlePlay}>
              ▶ Play next
            </Button>
          )}
        </Box>

        <Text> </Text>
        <Text bold>Spoken in this session</Text>
        {spoken.items.length === 0 && <Text dimColor>Nothing yet.</Text>}
        {spoken.items.map(item => (
          <Box key={`spoken-${item.id}`} flexDirection="row" gap={1}>
            <Button key={`replay-${item.id}`} variant="secondary" onPress={() => handleReplay(item.id)}>
              ▶
            </Button>
            <Box flexDirection="column" flexShrink={1}>
              <Text dimColor>{formatTime(item.at)}</Text>
              <Text>{item.text}</Text>
            </Box>
          </Box>
        ))}
        {(spoken.total > spoken.items.length || spoken.items.length > HISTORY_PAGE) && (
          <Box flexDirection="row" gap={1}>
            {spoken.total > spoken.items.length && (
              <Button key="history-more" variant="secondary" onPress={handleMore}>
                Show {Math.min(HISTORY_PAGE, spoken.total - spoken.items.length)} more
              </Button>
            )}
            {spoken.items.length > HISTORY_PAGE && (
              <Button key="history-less" variant="secondary" onPress={handleLess}>
                Show less
              </Button>
            )}
            <Text dimColor>
              {spoken.items.length} of {spoken.total}
            </Text>
          </Box>
        )}

        <Text> </Text>
        <Text bold>Shortcuts</Text>
        <Text>
          <Text color="cyan">⇧ ⇧</Text> <Text dimColor>left Shift twice, any app: play the next reply of the session in view, else any; again while speaking: skip to the next</Text>
        </Text>
        <Text>
          <Text color="cyan">Esc</Text> <Text dimColor>any app, while speaking: drop this line, keep the queue (a chime if more is waiting)</Text>
        </Text>
        <Text>
          <Text color="cyan">AirPods</Text> <Text dimColor>click while speaking: drop this line · double click: dictate</Text>
        </Text>

        <Text> </Text>
        <Text bold>How it behaves</Text>
        <Text dimColor>· Every new reply chimes, then is read now or waits, by mode.</Text>
        <Text dimColor>· The session open in Claude Desktop, with Claude in front, is always read at once.</Text>
        <Text dimColor>· Replies from several sessions queue up, one after another.</Text>
        <Text dimColor>· Before a reply it says its session's title, unless that session is the one open.</Text>
        <Text dimColor>· Dictation is told by the mic being in use with Claude in front, up to 30 s before sending.</Text>
        <Text dimColor>· The mode is shared by all your sessions. /voice-panel opens this pane; /voice-on and /voice-off switch without it.</Text>
      </Box>
    )
  })
}
