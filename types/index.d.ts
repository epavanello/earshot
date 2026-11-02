export type VoiceMode = 'off' | 'auto' | 'now' | 'ask'

declare module 'claude-code' {
  interface PluginState {
    earshot: {
      mode: Shaped<VoiceMode>
      queued: Shaped<number>
      isDictatedOnly: Shaped<boolean>
      isRemoteRunning: Shaped<boolean>
    }
  }
}
