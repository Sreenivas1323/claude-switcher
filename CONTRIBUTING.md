# Contributing

Thanks for helping out. Bug reports, fixes and small features are all welcome.

## Setup

macOS 14+ and Swift 5.9+ (Xcode or the Command Line Tools).

```sh
swift build
.build/debug/ClaudeSwitcher --demo        # fake accounts; never touches your keychain or ~/.claude.json
./build-app.sh --install                   # build the .app and run it from ~/Applications
```

`--demo --snapshot out.png [--dark]` renders the menu to a PNG, which is handy for UI changes
and screenshots in PRs.

## Ground rules

- **Never log, print or commit tokens.** Don't paste real `~/.claude.json` content or keychain values into issues.
- **Only touch what's per-account.** Switching must change `claudeAiOauth` in the keychain item and `oauthAccount` in `~/.claude.json`, nothing else.
- **Use screenshots from demo mode**, not your real accounts.
- **Keep PRs small** and explain *why* in the description.

## Reporting bugs

Include your macOS version, `claude --version`, and what the menu showed. If Claude Code
changed how it stores credentials, a note on what changed is the most useful thing you can send.
