<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/header-dark.svg">
  <img src="docs/images/header-light.svg" width="840" alt="Claude Usage: a Liquid Glass desktop widget for macOS that shows your Claude plan limits live: how much of your 5-hour session and weekly limit you've used, whether you're on pace, and when you'll run out.">
</picture>

<a href="../../releases/latest/download/ClaudeUsage.zip"><b>⬇︎ Download ClaudeUsage.zip</b></a> &nbsp;·&nbsp; macOS 26+ &nbsp;·&nbsp; Apple Silicon &amp; Intel

> **Unofficial.** This app is not made by, affiliated with, or endorsed by Anthropic.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/overview-dark.png">
    <img src="docs/images/overview-light.png" width="860" alt="Medium, small, monochrome and large widgets with callouts: ring slices, pace marker, pace note, saved resets, run-out forecast">
  </picture>
</p>

## Features

<img src="docs/images/desktop-menubar.png" width="136" align="right" alt="Medium widget alongside native macOS widgets, and the menu bar gauge with its popover">

- **Run-out forecast.** When you're ahead of pace, it estimates when you'll hit the limit, for example "Runs out 4:10 PM" or "Runs out Tue 18:00", following your Mac's 12/24-hour setting.
- **Weekly budgeting.** Split the weekly ring into 7 even days, 5 weekdays, or your own percentage for each day (say, more on Monday and less on the weekend). The pace marker follows your plan.
- **Alerts you set yourself.** Notifications at 80% and 95% by default, set separately for session, weekly and model limits. Add as many thresholds as you like.
- **Today by the hour.** A spark-shaped chart of which hours of today you used Claude most, plus a weekly split by app (Claude Code vs. chat).
- **Menu bar gauge.** A tiny ring and percentage in the menu bar. Click it for the full widget.
- **Three sizes.** Small (1 slot), medium (2×1, landscape) and large (2×2). Switching sizes animates smoothly, and you choose which way it grows and shrinks.
- **Feels native.** Liquid Glass, light and dark themes, the same rounded corners as macOS widgets, and a translucent monochrome look while you're in other apps. It snaps to the same grid as your desktop widgets and keeps out of their way.

<br clear="right">

## Install

**You need:** macOS 26 (Tahoe) or later, and [Claude Code](https://claude.com/claude-code) installed and logged in. The widget reads your usage with that login, so there's nothing else to set up.

1. **[Download ClaudeUsage.zip](../../releases/latest/download/ClaudeUsage.zip)** and double-click it to unzip.
2. Drag **ClaudeUsage.app** into your **Applications** folder.
3. **Open it the first time** by right-clicking (or Control-clicking) the app and choosing **Open**, then **Open** again.
   If macOS only offers "Move to Bin", go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.
   *(This happens because the app isn't distributed through the App Store.)*
4. When macOS asks to use **"Claude Code-credentials"** from your keychain, click **Always Allow**.
5. The widget appears on your desktop. Drag it anywhere and it snaps into place.

**Start at login (optional):** System Settings → General → Login Items → **+** → choose ClaudeUsage.

## Buttons

Hover over the widget to show its buttons (top right). Hover over a button to see its name.

| | |
|---|---|
| **↻** | Refresh now |
| **Ring icons** | Show or hide the pace marker; switch between segmented and solid rings |
| **Size buttons** | Switch to either of the other two sizes |
| **Gear** | Settings |

Click the **saved-reset chip** at the bottom to edit your saved resets.

## Customize

Click the **gear** to open Settings. You can change:

- **Look:** theme, size, which way it resizes, full color or monochrome, and segmented or solid rings
- **Weekly budget:** 7 even days, weekdays only, or your own percentage per day
- **Alerts:** your own thresholds for session, weekly and model limits, plus saved-reset reminders
- **Extras:** pace marker, Fable usage bar, menu bar gauge, and floating above windows

<p align="center">
  <img src="docs/images/settings-appearance.png" width="200" alt="Appearance settings">
  <img src="docs/images/settings-alerts.png" width="200" alt="Alert settings">
  <img src="docs/images/settings-data.png" width="200" alt="Today by the hour">
</p>

## Privacy

There's no account, no server, no analytics and no tracking. The app reads your existing Claude Code login from the macOS Keychain and uses it **only** to ask Anthropic's own API (`api.anthropic.com`) for your usage. The token is never saved, logged or sent anywhere else. Settings and usage history stay on your Mac.

## Troubleshooting

| Message | Fix |
|---|---|
| *Claude Code login not found* | Install Claude Code and log in, then press ↻ |
| *Login expired* | Use Claude Code once to refresh the login; the widget picks it up automatically |
| *Updates paused · retrying…* | Anthropic's usage API asked the widget to slow down. Your last numbers stay on screen and it retries on its own |
| No notifications | System Settings → Notifications → ClaudeUsage → allow |

## Build from source

Requires the Xcode Command Line Tools (`xcode-select --install`).

```sh
./build.sh            # build into ./build
./build.sh install    # build, install to ~/Applications, start at login
./build.sh dist       # universal build + zip with install guide in ./dist
```

## License

[MIT](LICENSE): free to use, modify and share, with no warranty.

## Disclaimer

Usage figures come from an undocumented Anthropic endpoint that may change or stop working at any time; forecasts are estimates. Check **Settings → Usage** on claude.ai for official figures.
Provided "as is", without warranty of any kind. "Claude" and "Anthropic" are trademarks of Anthropic, PBC.
