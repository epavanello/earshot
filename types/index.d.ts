declare module 'claude-code' {
  interface PluginState {
    earshot: { isVoiceOn: boolean }
  }
}

export type VoiceMode = boolean
