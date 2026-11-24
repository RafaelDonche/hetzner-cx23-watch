#!/usr/bin/env bash
# Consulta a API da Hetzner e avisa pelo ntfy quando muda o conjunto de locais em que o tipo de
# servidor (padrão: cx23) aparece como disponível.
#
# O campo lido é `server_types[].locations[].available`. A própria Hetzner avisa que ele é só um
# indicador, não garantia: a criação ainda pode falhar se o estoque acabar no meio do caminho.
#
# Variáveis:
#   HCLOUD_TOKEN   token de API da Hetzner, só leitura (obrigatória)
#   NTFY_TOPIC     tópico do ntfy.sh que recebe o aviso (obrigatória)
#   TIPO           tipo de servidor (padrão: cx23)
#   ESTADO         arquivo com os locais da última consulta (padrão: estado.txt)
#   TESTAR_AVISO   "true" manda um aviso de teste, sem mexer no estado
#
# Escreve `mudou=true|false` em $GITHUB_OUTPUT quando roda no GitHub Actions.

set -euo pipefail

: "${HCLOUD_TOKEN:?defina HCLOUD_TOKEN}"
: "${NTFY_TOPIC:?defina NTFY_TOPIC}"
TIPO="${TIPO:-cx23}"
ESTADO="${ESTADO:-estado.txt}"
CONSOLE="https://console.hetzner.cloud/projects"

avisar() {
    local titulo="$1" mensagem="$2" prioridade="$3" etiqueta="$4"
    jq -n \
        --arg topic "$NTFY_TOPIC" --arg title "$titulo" --arg message "$mensagem" \
        --argjson priority "$prioridade" --arg tag "$etiqueta" --arg click "$CONSOLE" \
        '{topic: $topic, title: $title, message: $message, priority: $priority, tags: [$tag], click: $click}' |
        curl -fsS -o /dev/null -H 'Content-Type: application/json' --data-binary @- https://ntfy.sh/
}

saida() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "mudou=$1" >>"$GITHUB_OUTPUT"
    fi
}

if [[ "${TESTAR_AVISO:-false}" == "true" ]]; then
    avisar "Teste do aviso da Hetzner" "Se você está lendo isto, o aviso do ${TIPO^^} funciona." 3 "white_check_mark"
    echo "Aviso de teste enviado."
    saida false
    exit 0
fi

# Junta todas as páginas da listagem de tipos de servidor.
tipos='[]'
pagina=1
while [[ -n "$pagina" && "$pagina" != "null" ]]; do
    resposta=$(curl -fsS -H "Authorization: Bearer $HCLOUD_TOKEN" \
        "https://api.hetzner.cloud/v1/server_types?per_page=50&page=$pagina")
    tipos=$(jq -c --argjson acumulado "$tipos" '$acumulado + .server_types' <<<"$resposta")
    pagina=$(jq -r '.meta.pagination.next_page' <<<"$resposta")
done

if ! jq -e --arg t "$TIPO" 'any(.[]; .name == $t)' <<<"$tipos" >/dev/null; then
    echo "O tipo '$TIPO' não aparece na listagem da Hetzner." >&2
    exit 1
fi

# Locais disponíveis, em ordem e separados por vírgula (vazio = nenhum).
disponiveis=$(jq -r --arg t "$TIPO" '
    [ .[] | select(.name == $t) | .locations[]?
      | select(.available == true)
      | (.name // .location // (.id | tostring)) ]
    | sort | join(",")' <<<"$tipos")

anterior=$(cat "$ESTADO" 2>/dev/null || true)
echo "Agora: ${disponiveis:-nenhum} | antes: ${anterior:-nenhum}"

if [[ "$disponiveis" == "$anterior" ]]; then
    saida false
    exit 0
fi

echo "$disponiveis" >"$ESTADO"

if [[ -n "$disponiveis" ]]; then
    avisar "${TIPO^^} disponível na Hetzner" \
        "Disponível em: ${disponiveis}. O projeto decidiu por hel1 (Helsinki). Corra: o estoque costuma acabar rápido." \
        5 "rotating_light"
else
    avisar "${TIPO^^} esgotou de novo" "Não aparece mais disponível em nenhum local." 2 "hourglass"
fi

saida true
