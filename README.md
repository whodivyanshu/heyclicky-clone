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
   - **Apple Intelligence** needs macOS 27 with Apple Intelligence turned on. On this Mac it answers questions, opens and quits apps and websites, and finds files, but only when your own words ask for it. It takes a screenshot only when you ask about your screen, and it can't click, type, point or use full control. It can also run on Apple's Private Cloud Compute, which has more room for long requests but needs internet, has a usage limit, and only works in a build signed with Apple's managed `com.apple.developer.private-cloud-compute` entitlement. Neither supports Hindi.
3. Hold **⌃⌥** (Control + Option), talk, and let go. Press **Esc** to stop it.

## The island

A black pill at the top center of your screen shows what Jarvis is doing: listening with a live waveform, thinking, replying, or which walkthrough step you're on. On a Mac with a notch it grows out of the notch.

Hover over it to open your conversation and a box where you can type a question instead of talking. You can hide it when idle in Settings.

## Doing things for you

Ask Jarvis to open or quit any installed app, whether or not it's in the Dock, open a website in your default browser or one you name ("open YouTube in Brave"), or find a file in your home folder and show it in Finder. It acts right away, and the island shows what it did. If something can't be done, it says so.

Simple English commands, such as "open Chrome", "quit Slack" or "go to github.com", run immediately without a screenshot or the AI. This only happens when the whole sentence is one command and it names an app or website Jarvis recognizes, and everything else goes to the AI as usual.

Actions only come from what you ask directly. Text on your screen can't trigger them, web actions only open `http` and `https` addresses, and found files are shown in Finder, not opened.

Jarvis can also click something you can see when you ask, such as a project in VS Code's recent list. The pointer flies to it first, and Esc stops it. This needs the Accessibility permission, which macOS asks for the first time Jarvis clicks. It makes one click per reply, and it won't click in System Settings or security dialogs. Without full control it can't type, and anything longer than one step ends with it telling you to turn full control on.

### Full control

Turn on **Let Jarvis control my Mac** in Settings and Jarvis finishes whole jobs by itself. Say "open WhatsApp and send Lovesh how are you", and it plans the steps, then opens the app, finds the chat and types the message, taking a new screenshot before each step, for up to 30 steps. It works silently and speaks when it's finished or needs you. If a step fails, it tries another way, up to 3 times. Press **Esc** to stop it at any time. It's off by default and needs the Accessibility permission.

### Asking before big actions

Before a step that's hard to take back, such as sending, posting, deleting, paying, signing in or calling, Jarvis stops and asks. The island shows what it's about to press and exactly what it typed. Click **Yes, do it**, or hold the shortcut and say yes or no. A no, Esc or 60 seconds of silence cancels the step. An unclear answer asks again. This also covers single clicks when full control is off.

Enforced in code:

- The model can't answer for you. A yes only comes from your voice or the button.
- Jarvis asks when the app's own label for a control, or the model's name for it, sounds risky. Labels are read through Accessibility.
- It asks before Return in chat and mail apps, and in browser windows titled with sites such as Gmail or WhatsApp, unless the focus is in a search box. It also asks before Command or Control+Return, Return when the default button sounds risky, Delete outside a text box, and Mail's send shortcut.
- After a yes, if the front app or the control under the pointer has changed, the step is cancelled.
- It won't type or press keys in password fields, terminal apps, Keychain Access, System Settings, security dialogs or Jarvis's own windows. Terminal panes inside other apps, such as VS Code, aren't detected.
- It can't press Esc, Command+Q or Command+Delete, including their variants.
- Typed text can't contain Return. Pressing Return is always a separate step. Pasted text can contain line breaks, which may send a message in some chat apps.

What it can't catch: an icon with no accessibility label that the model doesn't name as risky, or Return on an ordinary web form, such as a checkout page whose title doesn't give it away. For those Jarvis relies on the model asking first, and every step is decided from a screenshot, so a malicious page could still try to steer it. Watch it while it works, and leave this off when you're away from your Mac.

## Selected text and clipboard

Select some text and say "rewrite this" or "explain this error", and Jarvis works from the exact text. It can put its answer on your clipboard, and with full control it can paste it in. It reads your clipboard only when you mention it, such as "what I copied", and skips clipboard text that password managers mark as secret. Selected text needs the Accessibility permission and is never read from password fields. Both are capped at 8,000 characters.

## Memory

Say "remember that my main project is Jarvis" and it's still known after you quit. Jarvis also saves lasting preferences you state, and "forget..." removes them. See and delete everything on the **Memory** page in Settings. Facts are kept in `~/Library/Application Support/Jarvis/memory.json`, limited to 50, and only your own direct requests can change them. Your conversation itself is still forgotten when you quit.

## Guided walkthroughs

Say "teach me...", "show me how..." or "walk me through..." and Jarvis circles one control and tells you to click it. When you click inside the circle, it takes a new screenshot and moves to the next step, for up to 8 steps. You do all the clicking in a walkthrough. Clicking elsewhere, pressing Esc, holding the shortcut again, or waiting 2 minutes ends the walkthrough.

## Voices

- **Gemini voice** sounds natural and needs your Gemini API key, even if Claude Code is answering. Allow a few extra seconds before each reply starts. If a request fails before any sound, Jarvis says why and uses the Mac voice.
- **Mac voice** is free, works offline and starts right away. It sounds much better with a Premium voice from System Settings.
- **Hindi assistant** is a switch on the Voice page. Jarvis listens and replies in Hindi with a deep Gemini voice and a light audio effect. It has an original sound and isn't a copy of any film's dubbed voice. Without a Gemini key it uses the Mac's Hindi voice.

Needs macOS 14 or later and Xcode's command line tools.

## How it works

| Step | Code | Uses |
| --- | --- | --- |
| Detect the held shortcut and Esc | `HotkeyMonitor` | Key state polling, with no extra permission |
| Transcribe speech | `SpeechInput` | Apple Speech, on-device when supported |
| Capture each display | `ScreenCapture` | ScreenCaptureKit, leaving out Jarvis's own windows |
| Ask the AI and stream the reply | `Providers`, `AppleIntelligenceProvider` | Gemini REST, `claude -p` or Foundation Models |
| Split the reply into sentences and pointing tags | `JarvisCore/ResponseParser` | `[POINT:x,y:label:screenN]` |
| Speak and point, in order | `SpeechOutput`, `Overlay` | Gemini or Mac voice, click-through panels |
| Read selected text, control labels and what a click or key would hit | `UIInspector` | Accessibility, read-only |
| Decide what needs a yes | `JarvisCore/Safety` | Label and key rules, and spoken answers |
| Show status and take typed questions | `IslandView`, `IslandController` | SwiftUI in a non-activating panel |

`Coordinator` runs one turn from start to finish.

## Privacy

Jarvis listens only while the shortcut is held. Screenshots of every display are captured when you let go and sent to your chosen provider, so check what's on screen before asking. With Accessibility allowed, the labels of the front window's controls, your selected text and your saved memory facts go with them. Jarvis has no backend or analytics.

Claude Code runs with no tools, hooks or MCP servers. With full control off, text on your screen can influence an answer but can't make Jarvis take more than the one step you asked for. With it on, see the limits under [Full control](#full-control).

## Development

```sh
swift test
# One request through the real provider and parser, no permissions needed:
dist/Jarvis.app/Contents/MacOS/Jarvis --ask "Where is Export?" --image shot.jpg --model haiku
dist/Jarvis.app/Contents/MacOS/Jarvis --ask "Say hi" --provider gemini
dist/Jarvis.app/Contents/MacOS/Jarvis --ask "Where is Export?" --image shot.jpg --provider apple
dist/Jarvis.app/Contents/MacOS/Jarvis --ask "Where is Export?" --image shot.jpg --provider apple-cloud
# Same, with the full control instructions:
dist/Jarvis.app/Contents/MacOS/Jarvis --ask "Search YouTube for cats in Brave" --full-control --model haiku
# Speak through the Gemini voice (plays aloud):
dist/Jarvis.app/Contents/MacOS/Jarvis --tts "Hello there" --voice Sulafat
# Run an action, or just report which app a name would open:
dist/Jarvis.app/Contents/MacOS/Jarvis --act "[OPEN_APP:Calculator]"
dist/Jarvis.app/Contents/MacOS/Jarvis --act "[OPEN_URL:example.com|Brave]"
dist/Jarvis.app/Contents/MacOS/Jarvis --find-app "chat GPT"
# Save a Gemini key from stdin, as an alternative to Settings:
dist/Jarvis.app/Contents/MacOS/Jarvis --save-gemini-key
# Play through every island state and the pointer's flight:
open -n dist/Jarvis.app --args --demo
# Watch how long each stage of a request takes (stage names and times only):
log stream --predicate 'subsystem == "local.jarvis.companion" AND category == "timing"'
```

The build script signs with your Apple Development identity if you have one, so macOS keeps Jarvis's permissions across rebuilds. With ad-hoc signing you'd have to grant them again after each build.

The app icon is drawn by `scripts/make-icon.swift`. Run it from the project root after changing the design, then rebuild.
