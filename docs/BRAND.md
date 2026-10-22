# 🌸 Identidade do Ponte Fotos

A logo oficial do Ponte Fotos é a **imagem gerada escolhida pelo usuário**, com pétalas coloridas e uma ponte branca sobre um ícone claro. Ela reúne a ideia de biblioteca fotográfica com a conexão entre o Fotos da Apple, pastas e o Immich. Não é um logotipo oficial da Apple ou do Immich.

`Assets/AppLogo.png` preserva a imagem anexada e aprovada, sem redesenho. O vídeo usa uma cópia idêntica em `promo/assets/logo.png`. A partir da 0.8.2, `AppLogoDisplay.png` e `AppIcon.icns` são exportações com enquadramento para o macOS: removem a margem transparente externa e usam base opaca, evitando que o sistema reduza o desenho dentro de outra placa. O ícone tem resoluções de 16 a 1024 pixels. A interface decodifica o bitmap de alta resolução e informa seu tamanho em pontos; o app deixa o sistema carregar o ICNS do pacote.

Para regenerar esses recursos, execute `swift tools/export-icons.swift` na raiz, depois `zsh build.sh`. Requer as ferramentas de linha de comando da Apple, AppKit e `iconutil`; não instala dependências. O enquadramento é específico da arte aprovada atual.

O desenho vetorial simplificado usado na versão0.8.0 foi substituído. Mudanças futuras na identidade devem preservar esta arte aprovada, salvo novo pedido do usuário.

O logo do Immich aparece somente para identificar o destino na apresentação. Seu arquivo foi obtido do [repositório oficial](https://github.com/immich-app/immich/blob/main/design/immich-logo.svg), sem alterações no desenho; atribuição e licença acompanham a composição em `promo/assets/`. O projeto Ponte Fotos é independente e não representa endosso de terceiros.
