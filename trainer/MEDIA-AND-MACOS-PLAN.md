# BC250 Trainer Media Deck And macOS Test Harness Plan

## Status

Planning decisions were confirmed on July 30, 2026. The media controller, media
deck, waveform, generated-WAV tests, local macOS harness, and macOS checks are
implemented. The complete Homebrew harness passed on macOS with Qt 6.11.1 on
July 30, 2026. Existing release-workflow and asset-license changes were
preserved during implementation.

## Goals

1. Provide a repeatable native macOS build and test harness for mock-mode
   frontend development.
2. Add a macOS GitHub Actions check without changing Linux release authority.
3. Move all soundtrack controls from the right control deck and Setup page to a
   collapsible lower-left media deck.
4. Add play/pause, previous, next, current-track display, a selectable music
   directory, a track list, volume, and mute controls.
5. Add a synchronized waveform and dedicated beat-energy visualizer that remain
   compatible with Qt 6.4.

## Confirmed Decisions

- Add both a local Homebrew-based macOS script and a macOS CI workflow.
- Keep Ubuntu and SteamOS authoritative for releases, system-service behavior,
  and hardware integration.
- Let the user select a music directory and persist that selection.
- Scan only the selected directory, not its subdirectories.
- Default to the packaged `trainer/tracks` directory; selected empty folders
  remain empty.
- Display a synchronized waveform rather than a frequency spectrum or simple
  level meter.
- Place the player in a collapsible translucent lower-left deck.
- Use generated WAV data for native macOS media tests. Do not add another copy
  of the bundled soundtrack solely for macOS.
- Preserve the Qt 6.4 minimum version.

## Current Constraints

- The frontend C++ code is portable Qt, but the real service requires Linux,
  system D-Bus, systemd, polkit, sysfs, and SteamOS tooling.
- The current Mac has Homebrew CMake available outside the default path, while
  the default CMake is older than the required 3.22.
- Ninja and Qt may need to be installed before the native harness can run.
- Apple Bash 3.2 and BSD `stat` cannot run every shared-service lifecycle test.
  The harness must prefer Homebrew Bash and GNU coreutils.
- Native Mac media tests use generated WAV data independently of bundled media.
- The left 47 percent of `Main.qml` is currently one window-drag hit area. The
  media deck must take ownership of its interactive region.
- The previous QML `MediaPlayer` supported one embedded track, started
  automatically, and looped forever.

## Media Architecture

Add a dedicated `MediaController` instead of extending the hardware-oriented
`Bc250Bridge`.

The controller will:

- Own `QMediaPlayer` and `QAudioOutput`.
- Expose track titles, current index, current title, playback state, position,
  duration, mute, volume, selected directory, waveform data, and media errors
  to QML.
- Expose play/pause, previous, next, track selection, directory selection, and
  rescan operations to QML.
- Preserve the existing `audio/volume` setting and clear the legacy `audio/muted` key so each launch starts unmuted.
- Add settings for the selected directory and current track path.
- Auto-start playback to preserve current behavior.
- Advance to the next track at end-of-media and wrap at either end.
- Restart the current track when Previous is pressed after three seconds;
  otherwise select the prior track.
- Keep playback running while muted.
- Report playback failures without making the application unusable.

### Directory Scanning

- Use `QDir`, `QFileInfo`, and `QCollator` in numeric mode.
- Filter case-insensitively for `.oga`, `.ogg`, `.opus`, `.mp3`, `.flac`,
  `.wav`, `.m4a`, and `.aac`.
- Ignore directories, unreadable entries, and unsupported files.
- Display filename stems rather than requiring metadata extraction.
- Preserve the current track by canonical path when rescanning.
- Use `QFileSystemWatcher` with a short debounce to notice additions, removals,
  and renames.
- Resolve the packaged `tracks/` directory in source, staged, and installed
  layouts.

### Waveform Analysis

- Analyze only the selected track with `QAudioDecoder`.
- Convert supported Qt 6.4 PCM sample formats into normalized floating-point
  amplitudes.
- Combine channels and accumulate compact min/max or peak buckets across the
  track.
- Decode asynchronously and update the QML model progressively or once a
  useful envelope is available.
- Render a mirrored whole-track waveform with a playback-position highlight or
  moving playhead.
- Freeze the playhead while paused and continue moving it while muted.
- Show a quiet placeholder when analysis is unavailable or the codec cannot be
  decoded.
- Treat analyzer failures as nonfatal and separate from playback failures.
- Derive a short-window RMS envelope for the dedicated live visualizer and
  synchronize it to playback without requiring post-Qt-6.4 audio-tap APIs.

## Left Media Deck

Add `qml/components/MediaPane.qml`, `qml/components/AudioWaveform.qml`, and
`qml/components/AudioVisualizer.qml`.

The collapsed deck will always show:

- Current track name with plain-text elision.
- Current time and duration.
- Previous, play/pause, and next controls.
- Mute and volume controls.
- The synchronized waveform.
- The dedicated beat-energy visualizer.
- A control to expand the track list.

The expanded deck will:

- Grow upward from the lower-left edge.
- Show the naturally sorted track list and highlight the current track.
- Select and play a track when its row is activated.
- Show an empty-directory state clearly.
- Offer Select Folder and Refresh actions.
- Use the existing cyan/magenta neon language and a dark translucent backing so
  the artwork remains visible.

`Main.qml` changes will:

- Remove the right title-bar sound toggle.
- Remove the inline QML `MediaPlayer` and `AudioOutput`.
- Add the media pane over the lower-left artwork.
- Limit or split the window-drag `MouseArea` so it cannot overlap media controls.
- Retain the `M` mute shortcut and add a play/pause shortcut.
- Keep the fixed-aspect scaling behavior.

`SetupPage.qml` will remove duplicate volume and mute controls after the media
deck owns them.

## macOS Local Harness

Add `trainer/build-macos.sh`.

The script will:

- Require Homebrew but never install packages automatically.
- Detect missing `cmake`, `ninja`, `qt`, `bash`, and `coreutils` formulae and
  print one concise `brew install` command.
- Use `brew --prefix` so Intel and Apple Silicon paths both work.
- Resolve Homebrew CMake, Ninja, Qt, Bash, and GNU coreutils explicitly.
- Put Homebrew Bash and `coreutils/libexec/gnubin` first on `PATH`.
- Configure `trainer/build-macos/` with Ninja, Debug mode, and
  `BUILD_TESTING=ON`.
- Set `CMAKE_PREFIX_PATH` to the Homebrew Qt prefix.
- Build the frontend and the native tests.
- Run the `qml-lint` target.
- Run Qt CTest tests with offscreen rendering and the mock media backend where
  appropriate.
- Run the executable mock smoke test.
- Run backend, service, release, and QML utility tests from the repository root.
- Set `PYTHONDONTWRITEBYTECODE=1` to keep the worktree clean.
- Fail clearly when expected Qt test tools or test registrations are missing.
- Offer an interactive mock run mode only if it does not complicate the default
  full-verification path.

The build directory already matches `trainer/build-*` in `.gitignore`.

## macOS CI

Add `.github/workflows/trainer-checks.yml`.

The workflow will:

- Run on pushes to `trainer` and relevant pull requests.
- Restrict path triggers to BC250 Trainer, shared service/backend code, staging code,
  relevant tests, and the workflow itself.
- Use `macos-latest` and `actions/checkout`.
- Install the Homebrew dependencies required by `build-macos.sh`.
- Invoke the same local harness rather than duplicating test commands.
- Use read-only repository permissions.
- Never create tags, upload releases, or alter the main release timeline.

## Native Tests

Add focused `MediaController` tests using temporary directories and generated
PCM WAV files.

Coverage will include:

- Supported-extension filtering.
- Case-insensitive natural filename ordering.
- Empty-directory state and packaged default directory.
- Current-track preservation after rescanning.
- Current-track deletion behavior.
- Previous restart and wrap behavior.
- Next and end-of-media wrap behavior.
- Volume clamping and persisted setting keys.
- PCM conversion for Qt 6.4 sample formats.
- Deterministic waveform bucket calculations using known sample values.
- Decoder or backend failure remaining nonfatal.

## QML Tests

Use a fake media-controller object to test the UI independently from an audio
device or multimedia backend.

Coverage will include:

- Collapsed and expanded panel geometry.
- Play/pause text and action routing.
- Previous and next action routing.
- Current-track text and row highlighting.
- Track selection.
- Folder-selection and refresh actions.
- Empty and bundled-directory states.
- Waveform quiet, active, paused, and muted states.
- Visualizer active, paused, muted, and unavailable states.
- Media controls not initiating a window drag.

## Expected File Changes

- Add `trainer/src/MediaController.h`.
- Add `trainer/src/MediaController.cpp`.
- Add `trainer/qml/components/MediaPane.qml`.
- Add `trainer/qml/components/AudioWaveform.qml`.
- Add `trainer/qml/components/AudioVisualizer.qml`.
- Add native media-controller tests under `trainer/tests/`.
- Add QML media-pane tests under `trainer/tests/qml/`.
- Add `trainer/build-macos.sh`.
- Add `.github/workflows/trainer-checks.yml`.
- Update `trainer/src/main.cpp`.
- Update `trainer/qml/Main.qml`.
- Update `trainer/qml/pages/SetupPage.qml`.
- Update `trainer/CMakeLists.txt`.
- Update `trainer/resources.qrc`.
- Update `trainer/README.md` and the root `README.md`.
- Update `trainer/PLAN.md` where the old unobstructed-left-artwork requirement
  conflicts with the confirmed media-deck design.

Update the installer and runtime stager to place the bundled MP3 files in a
`tracks/` directory beside the executable while external music remains in the
user-selected directory.

## Implementation Order

1. Implement and unit-test directory scanning, track state, and navigation.
2. Add player ownership, settings, and error handling to `MediaController`.
3. Add asynchronous waveform decoding and deterministic PCM tests.
4. Expose the controller from `main.cpp` and remove QML player ownership.
5. Build and test the waveform and media-pane QML components.
6. Integrate the lower-left deck and reshape the window-drag area.
7. Remove duplicate right-side and Setup-page audio controls.
8. Add the Homebrew-aware macOS script.
9. Add the macOS GitHub Actions check.
10. Update documentation and run all available validation.

## Acceptance Criteria

- The application builds against Qt 6.4 and newer.
- Linux release behavior and the independent BC250 Trainer release workflow remain
  intact.
- A selected directory is remembered and rescanned without recursion.
- Supported files appear in deterministic natural order.
- The packaged MP3 directory is the first-run default and empty selected
  directories remain empty.
- Play/pause, previous, next, mute, volume, and direct track selection work.
- The current track and playback timing are visible in the left deck.
- The waveform visibly follows playback position and freezes while paused.
- The dedicated visualizer responds to short-window energy and beat transients,
  stays synchronized while playing, and freezes while paused.
- Expanding the track list does not move or resize the right control deck.
- Media controls never trigger window dragging.
- The Mac harness builds and runs mock/frontend tests using Homebrew tools.
- Mac CI invokes the same harness and never publishes artifacts or releases.
- Generated WAV fixtures validate native media behavior independently from the
  bundled MP3 files.
- Ubuntu and SteamOS remain the required environments for final D-Bus,
  system-service, and hardware validation.
