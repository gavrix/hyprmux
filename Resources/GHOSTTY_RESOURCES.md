# Bundled Ghostty resources

Hyprmux checks in the runtime data that libghostty needs. This keeps local and
release builds independent of an installed Ghostty or cmux application.

The current files came from the Ghostty 1.3.1 macOS distribution:

- `terminfo/` contains the compiled `ghostty` and `xterm-ghostty` terminal
  descriptions generated from Ghostty's MIT-licensed terminfo source.
- `ghostty/shell-integration/` contains Ghostty's shell integrations. Individual
  files retain their license headers. The Bash and Zsh integrations contain
  GPL-3.0 code derived from Kitty.
- `ghostty/themes/` contains color schemes sourced by Ghostty from
  iTerm2-Color-Schemes under the MIT license.

The corresponding license texts are in `ThirdPartyLicenses/` and are copied
into the application bundle by `scripts/bundle.sh`.
