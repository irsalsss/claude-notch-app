# ClaudeNotch

ClaudeNotch is a small macOS app that shows Claude Code status around the MacBook notch. It shows the usage of each claude-swap account. It also shows which Claude Code sessions are working.

claude-swap is a command-line tool that runs Claude Code with more than one account. ClaudeNotch reads the data of claude-swap. It does not change that data.

## What the app shows

The app has two states. The collapsed state is a black strip around the notch. When you move the pointer over the notch, the expanded state opens. When you move the pointer away, it closes.

The collapsed state shows these items:

- The Claude mark, on the left of the notch. If no session is working, the mark does not move.
- A number next to the mark. If one or more sessions are working, the mark turns and the number shows the count of working sessions.
- One small bar for each account, on the right of the notch. Each bar shows the 5-hour usage of that account.
- The 5-hour usage of the default account, as a percentage next to the bars.

The default account is the account that a plain `claude` command uses. claude-swap keeps the credentials of this account in `~/.claude`. A terminal tab that you start with `claude-swap run N` uses account `N` instead.

The expanded state shows a list of the working sessions. For each session, the list shows the session name, the folder, and the account number. Below the list, a card for each account shows the 5-hour limit, the 7-day limit, and the time until each limit resets.

If you turn on Reduce Motion in System Settings, the mark does not turn. A glow around the mark then shows that a session is working.

## Requirements

You must have these items before you install the app:

- A Mac with macOS 15 or later. A MacBook with a notch gives the best result. On other screens, the app uses a strip with the height of the menu bar.
- The Command Line Tools for Xcode 16 or later. The build script uses the `swiftc` compiler from these tools.
- claude-swap at the path `~/.local/bin/claude-swap`. The app reads claude-swap only from this path.

## Install

1. Install the Command Line Tools for Xcode. If the tools are already on your Mac, skip this step.

   ```bash
   xcode-select --install
   ```

2. Install claude-swap. Follow the steps in the [claude-swap repository](https://github.com/realiti4/claude-swap).

3. Make sure that claude-swap is at the expected path. If the file exists, the command prints the path.

   ```bash
   ls ~/.local/bin/claude-swap
   ```

4. Clone this repository into a folder of your choice, and go into that folder.

   ```bash
   git clone git@github.com:irsalsss/claude-notch-app.git
   cd claude-notch-app
   ```

5. Build the app and start it.

   ```bash
   ./build.sh
   ```

The script compiles `ClaudeNotch.swift` into `~/Applications/ClaudeNotch.app`. Then it signs the app with an ad hoc signature, which is a local signature with no developer account. Then it writes a launch agent to `~/Library/LaunchAgents/com.irsalsss.claude-notch.plist` and loads it.

A launch agent is a job that macOS starts for your user account. When you log in, macOS starts the app. If the app stops, macOS starts it again.

## Update

To update the app, get the new code and run the build script again from the folder of the repository:

```bash
git pull
./build.sh
```

The script stops the running copy of the app and starts the new build. You do not have to log out.

## Uninstall

1. Stop the app and remove the launch agent.

   ```bash
   launchctl bootout "gui/$(id -u)/com.irsalsss.claude-notch"
   rm ~/Library/LaunchAgents/com.irsalsss.claude-notch.plist
   ```

2. Delete the app.

   ```bash
   rm -rf ~/Applications/ClaudeNotch.app
   ```

3. If you do not want the source code, delete the folder of the repository.

## How the app gets its data

The app reads the usage data from claude-swap. It runs `claude-swap list --json` every 60 seconds. It also runs the command each time that the expanded state opens.

The app reads the session activity from files that Claude Code writes. Claude Code writes one file, `sessions/<pid>.json`, for each running session. Each file has a `status` field with the value `busy` or `idle`. The app reads these files every second.

The session files are in two places. Sessions that use the default account are in `~/.claude/sessions`. Sessions that you start with `claude-swap run N` are in `~/.claude-swap-backup/sessions/<N-email>/sessions`.

A session file can stay on the disk after its process stops, for example after a crash. If no process with that process ID exists, the app ignores the file. This rule stops the mark from turning for a session that is gone.

## Privacy

The app does not send data over the network. Only claude-swap makes network requests, to get the usage data. The app does not write files and does not keep a history.

If your account names are private, do not share screenshots of the expanded state. Each account card shows the first part of the account email, or the alias that you set in claude-swap.

## Troubleshooting

Use this table to find the cause of a problem:

| Problem | Cause and fix |
| --- | --- |
| The expanded state shows an error line. | Run `~/.local/bin/claude-swap list --json` in Terminal. The app reads the same output, so Terminal shows the same error. |
| A meter shows `–` in place of a percentage. | claude-swap has no usage data for that limit. Team plans do not report a 7-day limit, so the app does not show that row for them. |
| The mark does not turn while a session works. | Make sure that the session file of that session is in one of the folders in "How the app gets its data". |
| The app does not start after `./build.sh`. | Read the status of the launch agent with `launchctl print "gui/$(id -u)/com.irsalsss.claude-notch"`. |

## License

This project uses the MIT License. The full text is in [LICENSE](LICENSE).
