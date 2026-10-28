# myflix 📺

**myflix** is a native macOS command-line tracking application written in Swift that helps you keep track of the TV shows you watch. By leveraging the [TVmaze API](https://www.tvmaze.com/api), it easily fetches show details, aired episodes, and upcoming airdates without any hassle.

Your personalized tracked show data is saved locally in your home directory at `~/.tvshow_tracker.json`. Set `MYFLIX_TRACKER_FILE` to use a different file.

## Features

- **Personalized Tracking:** Keep a personalized local database of your favorite TV shows.
- **Episode Tracking:** Precisely track what episodes you've watched, formatted beautifully (e.g., `S01E02`).
- **Dashboard:** A zero-argument command that shows all of the unwatched episodes you have left for your tracked shows.
- **Up-to-Date Feature:** Instantly mark a tracked show as fully "up-to-date" up to the latest aired episode.
- **Show Search:** Detailed queries about a show's previous aired episode and its upcoming scheduled episode.
- **Season Explorer:** See all episodes for the current season of a show, highlighting the most recently aired one.

## Requirements

- **macOS** 12.0 or newer
- **Swift** 6.2 or newer

## Installation

Clone the repository and build the executable using the Swift Package Manager:

```bash
git clone https://github.com/yourusername/myflix.git
cd myflix
swift build -c release
```

You can find the built executable in `.build/release/myflix`. Consider creating an alias or moving the executable to your `/usr/local/bin` folder to run it globally.

## Usage

```
myflix [flags] <show name>
```

### Interactive interface

Run `myflix ui` in a terminal to browse your shows. Use the arrow keys (or `j`/`k`) and Enter to open a show. Press `1`, `2`, or `3` for unwatched episodes, upcoming episodes, or all tracked shows; `a` or `/` to search TVmaze and add a show; `r` to refresh; `d` to remove a selected show (with confirmation); `x` to archive a show or restore it from the archive; `v` to switch between active and archived shows; and `q` to quit. Archived shows keep their progress and are hidden from the active lists, including the non-interactive dashboard, list and upcoming commands. The current filter also applies to the archive; press `3` to see all archived shows. The same `1`, `2`, and `3` filters work inside a show: unwatched episodes (including future and undated episodes), episodes coming in the next 7 days, and all episodes. Upcoming episodes have a different color and a clock symbol; episodes without an air date have a question mark. In a show, select an aired episode and press `m` to mark it and all preceding episodes as watched, or press `u` to mark the show up to date. Press `b` or Escape to return.

The interactive interface uses the same local tracker as the commands below. The existing no-argument dashboard and command-line flags remain available.

### Options & Flags

If no arguments are provided to `myflix`, the app will display your **Dashboard**, showing all tracked shows that have unwatched aired episodes.

| Flag | Argument | Description |
| ---- | -------- | ----------- |
| `-l`, `--list` | `<show name>` (optional) | List all tracked shows. If a `<show name>` is provided, it fetches and lists all episodes from its current season. |
| `-a`, `--add` | `<show name>` | Adds a new show to your tracking list. |
| `-u` | `<show name>` | Marks a tracked show as up-to-date (sets watched episode to the latest currently aired episode). |
| `-m` | `<ep>` `<show name>` | Marks a specific episode and all preceding episodes as watched for the given show (e.g., `myflix -w S01E02 "The Boys"`). |
| `-w` | — | Lists upcoming episodes in the next 7 days. |
| `-r` | `<show name>` | Removes a show from your tracking list entirely. |
| `--reset` | `<show name>` | Resets watched progress for a tracked show. |

### Examples

**Search for a show** (shows last and next episode air dates):
```bash
myflix "The Last of Us"
```

**Track a new show**:
```bash
myflix --add "Severance"
```

**Mark an exact episode as watched**:
```bash
myflix -m S01E05 "Severance"
```

**List all episodes of a current season**:
```bash
myflix --list "Silo"
```

**Mark a tracked show as completely up-to-date**:
```bash
myflix -u "The Mandalorian"
```

**Add and mark up to date at the same time**:
```bash
myflix -a -u "Stranger Things"
```

**View your personal dashboard**:
```bash
myflix
```
