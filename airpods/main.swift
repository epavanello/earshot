// AirPods remote for Claude Desktop dictation (macOS).
// A quick Cmd+D tap toggles Claude Desktop dictation, which keeps recording when Claude loses focus.
// Stem double click (Claude Desktop in front): taps Cmd+D. 2.5 s of silence after speaking, or chin down
// and back up: brings Claude to the front and presses Return. Esc anywhere stops the speech.
// While the mic is on, macOS keeps stem clicks for call mute; head motion still gets through.
import AppKit
import AVFoundation
import MediaPlayer
import CoreMotion
import CoreAudio

let claudeBundleId = "com.anthropic.claudefordesktop"
let secondReturnDelay = 2.5 // seconds: time for the transcription to land before the safety Return
let maxRecording = 180.0 // send anyway after this
let nodAngle = 20.0 * .pi / 180
let backToRestAngle = 6.0 * .pi / 180
let gestureWindow = 2.0
let gestureGracePeriod = 1.0 // ignore head motion right after the click
let restFollowRate = 0.02 // the rest pose slowly follows the real one (walking moves the head)
let speechLevel: Float = -40 // dB: speech measured around -20/-30, pauses around -50/-65
let noSpeechTimeout = 12.0 // seconds: no speech at all means dictation never started (e.g. a dialog had focus)
let silenceToSend = 3.5 // seconds of silence after speaking that send the message
// Semaphore for the speak hook: while it exists you are dictating, so replies are not read aloud.
let recordingFlag = "/tmp/earshot.recording"
// Written by the speak hook while `say` is talking: any click then stops the speech, whatever app is in front.
let speakingFlag = "/tmp/earshot.speaking"

func isSpeaking() -> Bool {
    FileManager.default.fileExists(atPath: speakingFlag)
}

enum State { case idle, recording, sending }
var state = State.idle
var recordingStart = Date()
var maxRecordingTimer: Timer?

func log(_ message: String) {
    print("[\(Date())] \(message)")
    fflush(stdout)
}

// Hammerspoon presses the keys: it already has Accessibility permission, while this binary would
// lose it on every rebuild (its code signature changes).
let hammerspoonCli = ["/opt/homebrew/bin/hs", "/usr/local/bin/hs"].first { FileManager.default.isExecutableFile(atPath: $0) }

func hammerspoon(_ lua: String) {
    guard let hammerspoonCli else {
        log("Hammerspoon CLI not found: install Hammerspoon and run hs.ipc.cliInstall()")
        return
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: hammerspoonCli)
    process.arguments = ["-c", lua]
    try? process.run()
}

// A quick tap of Cmd+D toggles Claude's dictation, which then keeps recording even when Claude
// loses focus (holding it is push-to-talk and stops on focus loss).
// Like a real tap: Cmd down, D down/up, Cmd up. keyStroke() never sends the Cmd key events, and
// Claude then treats Cmd as still held (push-to-talk), which stops when Claude loses focus.
func tapDictationKey() {
    hammerspoon("""
    local e = hs.eventtap.event
    e.newKeyEvent('cmd', true):post()
    e.newKeyEvent({'cmd'}, 'd', true):post()
    hs.timer.usleep(40000)
    e.newKeyEvent({'cmd'}, 'd', false):post()
    e.newKeyEvent('cmd', false):post()
    """)
}

// Esc anywhere stops the speech. The watcher lives in Hammerspoon (it already has the permissions
// to see keys) and is (re)installed from here, so no Hammerspoon config file is touched.
func installEscWatcher() {
    hammerspoon("""
    if not earshotEsc or not earshotEsc:isEnabled() then
      earshotEsc = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(e)
        if e:getKeyCode() == 53 and hs.fs.attributes('\(speakingFlag)') then
          os.execute('/usr/bin/pkill -x say; rm -f \(speakingFlag)')
        end
        return false
      end):start()
    end
    """)
}

func activateClaude() -> Bool {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleId).first else {
        log("Claude Desktop is not running")
        NSSound(named: "Basso")?.play()
        return false
    }
    app.activate()
    return true
}

// Optional spoken debug: `touch ~/.config/earshot/debug-voice` to hear each step, delete it to stop.
let debugVoiceFlag = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/earshot/debug-voice").path
let isItalian = Locale.preferredLanguages.first?.hasPrefix("it") ?? false

func announce(_ english: String, _ italian: String) {
    guard FileManager.default.fileExists(atPath: debugVoiceFlag) else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = [isItalian ? italian : english]
    try? process.run()
}

func isMicInUse() -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var device = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    var isRunning: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)
    address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
    AudioObjectGetPropertyData(device, &address, 0, nil, &size, &isRunning)
    return isRunning != 0
}

func stopSpeech() {
    try? FileManager.default.removeItem(atPath: speakingFlag)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    process.arguments = ["-x", "say"]
    try? process.run()
}

func startRecording() {
    guard state == .idle else { return }
    stopSpeech()
    if isMicInUse() { announce("Mic busy", "Microfono occupato") }
    guard activateClaude() else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        tapDictationKey()
        FileManager.default.createFile(atPath: recordingFlag, contents: nil)
        state = .recording
        recordingStart = Date()
        resetHeadRest()
        startSilenceDetection()
        maxRecordingTimer = Timer.scheduledTimer(withTimeInterval: maxRecording, repeats: false) { _ in sendMessage() }
        NSSound(named: "Tink")?.play()
        log("Dictation started")
        announce("Talk", "Parla pure")
    }
}

// Nothing was said: free the mic (it keeps the AirPods in call mode) without pressing anything.
func abandonRecording() {
    guard state == .recording else { return }
    maxRecordingTimer?.invalidate()
    stopMic()
    try? FileManager.default.removeItem(atPath: recordingFlag)
    state = .idle
    NSSound(named: "Funk")?.play()
    log("No speech: dictation abandoned")
    announce("No speech, cancelled", "Nessuna voce, annullato")
}

func sendMessage() {
    guard state == .recording else { return }
    state = .sending
    maxRecordingTimer?.invalidate()
    stopMic()
    guard activateClaude() else {
        try? FileManager.default.removeItem(atPath: recordingFlag)
        state = .idle
        return
    }
    // Return stops the dictation and sends once the transcription is ready. A second Return covers
    // the case where the first one only stopped it; on an empty input it does nothing.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        hammerspoon("hs.eventtap.keyStroke({}, 'return', 50000)")
        DispatchQueue.main.asyncAfter(deadline: .now() + secondReturnDelay) {
            hammerspoon("hs.eventtap.keyStroke({}, 'return', 50000)")
            try? FileManager.default.removeItem(atPath: recordingFlag)
            state = .idle
            NSSound(named: "Pop")?.play()
            log("Message sent")
            announce("Sent", "Inviato")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if state == .idle && isMicInUse() { announce("Mic still busy", "Microfono ancora occupato") }
            }
        }
    }
}

// Silence detection. The mic can be shared with Claude's dictation, so we listen only while
// dictating: any mic listener puts the AirPods in call mode, where clicks become mute.
// A fresh engine per dictation, dropped afterwards: a stopped engine that keeps its input node
// alive still holds the AirPods in call mode, and double clicks then fail with the "denied" sound.
var micEngine: AVAudioEngine?
var micObserver: NSObjectProtocol?
var micLevel: Float = -100
var isMicRunning = false
var hasSpoken = false
var lastSpeech = Date()
var silenceTimer: Timer?
var levelTicks = 0

func startMic() {
    stopMicEngine()
    let engine = AVAudioEngine()
    let input = engine.inputNode
    input.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
        guard let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let level = 10 * log10(max(sum / Float(max(count, 1)), 1e-10))
        DispatchQueue.main.async { micLevel = level }
    }
    // The AirPods switching to the mic profile stops the engine: start a new one while dictating.
    micObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
        if state == .recording { startMic() }
    }
    micEngine = engine
    do {
        try engine.start()
        isMicRunning = true
        log("Mic started")
    } catch {
        log("Mic start failed, retrying: \((error as NSError).code)")
        // Right after Cmd+D the AirPods are still switching to the mic profile (-10868): retry.
        isMicRunning = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if state == .recording && !isMicRunning { startMic() }
        }
    }
}

func stopMicEngine() {
    if let micObserver { NotificationCenter.default.removeObserver(micObserver) }
    micObserver = nil
    micEngine?.inputNode.removeTap(onBus: 0)
    micEngine?.stop()
    micEngine?.reset()
    micEngine = nil
    isMicRunning = false
}

func stopMic() {
    silenceTimer?.invalidate()
    stopMicEngine()
}

func startSilenceDetection() {
    hasSpoken = false
    micLevel = -100
    startMic()
    silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
        guard state == .recording else { return }
        levelTicks += 1
        if levelTicks % 10 == 0 { log(String(format: "Mic level %.0f dB, spoken: \(hasSpoken)", micLevel)) }
        if micLevel > speechLevel {
            hasSpoken = true
            lastSpeech = Date()
        } else if hasSpoken && Date().timeIntervalSince(lastSpeech) > silenceToSend {
            log("Silence detected")
            announce("Silence, sending", "Silenzio, invio")
            sendMessage()
        } else if !hasSpoken && Date().timeIntervalSince(recordingStart) > noSpeechTimeout {
            abandonRecording()
        }
    }
}


// Silent audio loop: the "now playing" app is the one that receives AirPods clicks.
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
silence.frameLength = 44100
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: format)

func startSilentPlayback() {
    do {
        try engine.start()
    } catch {
        log("Audio not started: \(error)")
        return
    }
    // play() raises an Objective-C exception (a crash) if the engine stopped meanwhile.
    guard engine.isRunning else { return }
    player.scheduleBuffer(silence, at: nil, options: .loops)
    player.play()
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "Earshot remote"]
    MPNowPlayingInfoCenter.default().playbackState = .playing
}

func stopSilentPlayback() {
    player.stop()
    engine.stop()
    MPNowPlayingInfoCenter.default().playbackState = .stopped
}

// Own the clicks only while Claude is frontmost: with any other app in front they go back to music.
func updateClickOwnership() {
    let isClaudeFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleId
    if isClaudeFrontmost || state != .idle || isSpeaking() {
        if !engine.isRunning || !player.isPlaying { startSilentPlayback() }
        MPNowPlayingInfoCenter.default().playbackState = .playing
    } else if engine.isRunning {
        stopSilentPlayback()
    }
}

updateClickOwnership()
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
    updateClickOwnership()
}


// When the AirPods switch to the mic profile and back, macOS stops the audio engine.
NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
    updateClickOwnership()
}
// Another app (e.g. Spotify) can take "now playing" even with Claude in front: take it back.
Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in updateClickOwnership() }
// Speech starts and ends outside this process: follow it closely so the first click can stop it.
var wasSpeaking = false
Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
    let speaking = isSpeaking()
    if speaking != wasSpeaking {
        wasSpeaking = speaking
        updateClickOwnership()
    }
}

let center = MPRemoteCommandCenter.shared()
// A double click (next track) starts dictation, only with Claude Desktop in front and nothing being
// recorded. Single clicks are not used: taking an AirPod out sends the same "pause" as a click.
// Anything arriving while you dictate is ignored too (sending is the nod's job).
let namedCommands: [(String, MPRemoteCommand)] = [
    ("togglePlayPause", center.togglePlayPauseCommand), ("play", center.playCommand), ("pause", center.pauseCommand),
    ("nextTrack", center.nextTrackCommand),
]
for (name, command) in namedCommands {
    command.addTarget { _ in
        DispatchQueue.main.async {
            if isSpeaking() {
                stopSpeech()
                log("Speech stopped by \(name)")
            }
            let isClaudeFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleId
            guard name == "nextTrack", state == .idle, isClaudeFrontmost else {
                log("Ignored \(name) (state \(state), Claude in front: \(isClaudeFrontmost))")
                return
            }
            startRecording()
        }
        return .success
    }
}

// Nod: the pitch leaves the rest pose by at least `nodAngle` and comes back within `gestureWindow`.
let headphoneMotion = CMHeadphoneMotionManager()
var restPitch: Double?
var nodStart: Date?

func resetHeadRest() {
    restPitch = nil
    nodStart = nil
}

func angleDifference(_ a: Double, _ b: Double) -> Double {
    atan2(sin(a - b), cos(a - b))
}

headphoneMotion.startDeviceMotionUpdates(to: .main) { motion, error in
    if let error {
        log("Head motion error: \(error)")
        return
    }
    guard let pitch = motion?.attitude.pitch, state == .recording else { return }
    let now = Date()
    guard now.timeIntervalSince(recordingStart) > gestureGracePeriod else { return }
    guard let basePitch = restPitch else {
        restPitch = pitch
        return
    }
    // "Down" depends on how the AirPods sit, so either direction counts.
    let offset = angleDifference(pitch, basePitch)
    if abs(offset) > nodAngle && nodStart == nil {
        nodStart = now
    } else if let start = nodStart, abs(offset) < backToRestAngle {
        nodStart = nil
        if now.timeIntervalSince(start) < gestureWindow {
            log("Nod detected")
            announce("Nod, sending", "Cenno, invio")
            sendMessage()
            return
        }
    } else if let start = nodStart, now.timeIntervalSince(start) > gestureWindow {
        nodStart = nil
    }
    if nodStart == nil && abs(offset) < backToRestAngle {
        restPitch = basePitch + offset * restFollowRate
    }
}

try? FileManager.default.removeItem(atPath: recordingFlag)
installEscWatcher()
Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in installEscWatcher() } // survives Hammerspoon reloads
log("Listening to AirPods (head motion available: \(headphoneMotion.isDeviceMotionAvailable))")
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
