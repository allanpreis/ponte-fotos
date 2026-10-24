# Security policy

## Supported versions

Security fixes target the latest published release. Earlier releases do not have a separate maintenance branch. Update before reproducing a suspected issue.

## Report a vulnerability privately

Do not disclose vulnerabilities, API keys, private server addresses, photos, GPS coordinates or account data in a public issue.

Use **Security → Report a vulnerability** on this repository when available. Include the affected version, a minimal reproduction using synthetic data, the expected security boundary and the potential impact. Do not test against another person's library or server.

If private reporting is unavailable, open an issue asking only for a private security contact, without vulnerability details or personal data. Wait for a private channel before sharing details. No response deadline is guaranteed.

## Security boundaries

- API credentials are stored in macOS Keychain when saved by the user.
- Local histories and exported media can contain personal metadata; redact them before sharing.
- Prefer HTTPS, especially outside a trusted local network. HTTP does not encrypt keys or media in transit.
- Releases currently use ad hoc signing, without Apple Developer ID signing or notarization.
- A successful build does not validate real Photos permissions, server operations or media fidelity.

## Português (Brasil)

Relate vulnerabilidades pelo botão **Security → Report a vulnerability**, quando disponível. Não publique chaves, fotos, GPS, endereços privados ou detalhes exploráveis em issues. Se o canal privado não estiver disponível, peça um contato privado em uma issue sem incluir os detalhes. Correções de segurança são direcionadas à versão publicada mais recente.
