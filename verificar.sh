#!/usr/bin/env bash
# Vigia a disponibilidade de um tipo de servidor na Hetzner (padrão: cx23), avisa pelo ntfy quando
# ela muda e, com CRIAR=true, cria a máquina sozinho na primeira janela de estoque.
#
# O campo lido é `server_types[].locations[].available`. A própria Hetzner avisa que ele é só um
# indicador, não garantia: a criação ainda pode falhar se o estoque acabar no meio do caminho, e
# nesse caso o script só espera a próxima janela.
#
# O log deste script é PÚBLICO (repositório público). Por isso ele nunca imprime resposta inteira
# da API, nem o IP da máquina criada: o IP de origem atrás da Cloudflare não deve vazar.
#
# Variáveis:
#   HCLOUD_TOKEN      token de API da Hetzner (obrigatória). Leitura basta para vigiar; para
#                     criar, precisa de leitura e escrita
#   NTFY_TOPIC        tópico do ntfy.sh que recebe o aviso (obrigatória)
#   TIPO              tipo de servidor (padrão: cx23)
#   ESTADO            arquivo com os locais da última consulta (padrão: estado.txt)
#   CRIAR             "true" cria a máquina quando aparecer num dos LOCAIS_PARA_CRIAR
#   LOCAIS_PARA_CRIAR locais aceitos para criar, em ordem de preferência (padrão: hel1)
#   NOME_SERVIDOR     nome da máquina (padrão: dtqrcode-producao)
#   IMAGEM            imagem do sistema (padrão: ubuntu-24.04)
#   CHAVE_SSH         nome da chave SSH cadastrada no projeto (padrão: rafael-windows)
#   FIREWALL          nome do firewall do projeto (padrão: dtqrcode-web)
#   TESTAR_AVISO      "true" manda um aviso de teste e sai
#   TESTAR_CRIACAO    "true" confere tudo que a criação precisa (chave, firewall, imagem e se o
#                     token pode escrever), sem criar nada, e sai
#
# Saídas em $GITHUB_OUTPUT (no GitHub Actions):
#   mudou=true|false   o estado.txt mudou e precisa de commit
#   criada=true|false  a máquina existe; o workflow se desliga

set -euo pipefail

: "${HCLOUD_TOKEN:?defina HCLOUD_TOKEN}"
: "${NTFY_TOPIC:?defina NTFY_TOPIC}"
TIPO="${TIPO:-cx23}"
ESTADO="${ESTADO:-estado.txt}"
CRIAR="${CRIAR:-false}"
LOCAIS_PARA_CRIAR="${LOCAIS_PARA_CRIAR:-hel1}"
NOME_SERVIDOR="${NOME_SERVIDOR:-dtqrcode-producao}"
IMAGEM="${IMAGEM:-ubuntu-24.04}"
CHAVE_SSH="${CHAVE_SSH:-rafael-windows}"
FIREWALL="${FIREWALL:-dtqrcode-web}"
API="https://api.hetzner.cloud/v1"
CONSOLE="https://console.hetzner.cloud/projects"

mudou=false
criada=false

saidas() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        {
            echo "mudou=$mudou"
            echo "criada=$criada"
        } >>"$GITHUB_OUTPUT"
    fi
}
trap saidas EXIT

avisar() {
    local titulo="$1" mensagem="$2" prioridade="$3" etiqueta="$4"
    jq -n \
        --arg topic "$NTFY_TOPIC" --arg title "$titulo" --arg message "$mensagem" \
        --argjson priority "$prioridade" --arg tag "$etiqueta" --arg click "$CONSOLE" \
        '{topic: $topic, title: $title, message: $message, priority: $priority, tags: [$tag], click: $click}' |
        curl -fsS -o /dev/null -H 'Content-Type: application/json' --data-binary @- https://ntfy.sh/
}

# Chama a API da Hetzner. Deixa o corpo em $CORPO e o status HTTP em $STATUS.
api() {
    local metodo="$1" caminho="$2" dados="${3:-}" resposta
    local args=(-sS -X "$metodo" -H "Authorization: Bearer $HCLOUD_TOKEN" -w $'\n%{http_code}')
    if [[ -n "$dados" ]]; then
        args+=(-H 'Content-Type: application/json' --data-binary "$dados")
    fi
    resposta=$(curl "${args[@]}" "$API$caminho")
    STATUS="${resposta##*$'\n'}"
    CORPO="${resposta%$'\n'*}"
}

# Só o código e a mensagem do erro, nunca o corpo inteiro (o log é público).
erro_da_api() {
    jq -r '"\(.error.code // "sem_codigo"): \(.error.message // "sem mensagem")"' <<<"$CORPO" 2>/dev/null ||
        echo "HTTP $STATUS"
}

falhar() {
    echo "$1" >&2
    avisar "Verificador da Hetzner com problema" "$1" 4 "warning" || true
    exit 1
}

# Confere o que a criação precisa e deixa o id do firewall em $FIREWALL_ID.
preparar_criacao() {
    api GET "/ssh_keys?name=$CHAVE_SSH"
    [[ "$STATUS" == 200 ]] || falhar "Não consegui ler as chaves SSH: $(erro_da_api)"
    [[ $(jq '.ssh_keys | length' <<<"$CORPO") -ge 1 ]] || falhar "A chave SSH '$CHAVE_SSH' não existe no projeto."

    api GET "/firewalls?name=$FIREWALL"
    [[ "$STATUS" == 200 ]] || falhar "Não consegui ler os firewalls: $(erro_da_api)"
    FIREWALL_ID=$(jq -r '.firewalls[0].id // empty' <<<"$CORPO")
    [[ -n "$FIREWALL_ID" ]] || falhar "O firewall '$FIREWALL' não existe no projeto."
    FIREWALL_JSON=$(jq -c '.firewalls[0] | {name, labels}' <<<"$CORPO")

    api GET "/images?name=$IMAGEM&architecture=x86"
    [[ "$STATUS" == 200 ]] || falhar "Não consegui ler as imagens: $(erro_da_api)"
    [[ $(jq '.images | length' <<<"$CORPO") -ge 1 ]] || falhar "A imagem '$IMAGEM' não existe."
}

servidor_existe() {
    api GET "/servers?name=$NOME_SERVIDOR"
    [[ "$STATUS" == 200 ]] || falhar "Não consegui ler os servidores: $(erro_da_api)"
    [[ $(jq '.servers | length' <<<"$CORPO") -ge 1 ]]
}

# --- Modos de teste ------------------------------------------------------------------------

if [[ "${TESTAR_AVISO:-false}" == "true" ]]; then
    avisar "Teste do aviso da Hetzner" "Se você está lendo isto, o aviso do ${TIPO^^} funciona." 3 "white_check_mark"
    echo "Aviso de teste enviado."
    exit 0
fi

if [[ "${TESTAR_CRIACAO:-false}" == "true" ]]; then
    preparar_criacao
    # Escrita sem efeito: regrava o firewall com o mesmo nome e os mesmos rótulos. Só passa se o
    # token tiver permissão de escrita, que é o que a criação vai precisar.
    api PUT "/firewalls/$FIREWALL_ID" "$FIREWALL_JSON"
    [[ "$STATUS" == 200 ]] || falhar "O token não pode escrever no projeto (precisa de 'Read & Write'): $(erro_da_api)"
    if servidor_existe; then
        situacao="Já existe uma máquina chamada $NOME_SERVIDOR."
    else
        situacao="Nenhuma máquina chamada $NOME_SERVIDOR ainda."
    fi
    msg="Pronto para criar: chave $CHAVE_SSH, firewall $FIREWALL, imagem $IMAGEM, token com escrita. $situacao Criação automática: $CRIAR, em $LOCAIS_PARA_CRIAR."
    echo "$msg"
    avisar "Teste da criação automática" "$msg" 3 "white_check_mark"
    exit 0
fi

# --- Disponibilidade -----------------------------------------------------------------------

tipos='[]'
pagina=1
while [[ -n "$pagina" && "$pagina" != "null" ]]; do
    api GET "/server_types?per_page=50&page=$pagina"
    [[ "$STATUS" == 200 ]] || falhar "Não consegui ler os tipos de servidor: $(erro_da_api)"
    tipos=$(jq -c --argjson acumulado "$tipos" '$acumulado + .server_types' <<<"$CORPO")
    pagina=$(jq -r '.meta.pagination.next_page' <<<"$CORPO")
done

if ! jq -e --arg t "$TIPO" 'any(.[]; .name == $t)' <<<"$tipos" >/dev/null; then
    falhar "O tipo '$TIPO' não aparece na listagem da Hetzner."
fi

# Locais disponíveis, em ordem e separados por vírgula (vazio = nenhum).
disponiveis=$(jq -r --arg t "$TIPO" '
    [ .[] | select(.name == $t) | .locations[]?
      | select(.available == true)
      | (.name // .location // (.id | tostring)) ]
    | sort | join(",")' <<<"$tipos")

anterior=$(cat "$ESTADO" 2>/dev/null || true)
echo "Agora: ${disponiveis:-nenhum} | antes: ${anterior:-nenhum}"

if [[ "$disponiveis" != "$anterior" ]]; then
    echo "$disponiveis" >"$ESTADO"
    mudou=true
fi

# --- Criação automática --------------------------------------------------------------------

local_escolhido=""
if [[ "$CRIAR" == "true" ]]; then
    for candidato in ${LOCAIS_PARA_CRIAR//,/ }; do
        if [[ ",$disponiveis," == *",$candidato,"* ]]; then
            local_escolhido="$candidato"
            break
        fi
    done
fi

if [[ -n "$local_escolhido" ]]; then
    if servidor_existe; then
        echo "Já existe uma máquina chamada $NOME_SERVIDOR; nada a criar."
        avisar "Máquina já existe" "$NOME_SERVIDOR já existe no projeto. O verificador vai se desligar." 3 "information_source"
        criada=true
        exit 0
    fi

    preparar_criacao
    pedido=$(jq -n \
        --arg name "$NOME_SERVIDOR" --arg type "$TIPO" --arg location "$local_escolhido" \
        --arg image "$IMAGEM" --arg key "$CHAVE_SSH" --argjson firewall "$FIREWALL_ID" \
        '{name: $name, server_type: $type, location: $location, image: $image,
          ssh_keys: [$key], firewalls: [{firewall: $firewall}],
          public_net: {enable_ipv4: true, enable_ipv6: true},
          start_after_create: true,
          labels: {projeto: "dtqrcode", ambiente: "producao", criado_por: "verificador"}}')

    echo "Criando $NOME_SERVIDOR ($TIPO) em $local_escolhido..."
    api POST "/servers" "$pedido"

    if [[ "$STATUS" != 201 ]]; then
        codigo=$(jq -r '.error.code // ""' <<<"$CORPO" 2>/dev/null || true)
        case "$codigo" in
        resource_unavailable | resource_limit_exceeded)
            # A janela fechou entre a consulta e o pedido. Tenta na próxima.
            echo "Não deu: $(erro_da_api). Tento de novo na próxima janela."
            ;;
        uniqueness_error)
            echo "A máquina já existe (criada por outro caminho)."
            criada=true
            avisar "Máquina já existe" "$NOME_SERVIDOR já existe no projeto. O verificador vai se desligar." 3 "information_source"
            ;;
        *)
            falhar "A criação de $NOME_SERVIDOR falhou: $(erro_da_api)"
            ;;
        esac
        exit 0
    fi

    servidor_id=$(jq -r '.server.id' <<<"$CORPO")
    criada=true
    echo "Máquina criada (id $servidor_id). Ligando o backup..."

    # O backup é uma ação separada, e a máquina recém-criada fica travada por alguns segundos.
    backup="não ligou: ligue à mão no Console (Backups)"
    for _ in $(seq 1 12); do
        api POST "/servers/$servidor_id/actions/enable_backup"
        if [[ "$STATUS" == 201 ]]; then
            backup="ligado"
            break
        fi
        sleep 10
    done
    echo "Backup: $backup."

    avisar "Máquina criada na Hetzner!" \
        "$NOME_SERVIDOR ($TIPO) criada em $local_escolhido. Backup: $backup. O IP está no Console. Agora: revogue o token de escrita da Hetzner. O verificador se desligou." \
        5 "tada"
    exit 0
fi

# --- Só aviso ------------------------------------------------------------------------------

if [[ "$mudou" == "true" ]]; then
    if [[ -n "$disponiveis" ]]; then
        extra="Corra: o estoque costuma acabar em minutos."
        if [[ "$CRIAR" == "true" ]]; then
            extra="Fora dos locais da criação automática ($LOCAIS_PARA_CRIAR): nada foi criado."
        fi
        avisar "${TIPO^^} disponível na Hetzner" "Disponível em: ${disponiveis}. $extra" 5 "rotating_light"
    else
        avisar "${TIPO^^} esgotou de novo" "Não aparece mais disponível em nenhum local." 2 "hourglass"
    fi
fi
