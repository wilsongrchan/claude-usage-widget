Claude Usage — How to Install
=============================

A desktop widget that shows your Claude plan usage live: your 5-hour session
limit, your weekly limit, how you're pacing, and alerts before you run out.

This is an unofficial app. It is not made by, affiliated with, or endorsed by
Anthropic.


WHAT YOU NEED
-------------
- A Mac running macOS 26 (Tahoe) or later. Apple Silicon and Intel both work.
- Claude Code installed and logged in to your Claude account.
  The widget reads your usage using that login, so if you haven't set up
  Claude Code yet, do that first: https://claude.com/claude-code


INSTALL
-------
1. Drag "ClaudeUsage.app" into your Applications folder, then open it.
   macOS says Apple could not verify it. Click "Done".

2. Open System Settings → Privacy & Security, scroll down and click
   "Open Anyway" next to the ClaudeUsage message.

3. Click "Open Anyway" again and enter your password or use Touch ID.
   You only do this once.

4. The welcome window walks you through the rest:
   - Connect to Claude Code. macOS asks whether "security" may use
     "Claude Code-credentials" in your keychain. That's how the app reads
     your Claude Code login. It never leaves your Mac except to ask
     Anthropic for your usage.
     "Always Allow" stops macOS asking again, but it also lets other
     software on this Mac read that login through the same system tool.
     "Allow" asks again each time the app re-reads the login (at launch,
     and when Claude Code renews its login).
   - Notifications, so your usage alerts can reach you.
   - Open at Login, to start it whenever you log in (also in Settings).

The widget appears on your desktop. Drag it where you like. It snaps to the
same grid as your other desktop widgets.

Prefer Terminal for steps 1 to 3? After dragging the app into Applications:
   xattr -dr com.apple.quarantine /Applications/ClaudeUsage.app
then open it normally.

Or install and update in one line, without the warning at all:
   curl -fsSL https://raw.githubusercontent.com/wilsongrchan/claude-usage-widget/main/install.sh | bash


USING IT
--------
- Left ring: your 5-hour session limit. Right ring: your weekly limit.
- White tick: where you'd be if you spread your usage evenly. If the
  coloured arc is past the tick, you're using it faster than even pace.
- Buttons in the top right: refresh, pace marker, segmented rings, the two
  other sizes (small, medium, large), and settings. Hover over a button to
  see its name.
- Settings has Appearance (theme, size, resize direction, weekly split), Alerts (choose
  when to be notified), Data (today's usage by hour), and About.
- The small orange ring in your menu bar shows session usage at a glance.
  Click it to see the full widget.


TROUBLESHOOTING
---------------
- "Claude Code not found": install Claude Code and log in, then click
  refresh in the widget.
- "Keychain access denied": you clicked Deny on the Keychain prompt.
  Click refresh in the widget and choose "Allow" or "Always Allow".
- "Login expired": open Claude Code and use it once. That refreshes the
  login, and the widget picks it up automatically.
- "Updates paused · retrying…": Anthropic asked the widget to slow down
  for a moment. It keeps showing your last numbers and retries by itself.
- No notifications: System Settings → Notifications → ClaudeUsage →
  turn on "Allow notifications".


UNINSTALL
---------
1. Quit it: the X on the widget → Quit Claude Usage (or the gear →
   About → Quit). Turn off Open at Login first if you had it on.
2. Drag ClaudeUsage.app from Applications to the Trash.
3. Optional, to remove its settings too, run in Terminal:
   defaults delete local.claude-usage-widget


PRIVACY
-------
There's no account, no server, no analytics and no tracking. Your Claude
Code login is used only to ask Anthropic's API for your usage, and is never
saved or sent anywhere else. Your settings and usage history stay on your
Mac.

Usage figures come from an unofficial Anthropic endpoint that could change
or stop working at any time. The app is provided as is, without warranty.
