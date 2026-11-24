# hetzner-cx23-watch

Consulta a API da Hetzner a cada 5 minutos e manda uma notificação no celular (pelo
[ntfy](https://ntfy.sh)) quando o servidor **CX23** aparece disponível ou esgota de novo. Com a
criação automática ligada, **cria a máquina sozinho** na primeira janela de estoque no local
escolhido e depois se desliga.

É um script de shell (`verificar.sh`, com `curl` e `jq`) rodando no GitHub Actions. O último estado
fica em `estado.txt`, e um commit só acontece quando ele muda.

A documentação completa (por que existe, segredos, roteiro de criação à mão, o que fazer depois)
mora no repositório do projeto, em `docs/VERIFICADOR-CX23.md`.

## Segredos

| Segredo | O que é |
| --- | --- |
| `HCLOUD_TOKEN` | Token de API da Hetzner. **Read** basta para vigiar; **Read & Write** para criar |
| `NTFY_TOPIC` | Nome do tópico do ntfy. Funciona como senha |

```
gh secret set HCLOUD_TOKEN -R RafaelDonche/hetzner-cx23-watch
gh secret set NTFY_TOPIC  -R RafaelDonche/hetzner-cx23-watch
```

## Comandos

```
# Aviso de teste no celular
gh workflow run verificar.yml -R RafaelDonche/hetzner-cx23-watch -f testar_aviso=true

# Conferir tudo que a criação precisa (chave, firewall, imagem, token com escrita), sem criar
gh workflow run verificar.yml -R RafaelDonche/hetzner-cx23-watch -f testar_criacao=true

# Consultar agora e acompanhar
gh workflow run verificar.yml -R RafaelDonche/hetzner-cx23-watch
gh run watch -R RafaelDonche/hetzner-cx23-watch

# Desligar e religar
gh workflow disable verificar.yml -R RafaelDonche/hetzner-cx23-watch
gh workflow enable  verificar.yml -R RafaelDonche/hetzner-cx23-watch
```

A criação automática é ligada por `CRIAR` no workflow, e o local por `LOCAIS_PARA_CRIAR`.

## Segurança

- O workflow só roda pelo relógio ou por quem tem escrita no repositório. Não há gatilho de pull
  request, então um fork nunca recebe os segredos.
- O log é público: o script nunca imprime resposta inteira da API nem o IP da máquina criada.
- A única ação de terceiros é o `actions/checkout`, oficial do GitHub, fixado pelo SHA.
- Depois de criar a máquina, **revogue o token de escrita** no Console da Hetzner.
