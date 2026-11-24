# hetzner-cx23-watch

**Receba um push no celular assim que um tipo de servidor esgotado da Hetzner Cloud voltar ao
estoque e, se quiser, deixe que ele crie o servidor para você.**

[Read in English](README.md)

## Por quê

Desde meados de 2026 a linha barata da Hetzner (CX23 e vizinhos) aparece como "temporarily not
available" quase o tempo todo. Mas ela não sumiu: rastreadores da comunidade mostram o estoque
voltando **várias vezes por dia, em todos os locais europeus, e acabando em minutos**. Atualizar o
Console não resolve, e quando um e-mail de alerta é lido a janela quase sempre já fechou.

Este repositório é um verificador pequeno, que roda de graça no GitHub Actions:

- consulta a API da Hetzner a cada 5 minutos (`server_types[].locations[].available`);
- manda um push pelo [ntfy](https://ntfy.sh) quando a disponibilidade muda;
- **cria o servidor sozinho, se você quiser**, na primeira janela, nos locais que você aceita, com
  a sua chave SSH, firewall, imagem, rótulos e backup, e depois se desliga.

Sem servidor e sem dependências: um script de shell (`curl` + `jq`) e um workflow.

## Configuração (uns 5 minutos)

1. **Crie a sua cópia:** **Use this template** → *Create a new repository*. Deixe **público** para
   ter minutos ilimitados no Actions (a cada 5 minutos são ~8.600 execuções por mês, mais que os
   2.000 minutos grátis de um repositório privado). Segredos continuam secretos num repositório
   público; veja [Segurança](#segurança).
2. **Token da Hetzner:** Console → seu projeto → *Security* → *API tokens* → *Generate*. Permissão
   **Read** para só vigiar, **Read & Write** para criar.
3. **ntfy:** instale o app (Android ou iOS) e inscreva-se num tópico difícil de adivinhar (quem
   souber o nome lê os avisos), por exemplo `echo cx23-$(openssl rand -hex 12)`.
4. **Segredos** (*Settings → Secrets and variables → Actions → Secrets*), ou pelo GitHub CLI:

   ```
   gh secret set HCLOUD_TOKEN -R <você>/<repo>
   gh secret set NTFY_TOPIC  -R <você>/<repo>
   ```

5. **Variáveis** (*Settings → Secrets and variables → Actions → Variables*), todas opcionais para só
   vigiar:

   | Variável | Padrão | O que é |
   | --- | --- | --- |
   | `SERVER_TYPE` | `cx23` | Tipo de servidor vigiado |
   | `LANGUAGE` | `en` | `en` ou `pt-BR`, para o log e os avisos |
   | `CREATE` | `false` | `true` cria o servidor na primeira janela |
   | `LOCATIONS` | — | Locais aceitos para criar, em ordem de preferência, ex.: `hel1,nbg1` |
   | `SERVER_NAME` | — | Nome do servidor (obrigatório para criar) |
   | `SSH_KEY` | — | Nome de uma chave SSH já cadastrada no projeto (obrigatório para criar) |
   | `FIREWALL` | — | Nome de um firewall do projeto (opcional) |
   | `IMAGE` | `ubuntu-24.04` | Imagem do sistema |
   | `BACKUPS` | `true` | Liga o backup da Hetzner (+20% do preço) |
   | `LABELS` | `created-by=hetzner-cx23-watch` | Rótulos do servidor, `chave=valor,chave=valor` |

6. **Teste** pela aba *Actions* (*Hetzner stock watch* → *Run workflow*) ou:

   ```
   # um push de teste deve chegar em menos de um minuto
   gh workflow run watch.yml -R <você>/<repo> -f test_notification=true

   # confere chave SSH, firewall, imagem e permissão de escrita, sem criar nada
   gh workflow run watch.yml -R <você>/<repo> -f test_creation=true
   ```

Só mude `CREATE` para `true` depois que o `test_creation` disser "Pronto para criar".

## Como ele se comporta

- **Silêncio enquanto nada muda.** Um push quando o tipo aparece (com os locais) e um de prioridade
  baixa quando esgota de novo. O último estado fica em `state.txt`, e o histórico de commits dele é
  um registro de disponibilidade.
- **Nunca cria dois servidores.** Antes de criar, confere se já existe um com o `SERVER_NAME`.
- **Janela fechada não é erro.** Se o estoque acabar entre a consulta e o pedido
  (`resource_unavailable`), ele espera a próxima.
- **Para sozinho.** Depois de criar (ou de achar o servidor já criado), manda um push e desliga o
  workflow.
- **A cobrança começa na hora da criação**, pelo preço normal da Hetzner.

## Segurança

- **Ninguém lê um segredo de volta**, nem o dono; o GitHub mostra `***` nos logs.
- **Fork nunca recebe os seus segredos.** O workflow só roda pelo relógio ou por disparo manual de
  quem tem escrita no repositório; não há gatilho de pull request.
- **O log é público**, então o script nunca imprime resposta inteira da API nem o IP do servidor.
  Variáveis do repositório não são secretas e aparecem no log.
- **Uma única ação de terceiros**, `actions/checkout`, fixada pelo SHA do commit.
- **Um token Read & Write cria e apaga servidores no projeto dele.** Revogue no Console da Hetzner
  assim que o servidor for criado; o push de "servidor criado" lembra disso.

## Limites

- A Hetzner chama o `available` de indicador, não de garantia.
- O GitHub pode atrasar execuções agendadas em alguns minutos em horário de pico.
- O GitHub desliga workflows agendados de repositório público depois de 60 dias sem atividade.
- Sem vínculo com a Hetzner.

## Licença

[MIT](LICENSE)
