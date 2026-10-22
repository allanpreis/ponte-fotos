<p align="center"><img src="Assets/AppLogo.png" alt="Ponte Fotos" width="112"></p>

# Ponte Fotos

Aplicativo nativo para macOS que envia originais do Fotos da Apple e de pastas para o Immich, permite revisar data e localização e oferece ferramentas para organizar a biblioteca do servidor.

**Versão: 0.8.2 · macOS 14 ou superior · Apple Silicon · Immich 3.x**

O aplicativo é escrito em Swift e SwiftUI, usa os frameworks do macOS e não depende de serviços de nuvem próprios, Node.js, Docker ou pacotes Swift externos. Um servidor Immich é necessário para os recursos de conexão, upload e gestão; exportação local e revisão de arquivos podem ser usadas sem ele.

## Apresentação

https://github.com/user-attachments/assets/e5f2059a-b226-4cff-93a3-d166cbb0f6cb

[Assistir ou baixar o vídeo](docs/media/ponte-fotos-promo.mp4) · 36 segundos · sem áudio · 1080p.

A versão 0.8.2 corrige o enquadramento do ícone no macOS, melhora a nitidez da logo e aplica o tema Sistema imediatamente. A arte gerada aprovada permanece no app, no ícone e no vídeo. A apresentação mostra a foto atravessando o Ponte Fotos até o logo oficial do Immich e a troca automática de URLs conforme a rede. [Arte e conceito](docs/BRAND.md) · [Fonte reproduzível do vídeo](promo/README.md).

## 📦 Instalar pela release

Baixe o [Ponte Fotos 0.8.2 para Apple Silicon](https://github.com/allanpreis/ponte-fotos/releases/download/v0.8.2/Ponte-Fotos-0.8.2-arm64.zip), extraia e mova **Ponte Fotos.app** para a pasta Aplicativos do seu usuário. Encerre a versão anterior antes de substituir. O pacote tem assinatura local ad hoc; ainda não possui Developer ID nem notarização. Não é necessário desativar proteções do macOS.

[🚀 Release e arquivos](https://github.com/allanpreis/ponte-fotos/releases/tag/v0.8.2) · [📖 Guia completo com prints](docs/GUIA-COMPLETO.md) · [📝 Histórico de versões](CHANGELOG.md)

## 📸 Uma biblioteca, conectada

![Biblioteca com a logo aprovada e arquivos de demonstração](docs/media/library-v081.png)

Os prints usam uma prévia isolada e dados de demonstração. Veja também [temas e vidro](docs/media/settings-v081.png) e [Live Photo/estática na gestão](docs/media/duplicates-v081.png).

## Visual e configurações

A versão 0.7 separa as configurações da tela de fotos. Abra **Configurações** na barra lateral ou use **⌘,**:

- **Conexão**: endereços local/remoto, modo Automático/Local/Remoto, Wi-Fi doméstico e chave principal.
- **Contas e API**: contas adicionais usadas pela gestão; exige conexão validada e mantém chaves no Chaves do macOS.
- **Aparência**: Claro, Escuro ou Sistema. A escolha é salva e aplicada também às janelas de revisão e gestão.

A tela principal mantém origem, destino, lista de mídia e ações sem um painel rolável de conexão. Em janelas menores, a lista conserva sua própria rolagem; formulários extensos rolam somente dentro de Configurações.

A opção **Usar transparência e vidro** controla o acabamento da navegação. O Liquid Glass nativo é usado no macOS 26 ou superior; no macOS 14/15 são usados materiais translúcidos compatíveis. Desativar a opção ou ativar **Reduzir transparência** no macOS usa superfícies opacas. Fotos e formulários permanecem sólidos para manter a leitura. Tema e preferência de vidro são dados não sensíveis no UserDefaults; não são gravados junto de chaves de API.

O contrato visual e as referências oficiais da Apple estão em [DESIGN.md](DESIGN.md). As regras de envio e proteção de Live Photos permanecem preservadas.

## Recursos

| Área | O que faz |
| --- | --- |
| Biblioteca Apple | Lista fotos em páginas de 100 itens, permite seleção e pode baixar originais do iCloud mediante autorização. |
| Pastas e discos | Lê recursivamente a pasta escolhida, incluindo subpastas, e identifica metadados de imagem, vídeo e XMP. |
| Revisão | Permite completar ou corrigir data e GPS antes de preparar os arquivos para envio. |
| Exportação | Exporta originais com XMP complementar, sem modificar a biblioteca Apple ou arquivos de origem. |
| Upload | Envia para a linha do tempo, um álbum existente ou um novo álbum; confere checksum, data, GPS disponível e associação Live Photo. |
| Conexão por rede | Alterna entre endereço local e remoto conforme o Wi-Fi configurado, com modos manuais disponíveis. |
| Duplicatas | Encontra arquivos com checksum idêntico entre contas e álbuns selecionados, identifica Live Photos e permite revisar cópias estáticas excedentes. |
| Comparação | Compara conteúdos de dois álbuns e organiza seus vínculos sem apagar os arquivos da biblioteca. |
| Pessoa e idade | Seleciona imagens por pessoa, aniversário registrado no Immich e intervalo inclusivo de idade. |
| Contas e histórico | Usa chaves por conta e registra as últimas 20 operações de gestão, incluindo resultados incertos. |

## Requisitos

- Mac com Apple Silicon e macOS 14 ou superior. O script atual gera um executável `arm64`; Intel ainda não foi validado.
- Xcode Command Line Tools com o compilador Swift e SDK do macOS. Xcode completo também pode fornecer essas ferramentas.
- Servidor Immich 3.x acessível e chave de API da conta correspondente. A integração foi desenvolvida com Immich 3.3.5; mudanças futuras na API podem exigir ajustes.
- Espaço livre para preparar cópias temporárias e, quando solicitado, baixar originais do iCloud.
- Python 3 somente para a fixture HTTP opcional dos testes de API.

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
3. Escolha o modo **Local** ou **Remoto** e clique em **Testar conexão**.
4. Se quiser persistir os dados, use **Salvar configuração**. Eles são armazenados no Chaves do macOS.

A configuração inicial do código publicado fica vazia. Exemplos de preenchimento: URL local `http://immich.local:2283`, URL remota `https://photos.example.com`, Wi-Fi `MinhaRede`. São exemplos fictícios; substitua pelos seus dados na interface.

O aplicativo não lê arquivos `.env`. Não é necessário criar um para compilar ou usar o projeto. Chaves, URLs privadas e nome de Wi-Fi não devem ser colocados no código ou enviados ao GitHub.

### Permissões de API

Conceda apenas as permissões necessárias para o fluxo que pretende usar. Uma chave não amplia os acessos da conta aos álbuns de outras pessoas.

| Operação | Permissões relevantes |
| --- | --- |
| Conexão e envio | `server.version`, `user.read`, `asset.upload`, `asset.read` |
| Consulta e miniaturas na gestão | `user.read`, `album.read`, `asset.read`, `asset.view` |
| Pessoas | `person.read`, além das permissões de consulta |
| Criar álbum no envio | `album.create` e permissões de consulta/organização correspondentes |
| Adicionar/remover vínculos | `albumAsset.create`, `albumAsset.delete`, conforme a operação |
| Duplicatas para lixeira | `asset.delete`, além da leitura e preservação de vínculos em álbuns |
| Aplicar revisão a um recurso enviado | `asset.update`, quando necessário ao fluxo |

O servidor pode exigir escopos adicionais conforme a versão e o endpoint. Permissões ausentes ou falta de acesso ao recurso impedem a operação; confira a mensagem do app. Evite usar uma chave com `all` se não precisar de todas as funções.

### Alternância automática de endereço

Cadastre URL local, URL remota e nome exato do Wi-Fi doméstico e escolha **Automático**. Autorize **Localização** pelo botão do aplicativo: o macOS exige essa permissão para disponibilizar o nome da rede. O app usa o SSID para escolher o endereço; não consulta nem armazena sua posição.

- No Wi-Fi configurado, tenta a URL local; falhas de conectividade ou erros de servidor elegíveis podem levar à tentativa remota.
- Em outra rede, sem Wi-Fi ou sem acesso ao SSID, usa a URL remota.
- Erros de autenticação, servidor inválido ou identidade de conta divergente não provocam troca automática de destino.
- Durante um envio, mantém o cliente daquele conjunto de recursos. Mudanças de rede são tratadas em um ponto seguro, com revalidação, sem retomada parcial por byte.
- O histórico usa o perfil lógico e a conta para compartilhar continuidade entre as duas URLs.

A conferência fixa o UUID da conta, não uma identidade criptográfica do servidor. Configure apenas endereços do mesmo servidor confiável. HTTP é aceito, mas envia chave e mídia sem criptografia de transporte; prefira HTTPS, especialmente fora da rede local.

## Enviar fotos e vídeos

1. Selecione **Biblioteca Apple** e **Abrir biblioteca**, concedendo acesso ao Fotos. Ou use **Escolher pasta…** e selecione a origem em um disco/pasta.
2. Escolha itens e confira as indicações de data/GPS. A opção de baixar originais do iCloud depende do acesso à conta/biblioteca do próprio macOS.
3. Use **Revisar selecionada** para completar data ou localização ausente. Sem data confiável, o envio exige revisão; o app não usa automaticamente a criação do arquivo como data de captura.
4. Escolha o destino: sem álbum, álbum existente ou novo álbum.
5. Envie uma pequena amostra e confira o resultado no Immich antes de um lote grande.

Originais preservam seus bytes; um XMP complementar carrega data e localização da biblioteca/revisão. O processo de preparação não modifica o arquivo de origem. O XMP associado de uma pasta é mesclado preservando campos adicionais.

Para Live Photos do Fotos da Apple, o vídeo de movimento é enviado primeiro e associado à imagem principal. HEIC e MOV de pastas externas são itens independentes: o app não presume um par apenas pelo nome. RAW e JPEG associados são preservados como recursos distintos, sem empilhamento automático.

**Pausar após este item** conclui o conjunto atual. Histórico e checksum ajudam a reutilizar recursos já enviados e ainda válidos. Interrupções podem produzir resultados pendentes ou incertos: confira no servidor antes de repetir.

### Conferência dos metadados

O fluxo compara checksum, instante de captura (tolerância inferior a um segundo), GPS disponível (tolerância de 0,00001 grau) e associação do vídeo Live. Uma resposta tardia ou divergente permanece pendente/divergente, sem marcar sucesso indevido.

O PhotoKit fornece um instante absoluto; a prévia usa o fuso do Mac e o XMP complementar usa UTC. Confira fotos de viagens e correções manuais na linha do tempo. O app exporta originais, sem prometer reproduzir edições, álbuns Apple, legendas, palavras-chave, rostos ou todos os metadados proprietários da Apple. Favorito é enviado, mas não faz parte dessa conferência.

## Gerenciar o Immich

Com a conexão validada, abra **Gerenciar Immich** na barra lateral. Em **Contas e API**, clique em **Usar conta da conexão atual** ou adicione uma conta com a própria chave. Contas adicionais são salvas separadamente no Chaves; a conta atual pode ser usada apenas em memória nessa sessão. Nenhuma chave é copiada de outro dashboard.

### Álbuns e duplicatas

Selecione os álbuns e consulte. A comparação é por checksum exato e tipo de mídia, incluindo a imagem principal de Live Photos. Nome igual ou aparência semelhante, isoladamente, não comprovam duplicação. Arquivos recompactados, editados ou com bytes diferentes podem ficar fora do resultado.

Cada cópia mostra conta, nome, formato, metadados e álbuns acessíveis. **Live Photo · com movimento** e **Foto estática** aparecem em blocos próprios. Uma Live Photo é sugerida para manter; o envio de qualquer Live Photo à lixeira é bloqueado. Grupos sem conta proprietária conectada também podem ser bloqueados.

Antes da lixeira, o app revalida conteúdo, proprietário, movimento, acesso e vínculos; adiciona e confirma os álbuns acessíveis na cópia mantida antes da primeira exclusão. A exclusão é recuperável no Immich (`force: false`); o aplicativo não esvazia a lixeira. Vínculos invisíveis às contas conectadas não podem ser preservados pelo app.

### Comparar álbuns

Compara dois álbuns. Por padrão mostra conteúdos presentes nos dois; é possível incluir exclusivos. Para cada grupo, escolha deixar como está, manter nos dois ou reunir em um dos álbuns. Adições são confirmadas antes de remover vínculos de origem. Os arquivos permanecem na biblioteca do servidor.

### Pessoa e idade

Selecione conta, pessoa, origem, destino e intervalo de idade. A pessoa precisa ter aniversário cadastrado no Immich. A seleção considera a data local de captura e os limites inclusivos; aniversário em 29 de fevereiro passa a 1º de março em ano não bissexto. A origem pode ser um álbum ou todos os álbuns acessíveis à conta, exceto o destino.

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
| Chaves do macOS | Perfil de conexão, URLs, SSID e chave principal; chaves adicionais da gestão em serviço separado. |
| `~/Library/Application Support/PonteFotos/reviews.json` | Revisões de metadados. |
| `~/Library/Application Support/PonteFotos/history/` | Histórico de envio, IDs e checksums. |
| `~/Library/Application Support/PonteFotos/management/` | Histórico da gestão por perfil, salvo com modo de arquivo `0600`. |
| `~/Library/Application Support/PonteFotos/staging/` | Cópias temporárias; uma interrupção abrupta pode deixar resíduos. |
| Pasta escolhida para exportação | Originais e XMP exportados pelo usuário. |

Históricos, revisões e exportações podem conter nomes, IDs, datas e GPS pessoais. Não os publique em issues, logs ou repositórios. **Esquecer conexão salva** remove a conexão principal do Chaves; os campos atuais permanecem na memória até fechar. Isso não remove automaticamente contas adicionais ou históricos locais.

O `.gitignore` exclui `.env`, credenciais usuais, builds, bundles, arquivos compactados e estado local. Ele não remove segredos já versionados e não substitui revisão antes de cada commit. O repositório contém apenas código, assets do aplicativo, documentação e fixtures sintéticas.

## Desenvolvimento e testes

```sh
zsh build.sh
zsh test-connection.sh
zsh test-management.sh
zsh test-media.sh
zsh test-appearance.sh
plutil -lint Info.plist
codesign --verify --deep --strict "build/Ponte Fotos.app"
```

Os testes usam arquivos sintéticos e interceptação HTTP em memória, sem depender de um Immich real ou de chaves do usuário. A suíte de mídia gera JPEG/MOV temporários; a codificação do vídeo requer codecs disponíveis no macOS e pode falhar em uma sandbox restrita.

A fixture `Tests/api_fixture.py` é opcional, escuta somente em `127.0.0.1:18761` e é usada por `Tests/APISmoke.swift`; não é um servidor para produção. Testes automatizados não substituem a validação manual de PhotoKit, permissões, troca física de rede e compatibilidade com a versão do seu Immich.

### Estrutura

```text
Sources/
  App.swift                   Interface principal e fluxo de envio
  DesignSystem.swift          Temas, política de vidro e componentes visuais
  SettingsView.swift          Conexão, contas e aparência
  Metadata.swift              Metadados e modelos de mídia
  ExternalMedia.swift         Leitura de pastas, imagens, vídeos e XMP
  Review.swift                Revisão de data/GPS
  Immich.swift                Cliente de envio e conferência
  ConnectionStore.swift       Persistência no Chaves
  NetworkConnection.swift     Perfil, SSID e observação da rede
  ConnectionResolver.swift    Escolha e validação de endereço
  ConnectionHistory.swift     Continuidade do envio entre URLs
  ImmichManagementAPI.swift   API, contas e histórico de gestão
  ImmichDuplicates.swift      Análise e revisão de duplicatas
  ImmichOrganization.swift    Comparação e pessoa/idade
  ImmichWorkspace.swift       Interface das cinco abas
Assets/                       Logo e ícones do app
Tests/                        Testes e fixtures sintéticas
Info.plist                    Versão, identificador e permissões
build.sh                      Compilação e assinatura local
```

## Solução de problemas

| Sintoma | O que conferir |
| --- | --- |
| Servidor não responde | Immich em execução, URL/porta, rota, DNS e firewall. O app não precisa que você altere o código para configurar o endereço. |
| Wi-Fi indisponível | Permissão de Localização para o Ponte Fotos, Wi-Fi ativo e SSID exato; use um modo manual quando necessário. |
| Biblioteca vazia ou acesso negado | Ajustes do Sistema → Privacidade e Segurança → Fotos; confirme acesso e biblioteca selecionada no Fotos. |
| Original do iCloud indisponível | Acesso ao iCloud, internet, espaço livre e opção de baixar originais. |
| Ação da gestão bloqueada | Chave da conta proprietária, permissões da API, acesso aos álbuns e exclusões de mídia do fluxo. |
| Duplicatas visuais não aparecem | O método exige checksum exato; não faz reconhecimento perceptual de imagens semelhantes. |
| Assinatura inválida | Recompile em pasta local, confira `codesign` e instale o bundle fora de sincronizadores. |
| Resultado incerto | Confira histórico e servidor; não repita cegamente a operação. |

## Estado do projeto

Aplicativo em evolução, com assinatura local e testes automatizados. Faça backup da biblioteca e do servidor e comece com lotes pequenos antes de usar ferramentas que alteram vínculos ou enviam cópias à lixeira.

Este é um projeto independente, sem vínculo oficial com Apple ou Immich. Uma licença de redistribuição ainda não foi definida neste repositório.

## 🚀 Publicação de versões

Cada nova versão deve ser entregue com commit, tag e GitHub Release, incluindo pacote, checksum, notas e documentação atualizada. O procedimento está em [docs/RELEASING.md](docs/RELEASING.md).
