# Vídeo de apresentação

Composição original de 36 segundos, silenciosa, em português, 1920×1080 a 30 fps. Renderizada com HyperFrames 0.8.158 e GSAP 3.14.2. As paisagens e diagramas são sintéticos; não há dados ou fotos da biblioteca de um usuário.

O filme apresenta envio, revisão de metadados, duplicatas com Live/estática e seleção automática de conexão. Os diagramas ilustram o funcionamento; não são gravações da interface. A referência de ritmo foi o vídeo público do projeto [iCloudImmichCleanSync](https://github.com/miltos211/iCloudImmichCleanSync); seus arquivos, cenas e textos não foram reutilizados.

Com Node.js e npm instalados, nesta pasta:

```sh
npm run check
npm run dev
npm run render -- --output ponte-fotos-promo.mp4 --fps 30 --quality delivery
```

O primeiro uso baixa a versão fixada do HyperFrames do npm. A renderização usa os assets locais. O aplicativo macOS não depende dessa ferramenta para compilar ou funcionar.

A biblioteca GSAP mantém seu aviso no arquivo distribuído; consulte a [licença do GSAP](https://gsap.com/standard-license/). Nenhuma fonte proprietária é distribuída; a composição usa `system-ui`.

MP4 e pôster de entrega estão em `../docs/media/`. A duração e a resolução são definidas nos atributos `data-*` de `index.html`; o movimento está na timeline GSAP pausada, buscável e determinística. O storyboard público é descrito pelas quatro cenas do HTML.

## Créditos de marca

A logo do Ponte Fotos é a imagem gerada e aprovada pelo usuário, copiada sem redesenho de `Assets/AppLogo.png`. O logo do Immich em `assets/immich-logo.svg` vem do [repositório oficial](https://github.com/immich-app/immich/blob/main/design/immich-logo.svg), consultado em22/10/2026. A licença do projeto de origem acompanha o arquivo em `assets/IMMICH-LICENSE.txt`. A marca identifica o destino da integração; não implica endosso.

Na abertura, uma foto percorre origem→Ponte→Immich. Na última cena, os estados de rede e a seleção das URLs mudam em sequência. Todos os endereços mostrados são exemplos.
