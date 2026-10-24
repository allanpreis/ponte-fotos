# Contributing to Ponte Fotos
Contributions in English and Português (Brasil) are welcome: bug reports, documentation, translations, accessibility improvements and focused code changes.
## Report a bug or suggest a feature
Search existing issues first. Include the app version, macOS version, Mac architecture, Immich version, steps to reproduce, expected behavior and actual result. For media issues, include the format and use a synthetic or explicitly shareable sample. Explain the problem a feature would solve.
Never publish API keys, private server URLs, account identifiers, personal photos, GPS coordinates or unredacted histories and logs.
## Build locally
The current build targets Apple Silicon and macOS 14 or later. Install Xcode Command Line Tools, then run from the repository root:
```sh
zsh build.sh
```
The output is `build/Ponte Fotos.app`, signed locally with an ad hoc signature. Developer ID signing and notarization are not currently provided. See [README](README.md) or [Português (Brasil)](README.pt-BR.md) for installation and compatibility limits.
## Submit a pull request
1. Discuss substantial changes in an issue before implementing them.
2. Create a branch and keep the change focused. Avoid unrelated refactors and new dependencies unless discussed.
3. Build the app and describe the validation actually performed, including any checks you could not run. Add regression coverage where the change needs it.
4. Use synthetic media and a dedicated test library/account for transfer or library-management checks. Never run destructive checks against a personal library.
5. Update both READMEs and the English/Brazilian Portuguese interface strings when relevant. Include screenshots for interface changes.
6. Explain the problem, resulting behavior, validation and known limitations in the pull request.
Preserve original media, explicit confirmation for library changes, checksum verification and honest pending/error states. Do not claim PhotoKit, HDR, Live Photo or server compatibility based only on a successful build.
## Project and licensing status
Ponte Fotos is independent and is not affiliated with Apple or Immich. A redistribution license has not yet been selected; this guide does not grant additional licensing rights. Licensing terms should be clarified with the maintainer before submitting substantial code contributions.
## Em português
Você pode abrir issues e pull requests em português. Informe versões e passos para reproduzir, use amostras sintéticas e remova dados pessoais. Para mudanças no código, faça uma alteração pequena, compile com `zsh build.sh` e descreva exatamente o que foi validado.
