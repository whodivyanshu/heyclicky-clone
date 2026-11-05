# Jarvis for Windows

The same companion as the Mac app: hold a shortcut, ask about what's on screen, and Jarvis answers out loud while a small pointer flies to whatever it's talking about. See the [main README](../README.md) for what each feature does. This page covers what's different on Windows.

Needs 64-bit Windows 10 version 2004 or later, or Windows 11.

## Run it

Run `Jarvis-Setup.exe`. It installs for your account only and doesn't ask for administrator rights. Windows SmartScreen will warn you the first time, because the installer isn't code-signed yet. Choose **More info**, then **Run anyway**.

Settings opens on first launch:

1. On the **Setup** page, download the speech model (about 148 MB). It runs on your PC, so no audio leaves it.
2. On the **AI** page, choose a provider and click **Test**:
   - **Claude Code** runs your installed `claude` command with your existing login. Usage counts toward your Claude plan.
   - **Gemini** uses your API key, which is stored on this PC and encrypted for your Windows account.
   - **Ollama** runs a model on this PC, so your screenshots and questions stay here.
3. Hold **Ctrl + Alt**, talk, and let go. Press **Esc** to stop it.

Jarvis lives in the system tray. Closing Settings leaves it running, and **Quit Jarvis** is in the tray icon's menu.

## What's different from the Mac

| On a Mac | On Windows |
| --- | --- |
| Hold Control + Option | Hold Ctrl + Alt. You can also choose Ctrl + Win or Alt + Win |
| Apple Speech | Whisper, on your PC, for talking, "Hey Jarvis", interrupting and meeting notes. Text appears in bursts about once a second rather than word by word, and it's usually less responsive on a slower processor |
| The Mac voice | The Windows voice. Hindi needs a Hindi voice from Windows Settings, under Time & language, Speech |
| Calendar, Reminders and Contacts | **Classic Outlook only.** Reminders become Outlook tasks. The new Outlook has no way for other apps to reach this data, so without classic Outlook these requests say so |
| Mail drafts | The same, through your default mail app |
| Screen Recording and Accessibility permissions | Windows doesn't ask for these. Microphone access for desktop apps is the only switch, under Privacy & security |
| Keychain | DPAPI, which encrypts the key so only your Windows account can read it |
| Files in `~/Library/Application Support/Jarvis` | Files in `%LOCALAPPDATA%\Jarvis` |

These aren't available on Windows:

- **Apple Intelligence**, which is Apple's alone. Use Ollama if you want everything to stay on your PC.
- **Apple Shortcuts and Siri**, including the **Ask Jarvis** action.
- **Automatic updates.** To update, run the newer installer.

## Safety on Windows

The rules that decide what needs a yes are the same code as on the Mac. On Windows they also:

- **Refuse these keys entirely:** Alt+F4, Ctrl+Q, Alt+Space, Shift+Delete, Ctrl+Delete, Ctrl+Backspace, Ctrl+Alt+Delete, Esc, and anything using the Windows key, which rules out Win+R and Win+L.
- **Ask first for:** Alt+S, which is Outlook's send shortcut, and Ctrl+D in File Explorer, which deletes the selected file.
- **Never type in:** terminals such as Command Prompt, PowerShell, Windows Terminal and WSL, or the Run box.
- **Never click or type in:** Windows Settings, Windows Security, UAC prompts, Registry Editor, Task Manager or Jarvis's own windows.
- **Leave administrator apps alone.** Jarvis never runs as administrator, and Windows won't let it control apps that do, so it tells you rather than appearing to have clicked.

Windows has no system-wide "a password field has focus" signal like the Mac has, so Jarvis asks the focused control through UI Automation, and refuses to type if it can't get an answer. An app that doesn't report its password fields properly could still be typed into, so the same advice applies: watch it while it works, and leave full control off when you're away from your PC.

Jarvis's own windows are excluded from its screenshots using `WDA_EXCLUDEFROMCAPTURE`.

## Build it

From the repository root, with Swift 6.4 and the .NET 10 SDK installed:

```powershell
windows\scripts\build.ps1
```

This builds the Swift bridge, publishes the app to `windows\dist\Jarvis`, and builds `windows\dist\Jarvis-Setup.exe` if [Inno Setup](https://jrsoftware.org/isinfo.php) is installed.

You can check that the C# compiles on any platform, though it only runs on Windows:

```sh
cd windows/Jarvis && dotnet build
```

## How it fits together

The rules live once, in Swift, and both apps use them. `Sources/JarvisCore` holds the logic, and `Sources/JarvisBridge` exposes it to C# through one function, `jarvis_call`, which takes a method name and JSON. Adding a rule there changes both platforms.

| Step | Code | Uses |
| --- | --- | --- |
| Call the shared rules | `Core/Core.cs` | The Swift bridge DLL |
| Detect the held shortcut and Esc | `Platform/HotkeyMonitor.cs` | Key state polling, with no keyboard hook |
| Transcribe speech | `Speech/Recognition.cs` | Whisper.net and NAudio |
| Capture each display and read text from it | `Platform/ScreenCapture.cs` | GDI and `Windows.Media.Ocr` |
| Ask the AI and stream the reply | `App/Providers.cs` | Gemini REST, `claude -p` or Ollama |
| Read controls, selected text and what a key would hit | `Platform/UIInspector.cs` | UI Automation, read-only |
| Click, type and open things | `Platform/ActionRunner.cs` | `SendInput` and the Windows shell |
| Use calendar, tasks and contacts | `Platform/NativeServices.cs` | Outlook automation |
| Speak | `Speech/SpeechOutput.cs`, `Speech/KokoroEngine.cs` | Gemini, the Windows voice or Kokoro |
| Run one turn from start to finish | `App/Coordinator.cs`, `App/Coordinator.Automation.cs` | |
| Show status and take typed questions | `UI/Island.cs`, `UI/Overlay.cs`, `UI/SettingsWindow.cs` | WPF |

## Development

```powershell
# One request through the real provider and parser:
Jarvis.exe --ask "Say hi" --provider gemini
Jarvis.exe --ask "Where is Export?" --image shot.jpg --model haiku
# Run an action, or just report which app a name would open:
Jarvis.exe --act "[OPEN_APP:Calculator]"
Jarvis.exe --find-app "chat GPT"
# Save a Gemini key from stdin:
Jarvis.exe --save-gemini-key
# Play through every island state and the pointer's flight:
Jarvis.exe --demo
# Check what can be checked with nobody at the PC, and write a report:
Jarvis.exe --self-test report.txt
```

Jarvis logs stage names and failure types to `%LOCALAPPDATA%\Jarvis\jarvis.log`, and never what was said or what was on screen.

CI builds the installer on every push and runs the self-test on a Windows desktop, using `.github/workflows/windows.yml`. It can't test a microphone, speakers or a person holding a key, so those need a real PC.
