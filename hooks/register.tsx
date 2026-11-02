import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

const PANE = 'earshot-voice'
const STORE_KEY = 'isVoiceOn'
const isVoiceOn = atom({ plugin: 'earshot', key: 'isVoiceOn' } as const, false)

// The voice skill is the one source of the rules; the switch sends its body along each prompt.
async function loadVoiceRules(root: string, readFile: (path: string) => Promise<string>): Promise<string> {
  const skill = await readFile(`${root}/skills/voice/SKILL.md`)
  const body = skill.replace(/^---[\s\S]*?---\s*/, '')
  return body.slice(body.indexOf('The user mostly listens'))
}

export const register: Register = on => {
  let voiceRules = ''

  on('session.start', async ($, e, next) => {
    // The switch is remembered across sessions.
    const isOn = (await $.store.get(STORE_KEY)) === true
    await update($, isVoiceOn, () => isOn)
    voiceRules = await loadVoiceRules($.plugin.root, path => $.fs.read(path)).catch(() => '')
    await $.command.register({ name: 'voice-panel', description: 'Open the voice mode switch' })
    void $.ui.open({ id: PANE, title: 'Voice' })

    return next(e)
  })

  on('command.run', { command: 'voice-panel' }, async $ => {
    await $.ui.open({ id: PANE, title: 'Voice' })

    return { text: 'Voice panel opened.' }
  })

  // Rules ride along each prompt as hidden context (a prompt.compose section can be passed over by
  // plugins seated above). Switched off, the next prompt says so once, since earlier turns had them.
  let hasSentRules = false
  on('prompt.submit', async ($, e, next) => {
    const context = [...(e.context ?? [])]
    if (voiceRules && (await read($, isVoiceOn))) {
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
    const isOn = await read($, isVoiceOn)
    const handleToggle = () => {
      const isNext = !isOn
      void update($, isVoiceOn, () => isNext)
      void $.store.set(STORE_KEY, isNext)
    }

    return (
      <Box flexDirection="column">
        <Text>Short spoken replies</Text>
        <Button key="voice-toggle" variant={isOn ? 'primary' : 'secondary'} onPress={handleToggle}>
          {isOn ? 'On' : 'Off'}
        </Button>
        <Text dimColor>
          {!voiceRules
            ? 'Voice rules not found (skills/voice/SKILL.md).'
            : isOn
              ? 'Claude ends each reply with a line read aloud.'
              : 'Normal written replies.'}
        </Text>
      </Box>
    )
  })
}
