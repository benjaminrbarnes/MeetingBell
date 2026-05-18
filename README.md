# MeetingBell

MeetingBell is a small macOS menu bar app for people who miss meetings because normal calendar notifications are too easy to ignore.

It reads your local macOS Calendar events, shows a countdown to the next meeting in the menu bar, changes color as the meeting gets close, and can ding repeatedly once the meeting starts until you acknowledge it.

## What It Does

- Menu bar countdown to your next busy, non-all-day Calendar event.
- Light blue background when a meeting is within 5 minutes.
- Yellow background when a meeting is within 2 minutes.
- Red background once the meeting has started.
- Optional `Play Sound Until Silenced` setting; while ringing, the menu only shows `Silence Meeting`.
- Meetings already in progress when MeetingBell opens are skipped so the menu bar shows the next meeting instead.
- `Join Meeting` action when MeetingBell finds a Zoom, Google Meet, Teams, Chime, Webex, or BlueJeans link.
- `Launch at Login` option so it starts automatically.
- Optional `Show Time Only` mode to hide meeting titles from the menu bar.
- Local-only Calendar access through macOS EventKit.

## Getting Set Up

Requirements:

- macOS 14 Sonoma or newer.
- Apple Silicon Mac for the downloadable release zip.

1. Go to the repo's GitHub Releases page.
2. Download the latest `MeetingBell-<version>-macOS.zip`.
3. Unzip the download.
4. Drag `MeetingBell.app` into `/Applications`.
5. Open `MeetingBell.app`.
6. Grant Calendar access when macOS asks.
7. Open the menu bar dropdown and enable `Launch at Login` if you want MeetingBell to start automatically.

Because this app is not signed or notarized with an Apple Developer ID yet, macOS may block the first launch. If that happens, right-click `MeetingBell.app`, choose `Open`, then confirm that you want to open it. You should only need to do that once.

If Calendar access does not appear, open `System Settings > Privacy & Security > Calendars` and make sure MeetingBell is allowed.

The downloadable zip is currently built on Apple Silicon. Intel Macs can build from source, but a universal release build requires a full Xcode install.

## For Developers

### Build

Requires macOS with Swift command line tools installed.

```sh
./scripts/build-app.sh
```

The build script quits any running copy and relaunches the rebuilt app. To skip relaunching during development:

```sh
MEETINGBELL_RELAUNCH=0 ./scripts/build-app.sh
```

Local builds include a development-only `Testing` section in the dropdown. It can create a busy test meeting one minute in the future. To build locally without that menu:

```sh
MEETINGBELL_DEVELOPMENT_MODE=0 ./scripts/build-app.sh
```

### Package A Release

Build a distributable zip:

```sh
./scripts/package-release.sh 0.1.0
```

That creates:

```sh
release/MeetingBell-0.1.0-macOS.zip
```

Upload that zip to a GitHub Release. Teammates can download it, unzip it, and drag `MeetingBell.app` into `/Applications`.

Release packages disable the development-only testing menu automatically.

For the smoothest install experience, the app should eventually be signed with an Apple Developer ID certificate and notarized. Without that, users can still run it, but they may need to right-click and choose `Open` the first time.

Current release target:

- macOS 14 or newer.
- Apple Silicon binary.
- Tested on macOS 26.4.1.

### Run

Double-click `MeetingBell.app` in this folder.

On first launch, macOS should ask for Calendar access. MeetingBell runs only in the menu bar.

## Notes

- MeetingBell only reads calendars available to the macOS Calendar system.
- Acknowledging a ringing meeting hides that meeting and immediately shows the next eligible meeting.
- `Launch at Login` is path-based. If you move the app, toggle `Launch at Login` off and on again.
