# hetzner-cx23-watch

Consulta a API da Hetzner a cada 10 minutos e manda uma notificação no celular (pelo
[ntfy](https://ntfy.sh)) quando o servidor **CX23** aparece disponível. Também avisa, com prioridade
baixa, quando ele esgota de novo. Enquanto nada muda, fica em silêncio.

É um script de shell (`verificar.sh`, com `curl` e `jq`) rodando no GitHub Actions. O último estado
fica em `estado.txt`, e um commit só acontece quando ele muda.

## Configuração (uma vez)

1. **Token da Hetzner, só leitura.** No Console da Hetzner, abra o projeto, vá em *Security* →
   *API tokens* → *Generate API token* e escolha a permissão **Read**. Copie o token: ele aparece
   uma vez só.
2. **ntfy no celular.** Instale o app ntfy (Android ou iOS) e inscreva-se num tópico com nome
   difícil de adivinhar. Quem souber o nome lê os avisos. Para gerar um:
   `echo cx23-$(openssl rand -hex 12)`.
3. **Os dois segredos no GitHub.** Cada comando pede o valor e não mostra na tela:

   ```
   gh secret set HCLOUD_TOKEN -R RafaelDonche/hetzner-cx23-watch
   gh secret set NTFY_TOPIC  -R RafaelDonche/hetzner-cx23-watch
   ```

4. **Teste do aviso.** Tem que chegar uma notificação no celular em menos de um minuto:

   ```
   gh workflow run verificar.yml -R RafaelDonche/hetzner-cx23-watch -f testar_aviso=true
   ```

5. **Uma consulta de verdade**, para conferir o token (o log mostra `Agora: ... | antes: ...`):

   ```
   gh workflow run verificar.yml -R RafaelDonche/hetzner-cx23-watch
   gh run watch -R RafaelDonche/hetzner-cx23-watch
   ```

## Bom saber

- `available` é, nas palavras da Hetzner, "só um indicador, não garantia". Ao receber o aviso, crie
  a máquina logo: o estoque pode acabar no meio do caminho.
- Se o token parar de funcionar, a execução falha e o GitHub manda e-mail de falha.
- Para vigiar outro tipo, mude `TIPO` no passo `verificar` do workflow (padrão: `cx23`).
- Para desligar depois de comprar: `gh workflow disable verificar.yml -R RafaelDonche/hetzner-cx23-watch`.
- O GitHub desliga workflows agendados de repositórios públicos depois de 60 dias sem atividade.
