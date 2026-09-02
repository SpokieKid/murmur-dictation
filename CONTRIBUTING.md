# Contributing to Murmur

Thanks for helping improve Murmur. Bug reports, focused feature proposals,
documentation fixes, translations, and pull requests are welcome.

## Development setup

1. Use macOS 13 or later with Xcode and the Swift 6 toolchain installed.
2. Fork and clone the repository.
3. Run `swift test`.
4. Build the app with `SIGN_IDENTITY=- ./build.sh release`.
5. Open `build/Murmur.app` and grant the requested macOS permissions.

Never commit API keys, transcripts, recordings, signing certificates, or other
personal data. Use your own credentials only in the app's Settings window.

## Pull requests

- Keep each pull request focused on one change.
- Add or update tests when behavior changes.
- Run `swift test` and `swift build -c release -Xswiftc -warnings-as-errors`.
- Update both English and Simplified Chinese localizations for user-facing text.
- Explain privacy or permission changes clearly in the pull request.

By contributing, you agree that your contribution is licensed under the MIT License.
