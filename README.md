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
   - **Ollama** runs a model on this Mac, so your screenshots and questions stay here. Install [Ollama](https://ollama.com) and pull a model that can read images, such as `llama3.2-vision`. Pointing and clicking are usually less accurate than with the online models.
   - **Apple Intelligence** needs macOS 27 with Apple Intelligence turned on. On this Mac it answers questions, opens and quits apps and websites, and finds files, but only when your own words ask for it. It takes a screenshot only when you ask about your screen, and it can't click, type, point or use full control. It can also run on Apple's Private Cloud Compute, which has more room for long requests but needs internet, has a usage limit, and only works in a build signed with Apple's managed `com.apple.developer.private-cloud-compute` entitlement. Neither supports Hindi.
3. Hold **⌃⌥** (Control + Option), talk, and let go. Press **Esc** to stop it.

## The island

A black pill at the top center of your screen shows what Jarvis is doing: listening with a live waveform, thinking, replying, or which walkthrough step you're on. On a Mac with a notch it grows out of the notch.

Hover over it to open your conversation and a box where you can type a question instead of talking. You can hide it when idle in Settings.

## Doing things for you

Ask Jarvis to open or quit any installed app, whether or not it's in the Dock, open a website in your default browser or one you name ("open YouTube in Brave"), or find a file in your home folder and show it in Finder. It acts right away, and the island shows what it did. If something can't be done, it says so.

Simple commands, such as "open Chrome", "quit Slack", "go to github.com", "क्रोम खोलो" or "Slack band karo", run immediately without a screenshot or the AI. This only happens when the whole sentence is one command and it names an app or website Jarvis recognizes, and everything else goes to the AI as usual.

Jarvis also uses these apps directly, without the screen. Each one asks for permission the first time:

- **Calendar:** "what's on my calendar tomorrow?" or "add the dentist on Friday at 3".
- **Reminders:** "what are my reminders?" or "remind me to call Mum at 5".
- **Contacts:** "what's Lovesh's email?"
- **Mail:** "draft an email to Lovesh about the launch" opens a new draft for you to check and send. Jarvis doesn't read your inbox, and this never sends anything.
- **Shortcuts:** "run my Morning shortcut" runs any shortcut in your own list, by its exact name.

Looked-up details go to your chosen AI so it can answer. These work with every provider except Apple Intelligence on this Mac. Your own words act right away. A later step in a job, which follows a screenshot or looked-up data, asks you first.

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
- It won't type or press keys in password fields, terminal apps, Keychain Access, System Settings, security dialogs or Jarvis's own windows. It also refuses terminal panels inside other apps, such as VS Code, when the app labels them as terminals through Accessibility.
- It won't click or type in an app on your **Safety** page's block list, or outside your allow list if you turn that on.
- It can't press Esc, Command+Q or Command+Delete, including their variants.
- Typed text can't contain Return. Pressing Return is always a separate step. Pasted text can contain line breaks, which may send a message in some chat apps.

What it can't catch: an icon with no accessibility label that the model doesn't name as risky, or Return on an ordinary web form, such as a checkout page whose title doesn't give it away. For those Jarvis relies on the model asking first, and every step is decided from a screenshot, so a malicious page could still try to steer it. Watch it while it works, and leave this off when you're away from your Mac.

## Dictation

Choose a shortcut on the **Hands-free** page, then hold it anywhere you're typing, speak and let go. Your words are pasted where the cursor is, and your clipboard is put back afterward. "Um" and "uh" are removed on this Mac for free. **Clean up dictation with AI** also fixes punctuation and false starts, but sends what you said to your AI. Set the language to Hindi for Hindi, or Hindi mixed with English. It won't paste into password fields, and it never presses Return.

## Talking over Jarvis

Turn on **Talk over Jarvis to interrupt** on the **Hands-free** page. While Jarvis speaks, on-device speech recognition listens through your microphone. When it hears at least three words in a row that aren't in Jarvis's reply, the reply stops and what you said becomes the new request. Saying only "stop", "wait" or "ruko" just stops it. This uses no realtime API and adds no cost. It works best with headphones, because on speakers it can mistake the echo for you, and it needs a language with on-device recognition. It can't answer a "should I go ahead?" question, which still takes the shortcut or a button.

## Meeting notes

Say "start meeting notes" or use the menu bar icon, and a red dot stays on the island and the menu bar icon until you say "stop meeting notes". Jarvis hears your microphone and your Mac's sound, turns them into text on this Mac and keeps no audio. When you stop, the transcript goes to your chosen AI for a summary, decisions and action items, which you can add to Reminders on the **Meetings** page. Tell people on the call before you start, because some places require their consent. Recording stops by itself after 3 hours. The AI has no way to start a recording, and it only saves the summary as text, so nothing said on a call can make Jarvis act.

## Shortcuts and Siri

The **Ask Jarvis** action appears in the Shortcuts app and takes a request, then returns the reply, so your other automations can use it. It runs like a typed question.

## Teaching packs

When you ask to learn something ("teach me", "how do I..."), Jarvis adds notes for the app in front of you. Figma, Xcode, VS Code and Excel are built in. To add your own, save a `.md` file in the folder on the **Teaching** page, with a first line such as `apps: Sketch, Sketch Beta` and your notes below it.

## Screen memory

Off by default. Turn it on and Jarvis reads your screen every 20 seconds when it changes, keeping only the text, for 1, 7 or 30 days, so you can ask "where did I see that error yesterday?" or search on the **Screen memory** page. The text stays on this Mac in a file only your user can read, and the matches for a question go to your chosen AI. It skips password fields, password managers, private browser windows, a locked screen and apps you've blocked, and hides what looks like card numbers, keys and passwords. It can miss some, so turn it off or delete it if you've had something sensitive on screen.

## Selected text and clipboard

Select some text and say "rewrite this" or "explain this error", and Jarvis works from the exact text. It can put its answer on your clipboard, and with full control it can paste it in. It reads your clipboard only when you mention it, such as "what I copied", and skips clipboard text that password managers mark as secret. Selected text needs the Accessibility permission and is never read from password fields. Both are capped at 8,000 characters.

## Memory

Say "remember that my main project is Jarvis" and it's still known after you quit. Jarvis also saves lasting preferences you state, and "forget..." removes them. See and delete everything on the **Memory** page in Settings. Facts are kept in `~/Library/Application Support/Jarvis/memory.json`, limited to 50, and only your own direct requests can change them.

## History and activity

The **History** page keeps what you said and what Jarvis replied, so you can search it later. Past conversations aren't sent to your AI after you quit. The **Activity** page records every step Jarvis takes on your Mac and whether it worked, which can include what it typed. You can also keep a screenshot for each step, which is off by default. Both are on by default, stay on this Mac in files only your user can read, and can be turned off or deleted.

## Hands-free

These are all off until you turn them on, on the **Hands-free** page:

- **"Hey Jarvis"** starts a request without the shortcut. It's recognized on this Mac, so it only works for languages with on-device recognition. The microphone stays on while Jarvis is idle, macOS shows its orange dot, and it uses more battery.
- **Keep listening after a reply** gives you 6 seconds to carry on talking after a spoken reply. "Thanks" ends it.
- **Offer help with problems on screen** reads your screen on this Mac every 20 seconds, looking for messages such as "Build failed", and offers to help at most once every 5 minutes. Nothing goes to your AI unless you choose **Take a look**. It skips apps on your block list, password fields and a locked screen.

## Routines

Say "when I say focus mode, quit Slack and open Notes" or "every weekday at 9, read my calendar", or add one on the **Routines** page. Saying a routine's phrase works like any other request.

A scheduled routine may run with nobody at the Mac, so it never sees your screen, clicks or types, and any step that needs a yes is cancelled when nobody answers. It runs within 5 minutes of its time if the Mac is awake and unlocked, and is skipped otherwise.

## Guided walkthroughs

Say "teach me...", "show me how..." or "walk me through..." and Jarvis circles one control and tells you to click it. When you click inside the circle, it takes a new screenshot and moves to the next step, for up to 8 steps. You do all the clicking in a walkthrough. Clicking elsewhere, pressing Esc, holding the shortcut again, or waiting 2 minutes ends the walkthrough.

## Voices

- **Gemini voice** sounds natural and needs your Gemini API key, even if Claude Code is answering. It starts on the first finished sentence, but still takes longer to start than the Mac voice. If a request fails before any sound, Jarvis says why and uses the Mac voice.
- **Mac voice** is free, works offline and starts right away. It sounds much better with a Premium voice from System Settings.
- **Hindi assistant** is a switch on the Voice page. Jarvis listens and replies in Hindi with a deep Gemini voice and a light audio effect. It has an original sound and isn't a copy of any film's dubbed voice. Without a Gemini key it uses the Mac's Hindi voice.

Needs macOS 14 or later and Xcode's command line tools.

## How it works

| Step | Code | Uses |
| --- | --- | --- |
| Detect the held shortcut and Esc | `HotkeyMonitor` | Key state polling, with no extra permission |
| Transcribe speech | `SpeechInput` | Apple Speech, on-device when supported |
| Capture each display | `ScreenCapture` | ScreenCaptureKit, leaving out Jarvis's own windows |
| Ask the AI and stream the reply | `Providers`, `AppleIntelligenceProvider` | Gemini REST, `claude -p`, Ollama or Foundation Models |
| Use Calendar, Reminders, Contacts, Mail and Shortcuts | `NativeServices` | EventKit, Contacts, `mailto:` and the `shortcuts` command |
| Listen for "hey Jarvis" and for being talked over | `WakeWordListener`, `OnDeviceRecognition` | Apple Speech, on-device only |
| Turn a meeting into a transcript | `MeetingRecorder` | ScreenCaptureKit audio and Apple Speech, on-device only |
| Let Shortcuts and Siri ask Jarvis | `AskJarvisIntent` | App Intents |
| Run routines, follow-ups and offers of help | `Coordinator+Automation` | Timers, and Vision for reading the screen on this Mac |
| Keep history and activity | `Stores` | Private JSON files in Application Support |
| Split the reply into sentences and pointing tags | `JarvisCore/ResponseParser` | `[POINT:x,y:label:screenN]` |
| Speak and point, in order | `SpeechOutput`, `Overlay` | Gemini or Mac voice, click-through panels |
| Read selected text, control labels and what a click or key would hit | `UIInspector` | Accessibility, read-only |
| Decide what needs a yes | `JarvisCore/Safety` | Label and key rules, and spoken answers |
| Show status and take typed questions | `IslandView`, `IslandController` | SwiftUI in a non-activating panel |

`Coordinator` and its extensions run one turn from start to finish.

## Privacy

Unless you turn on a Hands-free option or start meeting notes, Jarvis listens only while a shortcut is held. Screenshots of every display are captured when you let go and sent to your chosen provider, so check what's on screen before asking. With Accessibility allowed, the labels of the front window's controls, your selected text and your saved memory facts go with them. Anything you ask it to look up in Calendar, Reminders or Contacts goes to your chosen provider too. With Ollama, all of this stays on your Mac. Jarvis has no backend or analytics. Release builds that you configure with an update address check it for updates.

Claude Code runs with no tools, hooks or MCP servers. With full control off, text on your screen can influence an answer but can't make Jarvis take more than the one step you asked for. With it on, see the limits under [Full control](#full-control).

## Development

```sh
swift test
# One request through the real provider and parser, no permissions needed:
dist/Jarvis.app/Contents/MacOS/Jarvis --ask "Where is Export?" --image shot.jpg --model haiku
dist/Jarvis.app/Contents/MacOS/Jarvis --ask "Say hi" --provider gemini
dist/Jarvis.app/Contents/MacOS/Jarvis --ask "Where is Export?" --image shot.jpg --provider apple
dist/Jarvis.app/Contents/MacOS/Jarvis --ask "Where is Export?" --image shot.jpg --provider apple-cloud
dist/Jarvis.app/Contents/MacOS/Jarvis --ask "Where is Export?" --image shot.jpg --provider ollama --model llama3.2-vision
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

CI runs the tests and builds the app on every push, using `.github/workflows/ci.yml`. It needs a runner with Xcode 27 or later, because Apple Intelligence support uses the macOS 27 SDK.

To build a release others can install, see the setup steps at the top of `scripts/release.sh`. It needs a Developer ID certificate from a paid Apple Developer account and a Sparkle update key. It signs and notarizes the app and writes the update feed to `dist/release`, and publishing those files is up to you. Development builds never check for updates.

The app icon is drawn by `scripts/make-icon.swift`. Run it from the project root after changing the design, then rebuild.
