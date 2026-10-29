<p align="center"><img src="Assets/AppLogo.png" alt="Ponte Fotos" width="112"></p>

[English](README.md) · **Português (Brasil)**

# Ponte Fotos

[![Release](https://img.shields.io/github/v/release/allanpreis/ponte-fotos)](https://github.com/allanpreis/ponte-fotos/releases/latest)
[![macOS build](https://github.com/allanpreis/ponte-fotos/actions/workflows/ci.yml/badge.svg)](https://github.com/allanpreis/ponte-fotos/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple)](#requisitos)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**[Baixar](https://github.com/allanpreis/ponte-fotos/releases/latest) · [Instalação](#-instalar-pela-release) · [Contribuir](CONTRIBUTING.md) · [Relatar erro](https://github.com/allanpreis/ponte-fotos/issues/new/choose)**

Aplicativo nativo para macOS que conecta o Fotos da Apple e o Immich nos dois sentidos. Envie originais do Fotos ou de pastas para o Immich, importe álbuns do Immich para o Fotos e revise data e localização. Também oferece ferramentas para organizar a biblioteca do servidor.

**Versão: 1.0.9 · macOS 14 ou superior · Apple Silicon · Immich 3.x**

**Idiomas:** o aplicativo oferece português (Brasil) e inglês. Por padrão, acompanha o idioma do macOS e usa inglês para outros idiomas. Em **Configurações → Aparência → Idioma do aplicativo**, escolha **Sistema**, **English** ou **Português (Brasil)**. Na primeira abertura, **Sistema** vem selecionado. A mudança é imediata e a preferência fica salva. As instruções também estão disponíveis no [README em inglês](README.md).

O aplicativo é escrito em Swift e SwiftUI, usa os frameworks do macOS e não depende de serviços de nuvem próprios, Node.js, Docker ou pacotes Swift externos. Um servidor Immich é necessário para conexão, envio, importação e gestão; exportação local e revisão de arquivos podem ser usadas sem ele.

O app reúne transferências por conta, escolha de URL por disponibilidade, diagnóstico de mídia e conferência de metadados após importar. Informa formato, disponibilidade de prévia, propriedades de cor das imagens e sinalização PQ/HLG dos vídeos, sem tratar esses dados como comprovação de compatibilidade HDR completa. Os buffers temporários permanecem limitados durante o cálculo de hash e a preparação de originais grandes. [Notas da versão](https://github.com/allanpreis/ponte-fotos/releases/tag/v1.0.9).

## Preparação dos originais do Fotos

A exportação informa o progresso nativo de download do iCloud e distingue exportação de cálculo do hash. Após dois minutos sem dados nem avanço no progresso, a solicitação é cancelada com erro para nova tentativa. Pausar cancela a preparação local; mídias já em envio terminam como unidade. Os blocos recebidos são gravados em temporário privado, disponibilizado apenas após sucesso. Vídeos e Live Photos prontos começam a ser enviados sem esperar o restante da janela de preparação. Isso não acelera a conexão do iCloud em si.

### Acompanhamento Fotos → Immich

Escolha um álbum específico do Fotos e um álbum existente no Immich; use **Acompanhar este álbum** no card de origem. **Consultar novidades** revisa o álbum inteiro, inclusive além da primeira página, e monta uma fila sem seleção automática. Confirme o envio no diálogo existente. Somente envios completos verificados e inclusão confirmada no álbum de destino são concluídos; recursos indisponíveis, metadados alterados e falhas continuam para revisão. Checksum, proprietário e presença no álbum remoto são consultados novamente antes de omitir itens concluídos. Os vínculos persistem por perfil/conta, separados dos vínculos de importação. Nada é enviado em segundo plano.

Na importação, os controles agora exibem um resumo compacto do destino. Abra **Destino e acompanhamento** para ajustar o destino ou o vínculo, deixando mais espaço para revisar as fotos. Os dois sentidos exigem revisão manual, sem comparação universal de cópias existentes ou sincronização bidirecional automática.


## Acompanhamento assistido de álbuns

Em **Immich → Fotos**, escolha a origem e um álbum existente do Fotos, depois clique em **Acompanhar este álbum**. O vínculo é salvo para o perfil e a conta atuais. **Consultar novidades** abre uma fila manual: selecione os itens e confirme a importação no diálogo existente. A primeira consulta inclui os itens da origem ainda não concluídos nesse vínculo. Consultar não importa nem consome a fila.

Somente importações confirmadas são marcadas como concluídas. Itens concluídos e inalterados saem da fila enquanto a foto conhecida ainda pertence ao álbum vinculado. Vínculos removidos do álbum, metadados alterados e resultados pendentes voltam para revisão; importações conhecidas podem ser adicionadas ao destino sem nova cópia. Um destino ausente bloqueia a importação. Parar o acompanhamento remove só o vínculo, preservando mídia e histórico. Os vínculos e comprovantes ficam localmente em `~/Library/Application Support/PonteFotos/album-follow/`, sem chaves de API.

O fluxo é manual e em uma direção, sem sincronização em segundo plano, propagação de exclusões ou comparação de toda a biblioteca do Fotos. A proteção contra repetição usa o histórico conhecido pelo app; não reconhece todas as cópias preexistentes ou envios antigos com outro ID remoto. Revise os casos incertos antes de importar.


## Operações grandes — concorrência limitada

O fluxo de envio prepara janelas de até oito mídias completas, com alvo flexível de 128 MiB. A última mídia inteira pode ultrapassar esse alvo. Imagens comuns existentes podem ser consultadas por SHA-1 em lotes e reutilizadas somente após revalidar identidade, proprietário, checksum, disponibilidade e ausência de associação Live. Vídeos e Live Photos mantêm o envio normal; o vídeo pareado continua antes da imagem. O hash calculado é reaproveitado no envio e a preparação multipart roda fora da interface. Há conferência do espaço livre conhecido antes de copiar/montar temporários, com reserva; tamanhos PhotoKit desconhecidos e mudanças no espaço ainda podem causar falhas de gravação.

Os contadores distinguem itens conferidos, recursos novos enviados e recursos reutilizados. Medições locais por fase apoiam a próxima otimização; não são telemetria de banda. Mudanças de rede e falhas pausam entre mídias completas, sem repetir automaticamente o lote. O indicador superior mostra apenas **URL local** ou **URL remota**, mantendo o diagnóstico nas configurações.

O agendador processa no máximo duas mídias completas por vez. Itens que compartilham o hash de algum recurso são processados separadamente; unidades com mais de 16 MiB de conteúdo multipart preparado são exclusivas. A pausa aguarda os itens ativos, incluindo todos os recursos Live, antes de parar. O progresso conta unidades concluídas, mesmo fora de ordem. Linhas repetidas de uma mesma origem são agendadas uma vez por identidade. Esses limites não prometem ganho real de velocidade. A previsão de tamanho de todo o lote PhotoKit e a validação grande de vazão/memória em servidor real continuam limitadas. [Validação e limites](https://github.com/allanpreis/ponte-fotos/releases/tag/v1.0.9).

## Contas por transferência e conexão por disponibilidade

O menu de conta abaixo de Configurações na barra lateral permite escolher uma conta para enviar e importar sem substituir a conexão principal. Mostra o nome e a foto de perfil circular quando disponível, com iniciais ou ícone de pessoa como alternativa. A foto é opcional e seu cache existe somente na memória; falta de permissão para a imagem ou falha no download não bloqueia transferências. IDs e chaves de API não aparecem como nomes no menu. A conta escolhida, o endereço do servidor e o álbum aparecem antes da confirmação; identidade e permissões de API necessárias são revalidadas antes das operações. Os históricos continuam separados por perfil e conta.

**Automático** tenta primeiro a URL local configurada e só tenta a remota se o serviço local estiver indisponível. **Local** e **Remoto** usam exclusivamente a respectiva URL. O app valida a API do Immich e a conta esperada, sem aceitar apenas ping ou qualquer resposta HTTP bem-sucedida, e informa o motivo do endereço escolhido. Nome de Wi-Fi e a permissão de Localização usada para lê-lo deixam de ser necessários; o tratamento de GPS das fotos permanece disponível. URLs, identificadores de perfil, contas e históricos existentes são preservados; um campo SSID antigo pode continuar armazenado, mas é ignorado.

A conexão fica fixa durante o lote. Uma mudança de rede pausa depois da mídia atual, incluindo todos os recursos de uma Live Photo, e exige revalidação antes de continuar. A retomada ocorre por item, sem retomada parcial de bytes.

O seletor acompanha o tamanho e alinhamento dos itens da barra lateral. Os botões de transferência usam o estilo nativo com borda do macOS, acompanhando as outras ações da barra nos dois temas.

A validação inclui testes sintéticos de roteamento, contas, histórico e falhas, além de transferências reais limitadas de JPEG/Live Photo por uma conta de teste autorizada. Envios repetidos e conferências de itens já importados no Fotos reutilizaram cópias existentes; downloads independentes corresponderam aos originais aprovados. Nova criação de originais no Fotos, alternância física de VPN, lotes grandes do iCloud e operações reais de lixeira/restauração não foram validados nesta consolidação.

## 📥 Immich → Fotos da Apple

Na barra lateral, abra **Immich → Fotos**. Teste a conexão, escolha a conta de origem no menu de conta da barra lateral, atualize os álbuns, consulte um álbum e selecione os itens. Confira a data de captura, GPS e o indicador de Live Photo; escolha **Álbum existente** ou **Criar novo álbum** no destino e confirme a importação.

O app baixa os originais, verifica o checksum e usa o PhotoKit para criar os itens no Fotos deste Mac. O iCloud segue os ajustes do Fotos. Os originais do Immich permanecem intactos. Itens sem data válida/fuso explícito, localização inválida ou recursos indisponíveis ficam bloqueados. Live Photos exigem imagem e vídeo compatíveis. Pessoas reconhecidas e histórico de edições não são transferidos.

A opção **Atualizar álbuns do Fotos** lista somente destinos editáveis, sem criar ou alterar itens. Álbuns com nomes iguais são diferenciados na lista e selecionados pelo identificador. Um novo álbum é criado somente após confirmação e passa a ser o destino dos próximos lotes.

Fotos já importadas pelo app podem ser selecionadas e adicionadas a outro álbum sem baixar novamente, criar novas cópias ou removê-las dos álbuns anteriores. Um histórico local por perfil/conta evita repetir importações feitas pelo Ponte Fotos; ele não compara toda a biblioteca preexistente. Resultados sem confirmação final ficam bloqueados para evitar repetição automática.


## Diagnóstico de mídia e conferência de importação

Use o botão de informação ao lado de um item de origem para inspecionar o original localmente. O diagnóstico informa formato, disponibilidade de prévia local, propriedades de cor disponíveis e sinalização PQ/HLG de vídeos. Arquivos JXL entram na busca em pastas, mas reconhecimento ou prévia funcional não comprovam suporte à importação no Fotos. Inspecionar recursos do Fotos pode baixar originais temporários do iCloud conforme a opção de acesso; as cópias temporárias são removidas ao terminar. Gain maps de imagens HDR, Dolby Vision e comportamento das edições de câmera lenta não são validados.

Depois de uma nova importação Immich → Fotos, o app confere presença do item criado, data de captura, localização disponível e subtipo Live Photo. Divergências ou resultados inconclusivos mantêm o histórico pendente e bloqueiam novas tentativas até conferir a biblioteca. Itens previamente importados são conferidos antes de adicioná-los a outro álbum. Ative **Conferir originais por hash após importar** em **Destino e acompanhamento** para reexportar temporariamente o original armazenado no Fotos e comparar seu SHA-1 com o Immich. Live Photos exigem imagem e vídeo iguais. A conferência opcional pode baixar originais do iCloud e levar mais tempo. Divergência ou falha de exportação mantém o item conhecido pendente para reconferência, mesmo se a opção for desligada depois; nunca cria uma cópia substituta. A conferência apenas de metadados continua como padrão. Nenhuma das conferências valida reprodução HDR ou aparência das edições.

## 📦 Instalar pela release

Baixe o [Ponte Fotos 1.0.9 para Apple Silicon](https://github.com/allanpreis/ponte-fotos/releases/download/v1.0.9/Ponte-Fotos-1.0.9-arm64.zip), extraia e mova **Ponte Fotos.app** para a pasta Aplicativos do seu usuário. Encerre a versão anterior antes de substituir. O pacote tem assinatura local ad hoc; ainda não possui Developer ID nem notarização. Não é necessário desativar proteções do macOS.

[🚀 Release e arquivos](https://github.com/allanpreis/ponte-fotos/releases/tag/v1.0.9) · [📝 Histórico de versões](https://github.com/allanpreis/ponte-fotos/releases)

## Visual e configurações

Abra **Configurações** na barra lateral ou use **⌘,**:

- **Conexão**: endereços local/remoto, modo Automático/Local/Remoto e chave principal. O app dispensa nome de Wi-Fi e permissão de Localização para conectar.
- **Contas e API**: cadastro de contas adicionais no Chaves do macOS após validar a conexão principal. Escolha uma conta cadastrada no menu abaixo de **Configurações** na barra lateral; cadastrá-la não substitui a chave principal nem a seleciona automaticamente para transferências.
- **Aparência**: tema Claro, Escuro ou Sistema, efeitos de vidro e **Idioma do aplicativo**. O tema também vale para revisão e gestão. O idioma muda imediatamente, sem reiniciar o app.

A tela principal mantém origem, destino, lista de mídia e ações sem um painel rolável de conexão. Em janelas menores, a lista conserva sua própria rolagem; formulários extensos rolam somente dentro de Configurações.

A opção **Usar transparência e vidro** controla o acabamento da navegação. O Liquid Glass nativo é usado no macOS 26 ou superior; no macOS 14/15 são usados materiais translúcidos compatíveis. Desativar a opção ou ativar **Reduzir transparência** no macOS usa superfícies opacas. Fotos e formulários permanecem sólidos para manter a leitura. Idioma, tema e preferência de vidro são dados não sensíveis no UserDefaults; não são gravados junto de chaves de API.

## Recursos

| Área | O que faz |
| --- | --- |
| Biblioteca Apple | Lista fotos em páginas de 100 itens, permite seleção e pode baixar originais do iCloud mediante autorização. |
| Pastas e discos | Lê recursivamente a pasta escolhida, incluindo subpastas, e identifica metadados de imagem, vídeo e XMP. |
| Revisão | Permite completar ou corrigir data e GPS antes de preparar os arquivos para envio. |
| Exportação | Exporta originais com XMP complementar, sem modificar a biblioteca Apple ou arquivos de origem. |
| Upload | Envia para a linha do tempo, um álbum existente ou um novo álbum; confere checksum, data, GPS disponível e associação Live Photo. |
| Conexão por rede | Tenta a URL local antes da remota por disponibilidade no modo Automático; Local e Remoto permanecem exclusivos. |
| Duplicatas | Encontra cópias por checksum exato e sugere separadamente pares por metadados para comparação manual, escolha da cópia mantida e revisão antes de enviar uma cópia estática à lixeira. |
| Comparação | Compara conteúdos de dois álbuns e organiza seus vínculos sem apagar os arquivos da biblioteca. |
| Pessoa e idade | Seleciona imagens por pessoa, aniversário registrado no Immich e intervalo inclusivo de idade. |
| Contas e histórico | Usa chaves por conta e registra as últimas 20 operações de gestão, incluindo resultados incertos. O app também permite selecionar uma conta cadastrada para transferir, com históricos separados por perfil/conta. |

## Requisitos

- Mac com Apple Silicon e macOS 14 ou superior. O script atual gera um executável `arm64`; Intel ainda não foi validado.
- Xcode 26 ou superior com o SDK do macOS 26, selecionado como ambiente ativo de desenvolvimento. O aplicativo continua compatível com macOS 14; SDKs antigos não compilam as APIs de Liquid Glass.
- Servidor Immich 3.x acessível e chave de API da conta correspondente. A integração foi desenvolvida com Immich 3.3.5; mudanças futuras na API podem exigir ajustes.
- Espaço livre para preparar cópias temporárias e, quando solicitado, baixar originais do iCloud.

## Instalar a partir do código

```sh
xcode-select --install
```

Se as ferramentas já estiverem instaladas, prossiga:

```sh
git clone https://github.com/allanpreis/ponte-fotos.git
cd ponte-fotos
zsh build.sh
mkdir -p "$HOME/Applications"
ditto "build/Ponte Fotos.app" "$HOME/Applications/Ponte Fotos.app"
open "$HOME/Applications/Ponte Fotos.app"
```

Encerre uma versão anterior do aplicativo antes de substituí-la. O build produz `build/Ponte Fotos.app` com assinatura local ad hoc. O projeto ainda não possui assinatura Developer ID, notarização ou instalador oficial; o macOS pode exigir autorização para abrir o aplicativo e voltar a pedir permissões após uma recompilação. Não há necessidade de desativar o Gatekeeper ou outras proteções do sistema.

Não execute o bundle diretamente de uma pasta sincronizada que modifique seus atributos estendidos: isso pode invalidar a assinatura. Prefira uma pasta local de aplicativos.

## Primeira conexão

1. Abra **Configurações → Conexão** no app (ou **⌘,**).
2. Informe a URL do seu Immich e a chave de API da conta de destino. Use a URL base, sem credenciais ou parâmetros embutidos.
3. Escolha **Automático**, **Local** ou **Remoto**, informe as URLs correspondentes ao modo e clique em **Testar conexão**.
4. Se quiser persistir os dados, use **Salvar configuração**. Eles são armazenados no Chaves do macOS.

A configuração inicial do código publicado fica vazia. Exemplos de preenchimento: URL local `http://immich.local:2283`, URL remota `https://photos.example.com`. São exemplos fictícios; substitua pelos seus dados na interface.

O aplicativo não lê arquivos `.env`. Não é necessário criar um para compilar ou usar o projeto. Chaves e URLs privadas não devem ser colocados no código ou enviados ao GitHub.

### Permissões de API

Conceda apenas as permissões necessárias para o fluxo que pretende usar. Uma chave não amplia os acessos da conta aos álbuns de outras pessoas.

| Operação | Permissões relevantes |
| --- | --- |
| Conexão e envio | `server.version`, `user.read`, `asset.upload`, `asset.read` |
| Importação do Immich para o Fotos | `user.read`, `asset.read`, `asset.download`, `album.read`; prévias também exigem a permissão correspondente de miniaturas |
| Consulta e miniaturas na gestão | `user.read`, `album.read`, `asset.read`, `asset.view` |
| Foto de perfil opcional da conta | `userProfileImage.read`; não é exigida para enviar ou importar, que continuam com iniciais ou ícone |
| Pessoas | `person.read`, além das permissões de consulta |
| Criar álbum no envio | `album.create` e permissões de consulta/organização correspondentes |
| Adicionar/remover vínculos | `albumAsset.create`, `albumAsset.delete`, conforme a operação |
| Duplicatas para lixeira | `asset.delete`, além da leitura e preservação de vínculos em álbuns |
| Aplicar revisão a um recurso enviado | `asset.update`, quando necessário ao fluxo |

O servidor pode exigir escopos adicionais conforme a versão e o endpoint. Permissões ausentes ou falta de acesso ao recurso impedem a operação; confira a mensagem do app. Evite usar uma chave com `all` se não precisar de todas as funções.

### Alternância automática de endereço

No aplicativo atual, informe URL local e/ou remota e escolha o modo de conexão. O roteamento não consulta SSID nem solicita Localização.

- **Automático** tenta primeiro a URL local, seja por Wi-Fi, Ethernet ou VPN, e depois a remota diante de falha elegível de conectividade/indisponibilidade do serviço. Uma URL configurada é suficiente nesse modo.
- **Local** usa somente a URL local; **Remoto** usa somente a remota. Ausência da URL em um modo exclusivo é erro de configuração.
- Cada candidato precisa responder como Immich com a conta esperada. Erros de autenticação, servidor inválido ou conta divergente bloqueiam a operação sem tentar outro destino.
- Endereço escolhido e motivo ficam visíveis. Há revalidação antes das transferências e depois de mudanças de rede ou falhas relevantes.
- A transferência mantém o cliente fixo durante o lote. Mudança de rota conclui o conjunto de recursos da mídia atual, pausa antes da próxima e exige revalidação. A prévia de importação deve ser atualizada se mudar conta/endereço de origem.
- Identificadores de perfil, contas, URLs e históricos existentes são preservados. O histórico continua separado por perfil lógico e conta entre os dois endereços.

A conferência fixa o UUID da conta, não uma identidade criptográfica do servidor. Configure apenas endereços do mesmo servidor confiável. HTTP é aceito, mas envia chave e mídia sem criptografia de transporte; prefira HTTPS, especialmente fora da rede local.

## Enviar fotos e vídeos

1. Selecione **Fotos da Apple** na barra lateral e conceda acesso ao Fotos. Ou selecione **Discos e pastas** e escolha a origem em um disco/pasta.
2. Escolha itens e confira as indicações de data/GPS. A opção de baixar originais do iCloud depende do acesso à conta/biblioteca do próprio macOS.
3. Use **Revisar** para completar data ou localização ausente. Sem data confiável, o envio exige revisão; o app não usa automaticamente a criação do arquivo como data de captura.
4. Escolha a conta da transferência no menu da barra lateral e o destino: sem álbum, álbum existente ou novo álbum. Confira a conta e o servidor exibidos antes de confirmar.
5. Envie uma pequena amostra e confira o resultado no Immich antes de um lote grande.

Originais preservam seus bytes; um XMP complementar carrega data e localização da biblioteca/revisão. O processo de preparação não modifica o arquivo de origem. O XMP associado de uma pasta é mesclado preservando campos adicionais.

Para Live Photos do Fotos da Apple, o vídeo de movimento é enviado primeiro e associado à imagem principal. Imagens e vídeos de pastas externas formam uma unidade Live Photo revisável somente quando os identificadores internos coincidem de forma única e o PhotoKit aceita o par. A revisão mostra os dois nomes e o diagnóstico inclui ambos os recursos. Metadados ausentes, conflitantes, ambíguos ou incompatíveis mantêm os arquivos independentes com uma explicação; nomes e horários nunca estabelecem o par. Os dois originais e seus XMP são conferidos novamente na preparação; alterações exigem nova análise. O vídeo é enviado primeiro e não reaparece como seleção independente. O vídeo acompanhante já é criado com visibilidade oculta, evitando sua publicação temporária como item independente na linha do tempo. A imagem mantém a visibilidade normal. O app exige o acompanhante oculto para marcar a Live Photo como conferida. Uma imagem estática preexistente ou outro vínculo remoto bloqueia a reutilização para revisão. Aceitação pelo PhotoKit comprova carregamento local, sem certificar fidelidade visual ou reprodução no Immich. RAW e JPEG associados são preservados como recursos distintos, sem empilhamento automático.

**Pausar após este item** conclui o conjunto atual. Histórico e checksum ajudam a reutilizar recursos já enviados e ainda válidos. Interrupções podem produzir resultados pendentes ou incertos: confira no servidor antes de repetir.

### Conferência dos metadados

O fluxo compara checksum, instante de captura (tolerância inferior a um segundo), GPS disponível (tolerância de 0,00001 grau) e associação do vídeo Live. Uma resposta tardia ou divergente permanece pendente/divergente, sem marcar sucesso indevido.

O PhotoKit fornece um instante absoluto; a prévia usa o fuso do Mac e o XMP complementar usa UTC. Confira fotos de viagens e correções manuais na linha do tempo. O app exporta originais, sem prometer reproduzir edições, álbuns Apple, legendas, palavras-chave, rostos ou todos os metadados proprietários da Apple. Favorito é enviado, mas não faz parte dessa conferência.

## Gerenciar o Immich

Gerencie as contas somente em **Configurações → Contas e API**. Com a conexão validada, clique em **Usar conta da conexão atual** ou adicione uma conta com a própria chave; depois abra **Gerenciar biblioteca** para as operações da biblioteca. Contas adicionais são salvas separadamente no Chaves; a conta atual pode ser usada apenas em memória nessa sessão.

### Álbuns e duplicatas

Selecione os álbuns e consulte. O resultado mostra duas contagens e visualizações separadas:

- **Cópias exatas por hash** agrupam arquivos com checksums idênticos. Essa conferência inclui imagens de Live Photos e permanece separada das sugestões por metadados.
- **Possíveis duplicatas** sugere pares de imagens com hashes diferentes, dimensões iguais e captura com até um segundo de diferença. O par precisa ter o mesmo nome normalizado ou fabricante e modelo de câmera preenchidos e coincidentes. A análise compara até dez itens próximos por agrupamento e retorna até 500 pares. Pode deixar variantes de fora e não garante uma biblioteca sem duplicatas.

Use **Comparar ampliado** para conferir as prévias geradas pelo servidor e escolha uma cópia para manter somente nos pares que reconhecer como duplicatas. As prévias não são os originais e não comprovam qualidade original, fidelidade HDR ou movimento. As sugestões começam desmarcadas; **Revisar possíveis duplicatas** mostra quais cópias serão mantidas e enviadas à lixeira antes da confirmação explícita.

Cada cópia mostra conta, nome, tipo de mídia, metadados e álbuns acessíveis. Nenhum dos fluxos descarta Live Photos. Um par com duas Live Photos fica, portanto, bloqueado, assim como pares selecionados que compartilhem fotos e ações sem contas proprietárias ou permissões necessárias.

Antes das alterações, o app revalida conteúdo, proprietário, movimento, acesso e vínculos de álbuns. Nas sugestões, também exige que os metadados e o conjunto de álbuns revisados permaneçam iguais. A cópia mantida é adicionada aos álbuns acessíveis da outra, e essas adições são confirmadas antes de qualquer solicitação de lixeira. Vínculos invisíveis às contas conectadas não podem ser preservados.

O app exige que o servidor confirme lixeira ativa e prazo de retenção positivo antes de o fluxo gravar alterações, e confere novamente antes de cada solicitação de lixeira. Configuração indisponível ou não confirmada bloqueia a ação. O app envia `force: false` e nunca esvazia a lixeira; mudanças posteriores de política pelo administrador ficam fora do seu controle. Operações reais de lixeira e restauração não foram exercitadas nesta consolidação; as guardas do app foram testadas com respostas simuladas do servidor.

### Comparar álbuns

Compara dois álbuns. Por padrão mostra conteúdos presentes nos dois; é possível incluir exclusivos. Para cada grupo, escolha deixar como está, manter nos dois ou reunir em um dos álbuns. Adições são confirmadas antes de remover vínculos de origem. Os arquivos permanecem na biblioteca do servidor.

### Pessoa e idade

Selecione conta, pessoa, origem, destino e intervalo de idade. Pessoas sem nome ficam ocultas. Registros com o mesmo nome e a mesma data completa de nascimento válida aparecem como uma opção; com Todas as contas, a consulta busca cada ID correspondente nas contas conectadas. Uma conta específica restringe a lista e a busca. Nascimentos diferentes ou ausentes mantêm registros separados; o agrupamento da consulta não mescla cadastros no servidor. Resultados compartilhados aparecem uma vez, preservando pessoa, conta e fontes para revalidação. Trocar os critérios limpa o resultado anterior; uma origem escolhida que ficou indisponível bloqueia a consulta. A pessoa precisa ter aniversário cadastrado no Immich. A seleção considera a data local de captura e os limites inclusivos; aniversário em 29 de fevereiro passa a 1º de março em ano não bissexto. A origem pode ser um álbum ou todos os álbuns acessíveis a cada conta correspondente da pessoa, exceto o destino.

Revise os resultados antes de organizar. O fluxo revalida aniversário, associação à pessoa, captura e conteúdo; mantém vínculos com outros álbuns que não fazem parte da origem selecionada.

### Revisão e histórico

Toda alteração da gestão passa por uma tela de revisão e uma confirmação explícita. O histórico registra até 20 execuções e cada ação antes/depois da solicitação. Falha ou interrupção pode deixar uma parte confirmada e outra incerta: não há rollback geral nem repetição automática. Consulte o histórico e o Immich antes de agir novamente.

### Limites da gestão nesta versão

- Até 100 álbuns e 30 mil itens únicos por análise.
- Comparação e pessoa/idade excluem Live Photos, pilhas, arquivos offline e editados; a consulta de duplicatas inclui imagens Live com proteção contra descarte.
- A conta proprietária pode ser exigida mesmo em operações de organização, de modo conservador.
- Consultas podem ser canceladas; alterações não oferecem cancelamento no meio de uma chamada de rede.
- Análises prontas não são restauradas depois de fechar a janela de gestão.
- Criação/destinos extras de álbuns no fluxo de duplicatas e decisões em lote da comparação ainda não estão disponíveis.
- Operações grandes podem ser lentas devido às revalidações de segurança.

## Privacidade e armazenamento local

| Local | Conteúdo |
| --- | --- |
| Chaves do macOS | Perfil de conexão, URLs e chave principal; chaves das contas adicionais em serviço separado. Um SSID antigo pode permanecer armazenado para migração, mas é ignorado pelo aplicativo atual. |
| `~/Library/Application Support/PonteFotos/reviews.json` | Revisões de metadados. |
| `~/Library/Application Support/PonteFotos/history/` | Histórico de envio, IDs e checksums. |
| `~/Library/Application Support/PonteFotos/management/` | Histórico da gestão por perfil, salvo com modo de arquivo `0600`. |
| `~/Library/Application Support/PonteFotos/staging/` | Cópias temporárias; uma interrupção abrupta pode deixar resíduos. |
| Pasta escolhida para exportação | Originais e XMP exportados pelo usuário. |

Fotos de perfil são buscadas na conexão Immich selecionada e validada e mantidas somente na memória do processo; não são salvas junto de chaves ou históricos. Históricos, revisões e exportações podem conter nomes, IDs, datas e GPS pessoais. Não os publique em issues, logs ou repositórios. **Esquecer conexão** remove a conexão principal do Chaves; os campos atuais permanecem na memória até fechar. Isso não remove automaticamente contas adicionais ou históricos locais.

O `.gitignore` exclui `.env`, credenciais usuais, builds, bundles, arquivos compactados e estado local. Ele não remove segredos já versionados e não substitui revisão antes de cada commit. O repositório contém os fontes do aplicativo, seus recursos visuais e a mídia usada pelos READMEs.

O histórico da importação inversa fica em `~/Library/Application Support/PonteFotos/reverse-import/`, com acesso restrito e sem chaves da API.

## Estrutura do repositório

```text
Sources/       Código Swift do aplicativo
Assets/        Logo e ícone do aplicativo
Resources/     Traduções em inglês e português do Brasil
Info.plist     Versão, identificador e permissões do macOS
build.sh       Compilação e assinatura local
README.md      Documentação principal em inglês
README.pt-BR.md Documentação em português (Brasil)
.gitignore     Exclusões de builds, credenciais e dados locais
```

O repositório contém o código do aplicativo, recursos de compilação, instruções de uso e arquivos da comunidade do GitHub. As releases fornecem o aplicativo e o histórico de mudanças.

## Solução de problemas

| Sintoma | O que conferir |
| --- | --- |
| Servidor não responde | Immich em execução, URL/porta, rota, DNS e firewall. O app não precisa que você altere o código para configurar o endereço. |
| Endereço ou conta incorretos | Confira Automático/Local/Remoto, URLs configuradas e conta selecionada para transferir. A conexão dispensa nome de Wi-Fi e Localização. Atualize os álbuns após mudar a origem. |
| Biblioteca vazia ou acesso negado | Ajustes do Sistema → Privacidade e Segurança → Fotos; confirme acesso e biblioteca selecionada no Fotos. |
| Original do iCloud indisponível | Acesso ao iCloud, internet, espaço livre e opção de baixar originais. |
| Ação da gestão bloqueada | Chave da conta proprietária, permissões da API, acesso aos álbuns, exclusões de mídia e, para lixeira, confirmação do servidor de que ela está ativa com retenção positiva. |
| Possíveis duplicatas não aparecem | Cópias exatas exigem checksums iguais. As sugestões separadas por metadados têm limites de nome/câmera, dimensões, data e quantidade; o app não faz reconhecimento visual automático. |
| Assinatura inválida | Recompile em pasta local, confira `codesign` e instale o bundle fora de sincronizadores. |
| Resultado incerto | Confira histórico e servidor; não repita cegamente a operação. |

## Estado do projeto

A versão 1.0.9 consolida os fluxos atuais, com assinatura local e testes automatizados. O workflow do GitHub confere compilação, metadados do bundle, assinatura e arquitetura arm64; os testes de comportamento são executados separadamente. O número da versão não certifica os cenários ainda não validados descritos acima. Faça backup da biblioteca e do servidor e comece com lotes pequenos antes de usar ferramentas que alteram vínculos ou enviam cópias à lixeira.

Este é um projeto independente, sem vínculo oficial com Apple ou Immich. Distribuído sob a [licença MIT](LICENSE).

## Comunidade e créditos

Criado e mantido por [Allan Reis](https://github.com/allanpreis). Veja os [contribuidores](https://github.com/allanpreis/ponte-fotos/graphs/contributors). Contribuições de código, documentação, tradução, acessibilidade e testes são bem-vindas.

[Como contribuir](CONTRIBUTING.md) · [Código de conduta](CODE_OF_CONDUCT.md) · [Segurança](SECURITY.md) · [Histórico de versões](https://github.com/allanpreis/ponte-fotos/releases)
