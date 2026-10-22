# 📝 Histórico de versões

As mudanças são agrupadas por versão. [Releases e downloads](https://github.com/allanpreis/ponte-fotos/releases) · [Guia completo](docs/GUIA-COMPLETO.md)

## 0.9.1 — 2026-10-22

### 🗂️ Destino no Fotos da Apple

- Escolha explícita entre álbum existente e criação de um novo álbum no fluxo Immich → Fotos.
- Lista de álbuns editáveis, atualizada sob demanda, com seleção pelo identificador e distinção de nomes repetidos.
- Novo álbum criado somente após confirmação e reutilizado no restante do lote; ao concluir a primeira operação confirmada, passa a ser o destino selecionado.
- Fotos já importadas podem ser adicionadas a outro álbum sem baixar ou criar uma nova cópia, preservando os vínculos anteriores.
- Destinos removidos ou sem permissão são bloqueados antes de baixar originais. A confirmação informa o destino escolhido.
- 51 verificações sintéticas da importação e dos destinos, sem mutações na fototeca real durante os testes.

## 0.9.0 — 2026-10-22

### 📥 Immich → Fotos da Apple

- Nova opção **Immich → Fotos** na barra lateral, com álbuns do Immich, miniaturas, seleção e revisão de data/GPS.
- Importação de originais por PhotoKit, com álbum de destino e confirmação explícita.
- Download com checksum, temporários protegidos, revalidação de metadados e proteção de pares Live Photo.
- Histórico por perfil/conta para evitar repetir itens importados pelo app, com bloqueio de resultados incertos.
- Cancelamento entre itens e conexão preservada durante a operação.
- Testes sintéticos sem gravações na biblioteca real. Limites de portabilidade de metadados documentados.

## 0.8.2 — 2026-10-22

### 🖼️ Ícone e nitidez

- Exportação opaca e sem a margem transparente da imagem gerada para evitar a segunda base que o macOS acrescentava ao ícone.
- Ícone nativo com todas as resoluções de 16 a 1024 pixels; o app deixa de sobrescrevê-lo com o PNG ao abrir.
- Logo interna carregada do bitmap de alta resolução com tamanho lógico de 38 pontos e interpolação de alta qualidade.
- Fonte aprovada preservada; exportação reproduzível com ferramentas nativas em `tools/export-icons.swift`.

### 🌓 Tema automático

- Selecionar Sistema remove imediatamente a aparência forçada do aplicativo, incluindo janelas e painéis existentes.
- Regressões cobrem Escuro → Sistema e Claro → Sistema. Nenhuma preferência global do macOS é modificada.

## 0.8.1 — 2026-10-22

### 🎨 Identidade consistente

- Uso da arte PNG gerada e escolhida pelo usuário, substituindo o redesenho vetorial anterior, no app, ícone macOS, repositório e apresentação.
- Ícone de distribuição regenerado a partir da mesma arte.

### 🎬 Apresentação

- Promo silencioso de 36 segundos, Full HD a 30 fps.
- Logo oficial do Immich na abertura e animação de uma foto percorrendo origem → Ponte Fotos → Immich.
- Demonstração animada da troca entre URL local e remota, com endereços fictícios e indicação da rede.

### 📚 Distribuição e documentação

- Guia cumulativo de instalação, conexão, fluxos, proteção de mídia, privacidade e limites, com screenshots de demonstração.
- Notas de versão e processo permanente de GitHub Release para cada nova versão, junto ao commit, ZIP e checksum.
- Esta correção de identidade e apresentação preserva os motores de upload, duplicatas e organização.

## 0.8.0 — 2026-10-22

- Primeira apresentação animada do app: vídeo silencioso de 32 segundos e fonte reproduzível.
- Exploração da identidade de pétalas e ponte, com um redesenho SVG aplicado nesta versão; substituído na 0.8.1 pela arte gerada escolhida pelo usuário.
- Publicação das melhorias acumuladas de interface e configurações.

## 0.7.0 — 2026-10-22

- Configurações dedicadas para conexão, contas/API e aparência, acessíveis por `⌘,`.
- Temas Claro, Escuro e Sistema persistentes; opção de transparência e vidro.
- Liquid Glass nativo no macOS 26+, materiais compatíveis no macOS 14/15 e respeito a Reduzir transparência.
- Biblioteca com melhor distribuição de espaço e continuidade da conta em memória entre configurações e gestão.
- Testes de aparência, persistência e cache de sessão.

## 0.6.0 — 2026-10-22

- Interface nativa reorganizada com barra lateral, componentes visuais consistentes e melhor adaptação ao tamanho da janela.
- Revisão visual das telas de biblioteca, metadados e gestão.

## 0.5.0 e base anterior

- Envio de originais do Fotos da Apple e de pastas, revisão de data/GPS e exportação com XMP.
- Associação de Live Photos do PhotoKit, conferência de envio, histórico e pausa após o conjunto atual.
- Perfis local/remoto, identificação de Wi-Fi e alternância automática de conexão.
- Gestão de contas, duplicatas por checksum incluindo imagem Live, comparação de álbuns, pessoa/idade e histórico de operações.
- Indicadores separados de Live Photo/estática e proteção contra descarte de Live Photos.
- Publicação inicial do código sanitizado, sem configuração privada e sem necessidade de `.env`.

Estas entradas históricas resumem a evolução do projeto; não representam releases retroativas já publicadas para cada versão anterior.
