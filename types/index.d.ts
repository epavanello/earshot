export type VoiceMode = 'off' | 'auto' | 'now' | 'ask'

/** One spoken line of this session, newest first in the pane. `id` is its history file name. */
export type HistoryItem = { id: string; at: number; text: string }

export type History = { total: number; items: HistoryItem[] }

/** What earshot's speaker is reading (speaker/main.swift's progress file): the word is `start`/`length`, UTF-16. */
export type SpeechState = 'idle' | 'speaking' | 'paused' | 'done'
export type SpeechProgress = { text: string; start: number; length: number; state: SpeechState; at: number }
/** The line being read and whether it is paused: changes per line, so every box can read it. */
export type SpeechLine = { text: string; state: SpeechState }
/** The word being read: changes per word, read only by the box of the line being read. */
export type SpeechWord = { start: number; length: number }

declare module 'claude-code' {
  interface PluginState {
    earshot: {
      mode: Shaped<VoiceMode>
      queued: Shaped<number>
      queuedHere: Shaped<number>
      history: Shaped<History>
      historyLimit: Shaped<number>
      isDictatedOnly: Shaped<boolean>
      isRemoteRunning: Shaped<boolean>
      line: Shaped<SpeechLine>
      word: Shaped<SpeechWord>
      speed: Shaped<number>
    }
  }
}
