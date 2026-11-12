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
1. Unzip ClaudeUsage.zip (double-click it).

2. Drag "ClaudeUsage.app" into your Applications folder.

3. Open it the first time like this, because it isn't from the App Store:
   - Right-click (or Control-click) ClaudeUsage.app and choose "Open".
   - Click "Open" in the box that appears.

   If macOS says it "can't be opened" and only offers to cancel or move it
   to the Bin:
   - Open System Settings → Privacy & Security.
   - Scroll down and click "Open Anyway" next to the ClaudeUsage message.
   - Confirm with your password or Touch ID.

4. macOS asks whether "security" can use the "Claude Code-credentials" item
   in your keychain. Click "Always Allow". This is how the widget reads your
   Claude Code login. It never leaves your Mac except to ask Anthropic for
   your usage.

5. The widget appears on your desktop. Drag it where you like. It snaps to
   the same grid as your other desktop widgets.


START IT AUTOMATICALLY AT LOGIN (optional)
-----------------------------------------
System Settings → General → Login Items → click "+" under "Open at Login"
→ choose ClaudeUsage from Applications.


USING IT
--------
- Left ring: your 5-hour session limit. Right ring: your weekly limit.
- White tick: where you'd be if you spread your usage evenly. If the
  coloured arc is past the tick, you're using it faster than even pace.
- Buttons in the top right: refresh, pace marker, segmented rings, size,
  and settings. Hover over a button to see its name.
- Settings has Appearance (theme, size, weekly split), Alerts (choose
  when to be notified), Data (today's usage by hour), and About.
- The small orange ring in your menu bar shows session usage at a glance.
  Click it to see the full widget.


TROUBLESHOOTING
---------------
- "Claude Code login not found": install Claude Code and log in, then
  click refresh in the widget.
- "Login expired": open Claude Code and use it once. That refreshes the
  login, and the widget picks it up automatically.
- "Updates paused · retrying…": Anthropic asked the widget to slow down
  for a moment. It keeps showing your last numbers and retries by itself.
- No notifications: System Settings → Notifications → ClaudeUsage →
  turn on "Allow notifications".


UNINSTALL
---------
1. Click the gear in the widget → About → Quit.
2. Drag ClaudeUsage.app from Applications to the Bin.
3. If you added it to Login Items, remove it there too.


PRIVACY
-------
There's no account, no server, no analytics and no tracking. Your Claude
Code login is used only to ask Anthropic's API for your usage, and is never
saved or sent anywhere else. Your settings and usage history stay on your
Mac.

Usage figures come from an unofficial Anthropic endpoint that could change
or stop working at any time. The app is provided as is, without warranty.
