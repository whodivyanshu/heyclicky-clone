# Jarvis

A voice companion for your Mac. Hold a shortcut and ask about what's on screen. Jarvis answers out loud, and a small pointer next to your cursor flies to whatever it's talking about.

## Run it

```sh
scripts/build-app.sh
open dist/Jarvis.app
```

Settings opens on first launch:

1. Allow Microphone, Speech recognition and Screen recording, then quit and reopen Jarvis from its menu bar icon.
2. Choose a provider and click **Test connection**:
   - **Claude Code** runs your installed `claude` command with your existing login. Usage counts toward your Claude plan.
   - **Gemini** uses your API key, which is stored in the macOS Keychain.
3. Hold **⌃⌥** (Control + Option), talk, and let go. Press **Esc** to stop it.

## The island

A black pill at the top center of your screen shows what Jarvis is doing: listening with a live waveform, thinking, replying, or which walkthrough step you're on. On a Mac with a notch it grows out of the notch.

Hover over it to open your conversation and a box where you can type a question instead of talking. You can hide it when idle in Settings.

## Doing things for you

Ask Jarvis to open or quit any installed app, whether or not it's in the Dock, open a website, or find a file in your home folder and show it in Finder. It acts right away, and the island shows what it did. If something can't be done, it says so.

Actions only come from what you ask directly. Text on your screen can't trigger them, web actions only open `http` and `https` addresses, and found files are shown in Finder, not opened. Jarvis can't click or type for you.

## Guided walkthroughs

Ask "how do I..." or "walk me through..." and Jarvis circles one control and tells you to click it. When you click inside the circle, it takes a new screenshot and moves to the next step, for up to 8 steps. You do all the clicking. Clicking elsewhere, pressing Esc, holding the shortcut again, or waiting 2 minutes ends the walkthrough.

## Voices

- **Gemini voice** sounds natural and needs your Gemini API key, even if Claude Code is answering. Allow a few extra seconds before each reply starts. If a request fails before any sound, Jarvis says why and uses the Mac voice.
- **Mac voice** is free, works offline and starts right away. It sounds much better with a Premium voice from System Settings.

Needs macOS 14 or later and Xcode's command line tools.

## How it works

| Step | Code | Uses |
| --- | --- | --- |
| Detect the held shortcut and Esc | `HotkeyMonitor` | Key state polling, with no extra permission |
| Transcribe speech | `SpeechInput` | Apple Speech, on-device when supported |
| Capture each display | `ScreenCapture` | ScreenCaptureKit, leaving out Jarvis's own windows |
| Ask the AI and stream the reply | `Providers` | Gemini REST or `claude -p` |
| Split the reply into sentences and pointing tags | `JarvisCore/ResponseParser` | `[POINT:x,y:label:screenN]` |
| Speak and point, in order | `SpeechOutput`, `Overlay` | Gemini or Mac voice, click-through panels |
| Show status and take typed questions | `IslandView`, `IslandController` | SwiftUI in a non-activating panel |

`Coordinator` runs one turn from start to finish.

## Privacy

Jarvis listens only while the shortcut is held. Screenshots of every display are captured when you let go and sent to your chosen provider, so check what's on screen before asking. Jarvis has no backend or analytics.

Claude Code runs with no tools, hooks or MCP servers, so text on your screen can influence an answer but can't make Jarvis take an action.

## Development

```sh
swift test
# One request through the real provider and parser, no permissions needed:
dist/Jarvis.app/Contents/MacOS/Jarvis --ask "Where is Export?" --image shot.jpg --model haiku
dist/Jarvis.app/Contents/MacOS/Jarvis --ask "Say hi" --provider gemini
# Speak through the Gemini voice (plays aloud):
dist/Jarvis.app/Contents/MacOS/Jarvis --tts "Hello there" --voice Sulafat
# Run an action, or just report which app a name would open:
dist/Jarvis.app/Contents/MacOS/Jarvis --act "[OPEN_APP:Calculator]"
dist/Jarvis.app/Contents/MacOS/Jarvis --find-app "chat GPT"
# Save a Gemini key from stdin, as an alternative to Settings:
dist/Jarvis.app/Contents/MacOS/Jarvis --save-gemini-key
# Play through every island state and the pointer's flight:
open -n dist/Jarvis.app --args --demo
```

The build script signs with your Apple Development identity if you have one, so macOS keeps Jarvis's permissions across rebuilds. With ad-hoc signing you'd have to grant them again after each build.

The app icon is drawn by `scripts/make-icon.swift`. Run it from the project root after changing the design, then rebuild.
