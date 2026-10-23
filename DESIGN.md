# Interface do Ponte Fotos

## Navegação

A barra lateral separa Fotos da Apple, discos e pastas, Immich → Fotos, gestão da biblioteca e configurações. A tela principal reúne origem, destino, lista de mídia e ações. Conexão, contas/API e aparência ficam em Configurações, acessíveis também por ⌘,.

Na importação, a origem é um álbum do Immich. O destino permite escolher um álbum editável do Fotos ou informar o nome de um novo álbum. Nomes repetidos são diferenciados; a seleção usa o identificador do álbum. A criação ocorre somente após confirmação.

## Cores e tipografia

Use tipografia de sistema: título de página em 28 pt semibold, títulos de seção nativos, corpo em 13 pt e texto secundário em 11–12 pt. Cores semânticas acompanham o tema: azul para ações, verde para resultados confirmados, laranja para avisos e vermelho para erros.

Os espaçamentos seguem a escala 4/8/12/16/20/24/32 pt. Cartões agrupam tarefas relacionadas, com raio contínuo de 18 pt e contorno discreto de 0,5 pt. `Sources/DesignSystem.swift` reúne temas, cartões, títulos, indicadores e estados vazios.

## Aparência e acessibilidade

Os temas Claro, Escuro e Sistema se aplicam também às janelas de revisão e gestão. Liquid Glass é usado em áreas de navegação e ações no macOS 26 ou superior; macOS 14/15 usa materiais compatíveis. Desativar vidro ou ativar Reduzir transparência produz navegação opaca. Fotos e formulários mantêm superfícies sólidas.

Prefira controles nativos, rótulos de acessibilidade e foco por teclado. Estados precisam de texto ou ícone além da cor. Indicadores de Live Photo e foto estática ocupam uma linha própria, sem sobrepor nomes ou datas. Ícones decorativos não participam da leitura por VoiceOver.

## Layout

A janela tem mínimo de 900 × 650 e barra lateral de aproximadamente 220 pt. Grupos de controles se adaptam com `ViewThatFits` ou grades adaptativas; formulários e listas têm rolagem própria. As ações de revisão permanecem acessíveis enquanto o conteúdo rola.

## Estados e confirmações

A biblioteca vazia orienta a escolha de uma origem. Consultas remotas dependem de conexão validada; revisão e exportação local permanecem disponíveis sem servidor. Erros são identificados e selecionáveis. Consultar álbuns não inicia importações.

Alterações exigem revisão e confirmação. Durante uma transferência, origem, conexão e navegação ficam protegidas até um ponto seguro. Cancelar preserva os resultados já confirmados. O histórico de importação reconhece somente itens importados pelo aplicativo.

Os textos usam português direto e verbos concretos, como Abrir biblioteca, Escolher pasta, Revisar e Enviar. A confirmação explica o que será alterado e qual será o destino.

## Referências

- [Materials — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [preferredColorScheme](https://developer.apple.com/documentation/swiftui/view/preferredcolorscheme(_:))
- [accessibilityReduceTransparency](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducetransparency)
