import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { VoiceMode } from '../types'

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

const MODES: { value: VoiceMode; label: string; hint: string }[] = [
  { value: 'off', label: 'Off', hint: 'Normal written replies, nothing is read aloud.' },
  { value: 'auto', label: 'Auto', hint: 'AirPods as output: read at once. Otherwise: chime, wait for Play.' },
  { value: 'now', label: 'Now', hint: 'Every reply is read aloud as soon as it lands.' },
  { value: 'ask', label: 'On demand', hint: 'A chime when a reply lands; it waits in the queue until Play.' },
]

const isVoiceMode = (value: unknown): value is VoiceMode => MODES.some(one => one.value === value)

// The voice skill is the one source of the rules; the switch sends its body along each prompt.
async function loadVoiceRules(root: string, readFile: (path: string) => Promise<string>): Promise<string> {
  const skill = await readFile(`${root}/skills/voice/SKILL.md`)
  const body = skill.replace(/^---[\s\S]*?---\s*/, '')
  return body.slice(body.indexOf('The user mostly listens'))
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
    voiceRules = await loadVoiceRules($.plugin.root, path => $.fs.read(path)).catch(() => '')
    await $.command.register({ name: 'voice-panel', description: 'Open the earshot voice pane' })
    void $.ui.open({ id: PANE, title: 'Voice' })
    $.clock.every(QUEUE_POLL_MS, () => {
      void $.process.run(['/bin/sh', '-c', 'ls /tmp/earshot.queue 2>/dev/null | wc -l']).then(ran => {
        const count = Number.parseInt(ran.stdout.trim(), 10) || 0
        void update($, queued, previous => (previous === count ? previous : count))
      })
      void $.process.run(['/usr/bin/pgrep', '-x', 'earshot-remote']).then(ran => {
        const isRunning = ran.exitCode === 0
        void update($, isRemoteRunning, previous => (previous === isRunning ? previous : isRunning))
      })
    })

    return next(e)
  })

  on('command.run', { command: 'voice-panel' }, async $ => {
    await $.ui.open({ id: PANE, title: 'Voice' })

    return { text: 'Voice pane opened.' }
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

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const current = await read($, mode)
    const count = await read($, queued)
    const dictatedOnly = await read($, isDictatedOnly)
    const hasRemote = await read($, isRemoteRunning)
    const handleDictatedOnly = (value: boolean) => {
      void update($, isDictatedOnly, () => value)
      void $.store.set(DICTATED_ONLY_STORE_KEY, value)
    }
    const handleSelect = (value: VoiceMode) => {
      void update($, mode, () => value)
      void $.store.set(STORE_KEY, value)
      void $.process.run([`${$.plugin.root}/scripts/set-mode.sh`, value])
    }
    const handlePlay = () => void $.process.run([`${$.plugin.root}/scripts/player.sh`, '--one'])

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
          <Text>{count === 0 ? 'Empty.' : `${count} waiting.`}</Text>
          {count > 0 && (
            <Button key="play-next" onPress={handlePlay}>
              ▶ Play next
            </Button>
          )}
        </Box>

        <Text> </Text>
        <Text bold>Shortcuts</Text>
        <Text>
          <Text color="cyan">⇧ ⇧</Text> <Text dimColor>left Shift twice, any app: play the next queued reply</Text>
        </Text>
        <Text>
          <Text color="cyan">Esc</Text> <Text dimColor>any app, while speaking: stop and drop the queue</Text>
        </Text>
        <Text>
          <Text color="cyan">AirPods</Text> <Text dimColor>click while speaking: stop · double click: dictate</Text>
        </Text>

        <Text> </Text>
        <Text bold>How it behaves</Text>
        <Text dimColor>· Every new reply chimes, then is read now or waits, by mode.</Text>
        <Text dimColor>· The session you last talked to, with Claude in front, is always read at once.</Text>
        <Text dimColor>· Replies from several sessions queue up, one after another.</Text>
        <Text dimColor>· Before a reply from another session it says its title.</Text>
        <Text dimColor>· Dictation is told by the mic being in use with Claude in front, up to 30 s before sending.</Text>
        <Text dimColor>· The mode is shared by all your sessions. /voice-panel reopens this pane.</Text>
      </Box>
    )
  })
}
