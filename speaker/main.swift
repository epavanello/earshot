// earshot's speaker: `say` with the same voices and rate, which also tells where it is. While it
// speaks it keeps a progress file (default /tmp/earshot.progress) with the text, the word being
// spoken (UTF-16 offset and length, as JavaScript counts) and whether it is paused, so the inline
// player in the transcript can follow word by word.
// Usage: say [-r words-per-minute] [-v voice name] [--offset n] text
// --offset starts reading at that UTF-16 offset of the text (a click on a word, a speed change); the
// progress keeps the whole text and counts from its start.
// Signals: SIGUSR1 pauses or resumes at the next word; SIGTERM / SIGINT stop.
// Built as a binary named `say` so that every `pkill -x say` in earshot stops it too.
import AppKit

let progressPath = (ProcessInfo.processInfo.environment["EARSHOT_TMP"] ?? "/tmp") + "/earshot.progress"

var rate: Float?
var voiceName: String?
var offset = 0
var words: [String] = []
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
  switch arg {
  case "-r": rate = args.next().flatMap(Float.init)
  case "-v": voiceName = args.next()
  case "--offset": offset = args.next().flatMap(Int.init) ?? 0
  default: words.append(arg)
  }
}
let text = words.joined(separator: " ")
if text.isEmpty { exit(0) }
offset = max(0, min(offset, (text as NSString).length))
let spoken = (text as NSString).substring(from: offset)

final class Speaker: NSObject, NSSpeechSynthesizerDelegate {
  let synth = NSSpeechSynthesizer()
  var start = offset
  var length = 0
  var isPaused = false

  override init() {
    super.init()
    if let name = voiceName,
       let voice = NSSpeechSynthesizer.availableVoices.first(where: {
         (NSSpeechSynthesizer.attributes(forVoice: $0)[.name] as? String)?.caseInsensitiveCompare(name) == .orderedSame
       }) {
      synth.setVoice(voice)
    }
    if let rate { synth.rate = rate }
    synth.delegate = self
  }

  func write(_ state: String) {
    let payload: [String: Any] = [
      "pid": Int(getpid()), "text": text, "start": start, "length": length, "state": state,
      "at": Date().timeIntervalSince1970,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload) {
      try? data.write(to: URL(fileURLWithPath: progressPath), options: .atomic)
    }
  }

  func speak() {
    write("speaking")
    synth.startSpeaking(spoken)
  }

  func togglePause() {
    if isPaused {
      synth.continueSpeaking()
    } else {
      synth.pauseSpeaking(at: .wordBoundary)
    }
    isPaused.toggle()
    write(isPaused ? "paused" : "speaking")
  }

  func stop() {
    synth.stopSpeaking()
    finish()
  }

  func finish() {
    start = (text as NSString).length
    length = 0
    write("done")
    exit(0)
  }

  func speechSynthesizer(_ sender: NSSpeechSynthesizer, willSpeakWord range: NSRange, of string: String) {
    start = offset + range.location
    length = range.length
    write(isPaused ? "paused" : "speaking")
  }

  func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
    finish()
  }
}

let speaker = Speaker()
var sources: [DispatchSourceSignal] = []
for (signo, action) in [(SIGUSR1, speaker.togglePause), (SIGTERM, speaker.stop), (SIGINT, speaker.stop)] {
  signal(signo, SIG_IGN)
  let source = DispatchSource.makeSignalSource(signal: signo, queue: .main)
  source.setEventHandler(handler: action)
  source.resume()
  sources.append(source)
}
speaker.speak()
RunLoop.main.run()
