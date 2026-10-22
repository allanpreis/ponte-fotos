# 📦 Publicação de versões

Preferência do mantenedor: **toda nova versão do Ponte Fotos deve ter commit no repositório e uma GitHub Release correspondente**. Não entregar apenas o commit. Cada release deve permitir instalar a versão e entender suas mudanças e limitações.

## Preparar

1. Defina a versão `X.Y.Z` e atualize `CFBundleShortVersionString`, `CFBundleVersion`, referências da interface, README, guia e changelog conforme a mudança.
2. Escreva `docs/releases/vX.Y.Z.md` em português, com mudanças concretas, recursos acumulados relevantes, instalação, limites, evidências de validação e links. Use emojis com moderação e screenshots legíveis.
3. Atualize os prints quando o visual mudar. Use dados sintéticos; nunca publique fotos privadas, chaves, SSID doméstico, URLs reais do ambiente ou caminhos pessoais. Atualize o vídeo quando a mudança exigir.
4. Confira os arquivos staged e os assets, além do `.gitignore`. Não inclua `.env`, perfis, Chaves, históricos, staging, builds de teste nem a pasta privada que contém o projeto.

## Validar e empacotar

Execute os testes pertinentes à mudança e as verificações de build, plist e assinatura. Para uma distribuição cumulativa, execute:

```sh
zsh build.sh
zsh test-connection.sh
zsh test-management.sh
zsh test-media.sh
zsh test-appearance.sh
plutil -lint Info.plist
codesign --verify --deep --strict "build/Ponte Fotos.app"
```

Registre resultados reais e limites de QA. Não descreva testes contra Immich real quando apenas fixtures foram usadas. Quando o servidor estiver em manutenção, documente isso.

Produza um ZIP limpo contendo o app de produção, sem dados locais, e gere o checksum do arquivo final:

```sh
ditto -c -k --sequesterRsrc --keepParent "build/Ponte Fotos.app" "Ponte-Fotos-X.Y.Z-arm64.zip"
shasum -a 256 "Ponte-Fotos-X.Y.Z-arm64.zip" > SHA256SUMS.txt
```

Verifique o ZIP extraído, sua versão e assinatura. O app é arm64 para macOS 14+, com assinatura ad hoc e sem notarização; mantenha isso claro na release. Se a forma de distribuição mudar, atualize estas instruções.

## Publicar

1. Faça o commit dos arquivos revisados e publique na `main`.
2. Crie a tag **`vX.Y.Z` apontando para o commit publicado** e a GitHub Release correspondente.
3. Use `docs/releases/vX.Y.Z.md` como corpo da release. Links e imagens nele devem ser absolutos para funcionar fora da árvore do repositório.
4. Anexe o ZIP e `SHA256SUMS.txt`. Confira que os nomes e o hash correspondem ao pacote final.
5. Abra a release publicada, confira texto, imagens, links e arquivos. Faça o download público e compare o SHA-256; confirme que a tag resolve para o commit correto.
6. Atualize a memória de continuidade com versão, commit/tag, URL pública, validação e pendências, sem segredos.

Não reutilize uma tag já publicada para uma versão diferente. Corrija um pacote com nova versão e release; preserve o histórico de mudanças. Não anuncie atualizador automático, notarização ou suporte Intel enquanto não forem implementados e validados.

[⬅️ Guia completo](GUIA-COMPLETO.md) · [📝 Changelog](../CHANGELOG.md)
