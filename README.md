# mpv-playlist-panel

<img width="988" height="601" alt="image" src="https://github.com/user-attachments/assets/3eaeb3cd-d773-4088-b638-fcf510edc061" />

# playlist-panel.lua

A thumbnail playlist panel for mpv with watched tracking.

## Features

- **Thumbnail previews** — generated via ffmpeg, cached per session
- **Watched tracking** — ✓ marker and dimmed thumbnail, persisted across sessions
- **Scrolling titles** — long names marquee-scroll on the focused row
- **Duration display** — fetched in the background via ffprobe
- **Panel width cycling** — 3 sizes, toggle with `c`
- **Adaptive resize** — debounced redraw on window resize

## Requirements

- [mpv](https://mpv.io)
- [ffmpeg](https://ffmpeg.org) — `ffmpeg` and `ffprobe` must be in PATH (same install)

Everything else (Lua, the `mp` library, ASS rendering, overlay system) is built into mpv itself.

## Installation

```
~/.config/mpv/
├── scripts/
│   └── playlist-panel.lua
└── playlist-panel.conf   ← optional config
```

> **Windows:** replace `~/.config/mpv/` with `%APPDATA%\mpv\`

ffmpeg is available via ffmpeg.org or any package manager:
```
brew install ffmpeg
winget install ffmpeg
apt install ffmpeg
```

## Usage

```
Tab        toggle panel
↑ / ↓      navigate
Enter      play selected
c          cycle panel width
```
