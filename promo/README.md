# Vídeo de apresentação

Apresentação ilustrativa de **66 segundos**, em português, sem áudio, em **1920 × 1080 a 30 fps**. Usa HyperFrames 0.8.185 e GSAP 3.14.2. As paisagens, álbuns e diagramas são sintéticos; o vídeo não é uma gravação da interface.

## Cenas

| Tempo | Conteúdo |
| --- | --- |
| 0–8 s | Fotos da Apple e pastas → Immich; Immich → Fotos |
| 8–16 s | Originais, revisão de data/GPS e exportação com XMP |
| 16–25 s | Importação de originais, checksum e Live Photos compatíveis |
| 25–35 s | Álbum existente ou novo; novos vínculos para itens já importados |
| 35–44 s | Duplicatas exatas e proteção de Live Photos contra descarte |
| 44–52 s | Comparação de álbuns e seleção por pessoa e idade |
| 52–60 s | Conexão local/remota conforme o Wi-Fi configurado |
| 60–66 s | Marca, endereço do projeto e requisitos |

As transferências dependem da seleção e confirmação do usuário. O histórico reconhece importações anteriores feitas pelo Ponte Fotos; não compara toda a fototeca. A importação de Live Photos exige pares compatíveis. Pessoa e idade usa informações já cadastradas no Immich.

## Reproduzir

Com Node.js 22 ou superior, npm e FFmpeg instalados, execute nesta pasta:

```sh
npm run check
npm run dev
npm run render -- --output ../docs/media/ponte-fotos-promo.mp4 --fps 30 --quality delivery
```

O primeiro uso baixa a versão fixada do HyperFrames do npm. Os assets da composição são locais. O app macOS não depende dessas ferramentas.

`index.html` reúne oito cenas em `compositions/`, com uma timeline GSAP pausada e determinística por cena. `style.css` define a linguagem visual compartilhada. `index.motion.json` verifica o aparecimento e o enquadramento de elementos durante as transferências. A repetição da paisagem entre cenas e cópias é intencional.

MP4 e pôster ficam em `../docs/media/`.

## Créditos

A marca do Ponte Fotos usa `Assets/AppLogo.png`, reproduzida sem redesenho em `assets/logo.png`. O logo do Immich em `assets/immich-logo.svg` vem do [repositório oficial](https://github.com/immich-app/immich/blob/main/design/immich-logo.svg); a licença acompanha o arquivo em `assets/IMMICH-LICENSE.txt`. A marca identifica a integração e não implica endosso.

A biblioteca GSAP mantém seu aviso no arquivo distribuído; consulte a [licença do GSAP](https://gsap.com/standard-license/). A composição usa tipografia `system-ui`, sem fontes proprietárias distribuídas. Os endereços de servidor mostrados são exemplos.
