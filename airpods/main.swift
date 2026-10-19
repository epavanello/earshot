// AirPods remote for Claude Desktop dictation (macOS).
// Claude Desktop dictation is push-to-talk on Cmd+D: held down it records, released it transcribes.
// Stem click: holds Cmd+D. Chin down and back up: releases it and presses Return.
// While the mic is on, macOS keeps stem clicks for call mute; head motion still gets through.
import AppKit
import AVFoundation
import MediaPlayer
import CoreMotion

let claudeBundleId = "com.anthropic.claudefordesktop"
let releaseToSendDelay = 0.2 // Claude queues Return until the transcription is ready
let maxRecording = 180.0 // send anyway after this
let nodAngle = 15.0 * .pi / 180
let backToRestAngle = 6.0 * .pi / 180
let gestureWindow = 2.0
let gestureGracePeriod = 1.0 // ignore head motion right after the click
let restFollowRate = 0.02 // the rest pose slowly follows the real one (walking moves the head)
// Semaphore for the speak hook: while it exists you are dictating, so replies are not read aloud.
let recordingFlag = "/tmp/earshot.recording"

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

func setDictationKey(isDown: Bool) {
    if isDown {
        hammerspoon("hs.eventtap.event.newKeyEvent('cmd', true):post(); hs.eventtap.event.newKeyEvent({'cmd'}, 'd', true):post()")
    } else {
        // Cmd must be released too, or the following Return becomes Cmd+Return and doesn't send.
        hammerspoon("hs.eventtap.event.newKeyEvent({'cmd'}, 'd', false):post(); hs.eventtap.event.newKeyEvent('cmd', false):post()")
    }
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

func stopSpeech() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    process.arguments = ["-x", "say"]
    try? process.run()
}

func startRecording() {
    guard state == .idle else { return }
    stopSpeech()
    guard activateClaude() else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        setDictationKey(isDown: true)
        FileManager.default.createFile(atPath: recordingFlag, contents: nil)
        state = .recording
        recordingStart = Date()
        resetHeadRest()
        maxRecordingTimer = Timer.scheduledTimer(withTimeInterval: maxRecording, repeats: false) { _ in sendMessage() }
        NSSound(named: "Tink")?.play()
        log("Dictation started")
    }
}

func sendMessage() {
    guard state == .recording else { return }
    state = .sending
    maxRecordingTimer?.invalidate()
    guard activateClaude() else {
        setDictationKey(isDown: false)
        try? FileManager.default.removeItem(atPath: recordingFlag)
        state = .idle
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        setDictationKey(isDown: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseToSendDelay) {
            hammerspoon("hs.eventtap.keyStroke({}, 'return', 50000)")
            try? FileManager.default.removeItem(atPath: recordingFlag)
            state = .idle
            NSSound(named: "Pop")?.play()
            log("Message sent")
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
    if isClaudeFrontmost || state != .idle {
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

let center = MPRemoteCommandCenter.shared()
for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand] {
    command.addTarget { _ in
        DispatchQueue.main.async {
            switch state {
            case .idle: startRecording()
            case .recording: sendMessage()
            case .sending: break
            }
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
log("Listening to AirPods (head motion available: \(headphoneMotion.isDeviceMotionAvailable))")
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
