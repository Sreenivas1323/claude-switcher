# Security

Claude Switcher handles OAuth tokens for your Claude accounts. They are stored only in your
login keychain (service `ClaudeSwitcher`) and are sent only to Anthropic
(`api.anthropic.com`, `platform.claude.com`).

If you find a way tokens could leak or be misused, please **don't open a public issue**.
Report it privately through GitHub's
[security advisory form](https://github.com/Sreenivas1323/claude-switcher/security/advisories/new).
