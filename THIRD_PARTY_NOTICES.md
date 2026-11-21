# Third-party software notices

## Trafilatura Dart 1.0.1

- Repository: https://github.com/kamranxdev/trafilatura
- License: Apache License 2.0
- Use in Cwhale: on-device HTML content extraction for web search results.
- License text: [third_party_licenses/trafilatura-LICENSE.txt](third_party_licenses/trafilatura-LICENSE.txt)

The Trafilatura Dart source is used as an unmodified package dependency. Search-result discovery and guarded page requests are implemented by Cwhale; extracted page content stays on the phone until the user sends the search-enabled prompt to their configured model provider.

## html 0.15.7

- Repository: https://github.com/dart-lang/tools/tree/main/pkgs/html
- License: BSD 3-Clause
- Use in Cwhale: parse the DuckDuckGo HTML search results into links and snippets.
- License text: [third_party_licenses/html-LICENSE.txt](third_party_licenses/html-LICENSE.txt)

## Agent-Reach (implementation reference)

- Repository: https://github.com/Panniantong/Agent-Reach
- License: MIT
- Use in Cwhale: reviewed its web channel to identify the Exa hosted MCP search/read endpoint and tool protocol.
- Cwhale does not bundle Agent-Reach's Python CLI or its source files. Search integration is implemented natively in Dart and connects directly from the phone to Exa's hosted MCP.

## Humanizer skill

- Repository: https://github.com/blader/humanizer
- Bundled skill version: 4.0.0
- License: MIT
- Use in Cwhale: optional, user-activated writing guidance in the chat composer.
- Skill source: [assets/skills/humanizer/SKILL.md](assets/skills/humanizer/SKILL.md)
- License text: [third_party_licenses/humanizer-LICENSE.txt](third_party_licenses/humanizer-LICENSE.txt)

The skill text is bundled with Cwhale but loaded into a model request only when the user turns on “说人话” for the next message. When the option is off, the skill prompt is omitted.
