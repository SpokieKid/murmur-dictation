# Changelog

All notable changes to Murmur are documented here.

## [0.5.0] - 2026-09-02

### Added

- Pinned insertion targets: each dictation remembers the app and text field
  where it began, so users can switch windows while transcription continues.
- Safe fallback to the clipboard when the original field has closed, changed,
  is secure, or cannot accept background insertion.
- Independent ordered delivery per input target, allowing jobs for separate
  windows to finish without blocking one another.

### Changed

- Added a General setting for switching between pinned-target delivery and the
  previous paste-at-current-focus behavior.
- Corrected the computer-audio switch alignment in the Xiaohongshu demo.

## [0.4.0] - 2026-09-02

### Added

- Runtime-selectable English and Simplified Chinese interface.
- Menu-bar shortcut for including or excluding computer audio.
- Computer-audio capture and microphone mixing for online meetings.
- Parallel dictation jobs with ordered delivery and a stacked progress HUD.

### Changed

- Reworded computer-audio controls to emphasize intentional capture rather than monitoring.
- Prepared a credential-free, MIT-licensed open-source distribution.
