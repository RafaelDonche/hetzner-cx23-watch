#!/usr/bin/env bash
# hetzner-cx23-watch — watches Hetzner Cloud stock for a server type (default: cx23), sends a push
# notification through ntfy when availability changes and, with CREATE=true, creates the server
# by itself in the first stock window, so a short restock is not missed while you sleep.
#
# Availability comes from `server_types[].locations[].available`. Hetzner describes that field as
# an indicator, not a guarantee: the create request can still be refused if the stock runs out in
# between. When that happens the script simply waits for the next window.
#
# The log of a public repository is PUBLIC. This script never prints a full API response nor the
# IP address of the created server.
#
# Configuration (environment variables; the workflow fills them from repository variables):
#   HCLOUD_TOKEN      Hetzner Cloud API token (required). Read is enough to watch; creating needs
#                     Read & Write
#   NTFY_TOPIC        ntfy.sh topic that receives the notifications (required)
#   SERVER_TYPE       server type to watch (default: cx23)
#   LANGUAGE          language of logs and notifications: en or pt-BR (default: en)
#   STATE_FILE        file holding the last seen locations (default: state.txt)
#   CREATE            "true" creates the server when it shows up in one of LOCATIONS
#   LOCATIONS         locations accepted for creation, in order of preference (e.g. hel1,nbg1)
#   SERVER_NAME       name of the server to create (required when CREATE=true)
#   SSH_KEY           name of an SSH key in the project (required when CREATE=true)
#   FIREWALL          name of a firewall in the project to attach (optional)
#   IMAGE             system image (default: ubuntu-24.04)
#   BACKUPS           "true" enables Hetzner backups after creating (default: true)
#   LABELS            labels for the server, as key=value,key=value
#                     (default: created-by=hetzner-cx23-watch)
#   TEST_NOTIFICATION "true" sends a test notification and exits
#   TEST_CREATION     "true" checks everything creation needs (SSH key, firewall, image, write
#                     permission) without creating anything, and exits
#
# Outputs in $GITHUB_OUTPUT (GitHub Actions):
#   changed=true|false  the state file changed and must be committed
#   created=true|false  the server exists; the workflow disables itself

set -euo pipefail

: "${HCLOUD_TOKEN:?set HCLOUD_TOKEN}"
: "${NTFY_TOPIC:?set NTFY_TOPIC}"
SERVER_TYPE="${SERVER_TYPE:-cx23}"
LANGUAGE="${LANGUAGE:-en}"
STATE_FILE="${STATE_FILE:-state.txt}"
CREATE="${CREATE:-false}"
LOCATIONS="${LOCATIONS:-}"
SERVER_NAME="${SERVER_NAME:-}"
SSH_KEY="${SSH_KEY:-}"
FIREWALL="${FIREWALL:-}"
IMAGE="${IMAGE:-ubuntu-24.04}"
BACKUPS="${BACKUPS:-true}"
LABELS="${LABELS:-created-by=hetzner-cx23-watch}"
API="https://api.hetzner.cloud/v1"
CONSOLE="https://console.hetzner.cloud/projects"
TYPE_UPPER="${SERVER_TYPE^^}"

changed=false
created=false

write_outputs() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        {
            echo "changed=$changed"
            echo "created=$created"
        } >>"$GITHUB_OUTPUT"
    fi
}
trap write_outputs EXIT

# Translated message: t <key> [args...]
t() {
    local key="$1" fmt=""
    shift
    if [[ "$LANGUAGE" == pt* ]]; then
        case "$key" in
        test_title) fmt='Teste do aviso da Hetzner' ;;
        test_body) fmt='Se você está lendo isto, o aviso do %s funciona.' ;;
        problem_title) fmt='Verificador da Hetzner com problema' ;;
        config_missing) fmt='Com CREATE=true, defina SERVER_NAME, SSH_KEY e LOCATIONS.' ;;
        read_failed) fmt='Não consegui ler %s: %s' ;;
        ssh_missing) fmt='A chave SSH "%s" não existe no projeto.' ;;
        firewall_missing) fmt='O firewall "%s" não existe no projeto.' ;;
        image_missing) fmt='A imagem "%s" não existe.' ;;
        type_missing) fmt='O tipo "%s" não aparece na listagem da Hetzner.' ;;
        no_write) fmt='O token não pode escrever no projeto (precisa de "Read & Write"): %s' ;;
        create_failed) fmt='A criação de %s falhou: %s' ;;
        ready_exists) fmt='Já existe um servidor chamado %s.' ;;
        ready_none) fmt='Nenhum servidor chamado %s ainda.' ;;
        ready_body) fmt='Pronto para criar: chave %s, firewall %s, imagem %s, token com escrita. %s Criação automática: %s, em %s.' ;;
        ready_title) fmt='Teste da criação automática' ;;
        now) fmt='Agora: %s | antes: %s' ;;
        none) fmt='nenhum' ;;
        exists_title) fmt='Servidor já existe' ;;
        exists_body) fmt='%s já existe no projeto. O verificador vai se desligar.' ;;
        creating) fmt='Criando %s (%s) em %s...' ;;
        retry) fmt='Não deu: %s. Tento de novo na próxima janela.' ;;
        created_log) fmt='Servidor criado (id %s). Backup: %s.' ;;
        backup_on) fmt='ligado' ;;
        backup_off) fmt='desligado (BACKUPS=false)' ;;
        backup_failed) fmt='não ligou: ligue à mão no Console' ;;
        created_title) fmt='Servidor criado na Hetzner!' ;;
        created_body) fmt='%s (%s) criado em %s. Backup: %s. O IP está no Console. Agora: revogue o token de escrita da Hetzner. O verificador se desligou.' ;;
        available_title) fmt='%s disponível na Hetzner' ;;
        available_body) fmt='Disponível em: %s. %s' ;;
        hurry) fmt='Corra: o estoque costuma acabar em minutos.' ;;
        outside) fmt='Fora dos locais da criação automática (%s): nada foi criado.' ;;
        soldout_title) fmt='%s esgotou de novo' ;;
        soldout_body) fmt='Não aparece mais disponível em nenhum local.' ;;
        test_sent) fmt='Aviso de teste enviado.' ;;
        esac
    else
        case "$key" in
        test_title) fmt='Hetzner watch test' ;;
        test_body) fmt='If you are reading this, the %s notification works.' ;;
        problem_title) fmt='Hetzner watch problem' ;;
        config_missing) fmt='With CREATE=true, set SERVER_NAME, SSH_KEY and LOCATIONS.' ;;
        read_failed) fmt='Could not read %s: %s' ;;
        ssh_missing) fmt='SSH key "%s" does not exist in the project.' ;;
        firewall_missing) fmt='Firewall "%s" does not exist in the project.' ;;
        image_missing) fmt='Image "%s" does not exist.' ;;
        type_missing) fmt='Server type "%s" is not in the Hetzner listing.' ;;
        no_write) fmt='The token cannot write to the project (it needs "Read & Write"): %s' ;;
        create_failed) fmt='Creating %s failed: %s' ;;
        ready_exists) fmt='A server named %s already exists.' ;;
        ready_none) fmt='No server named %s yet.' ;;
        ready_body) fmt='Ready to create: SSH key %s, firewall %s, image %s, token can write. %s Auto-create: %s, in %s.' ;;
        ready_title) fmt='Auto-create test' ;;
        now) fmt='Now: %s | before: %s' ;;
        none) fmt='none' ;;
        exists_title) fmt='Server already exists' ;;
        exists_body) fmt='%s already exists in the project. The watcher will disable itself.' ;;
        creating) fmt='Creating %s (%s) in %s...' ;;
        retry) fmt='No luck: %s. Trying again in the next window.' ;;
        created_log) fmt='Server created (id %s). Backup: %s.' ;;
        backup_on) fmt='enabled' ;;
        backup_off) fmt='off (BACKUPS=false)' ;;
        backup_failed) fmt='not enabled: turn it on in the Console' ;;
        created_title) fmt='Server created on Hetzner!' ;;
        created_body) fmt='%s (%s) created in %s. Backup: %s. The IP is in the Console. Now revoke the Hetzner write token. The watcher has disabled itself.' ;;
        available_title) fmt='%s available on Hetzner' ;;
        available_body) fmt='Available in: %s. %s' ;;
        hurry) fmt='Hurry: stock usually runs out within minutes.' ;;
        outside) fmt='Outside the auto-create locations (%s): nothing was created.' ;;
        soldout_title) fmt='%s sold out again' ;;
        soldout_body) fmt='No longer available in any location.' ;;
        test_sent) fmt='Test notification sent.' ;;
        esac
    fi
    # shellcheck disable=SC2059
    printf "$fmt" "$@"
}

notify() {
    local title="$1" message="$2" priority="$3" tag="$4"
    jq -n \
        --arg topic "$NTFY_TOPIC" --arg title "$title" --arg message "$message" \
        --argjson priority "$priority" --arg tag "$tag" --arg click "$CONSOLE" \
        '{topic: $topic, title: $title, message: $message, priority: $priority, tags: [$tag], click: $click}' |
        curl -fsS -o /dev/null -H 'Content-Type: application/json' --data-binary @- https://ntfy.sh/
}

# Calls the Hetzner API. Leaves the body in $BODY and the HTTP status in $STATUS.
api() {
    local method="$1" path="$2" data="${3:-}" response
    local args=(-sS -X "$method" -H "Authorization: Bearer $HCLOUD_TOKEN" -w $'\n%{http_code}')
    if [[ -n "$data" ]]; then
        args+=(-H 'Content-Type: application/json' --data-binary "$data")
    fi
    response=$(curl "${args[@]}" "$API$path")
    STATUS="${response##*$'\n'}"
    BODY="${response%$'\n'*}"
}

# Only the error code and message, never the full body (the log is public).
api_error() {
    jq -r '"\(.error.code // "no_code"): \(.error.message // "no message")"' <<<"$BODY" 2>/dev/null ||
        echo "HTTP $STATUS"
}

fail() {
    echo "$1" >&2
    notify "$(t problem_title)" "$1" 4 "warning" || true
    exit 1
}

# Checks what creation needs. Leaves the SSH key (for the write test) and the firewall id.
prepare_creation() {
    api GET "/ssh_keys?name=$SSH_KEY"
    [[ "$STATUS" == 200 ]] || fail "$(t read_failed ssh_keys "$(api_error)")"
    SSH_KEY_ID=$(jq -r '.ssh_keys[0].id // empty' <<<"$BODY")
    [[ -n "$SSH_KEY_ID" ]] || fail "$(t ssh_missing "$SSH_KEY")"
    SSH_KEY_JSON=$(jq -c '.ssh_keys[0] | {name, labels}' <<<"$BODY")

    FIREWALL_ID=""
    if [[ -n "$FIREWALL" ]]; then
        api GET "/firewalls?name=$FIREWALL"
        [[ "$STATUS" == 200 ]] || fail "$(t read_failed firewalls "$(api_error)")"
        FIREWALL_ID=$(jq -r '.firewalls[0].id // empty' <<<"$BODY")
        [[ -n "$FIREWALL_ID" ]] || fail "$(t firewall_missing "$FIREWALL")"
    fi

    api GET "/images?name=$IMAGE"
    [[ "$STATUS" == 200 ]] || fail "$(t read_failed images "$(api_error)")"
    [[ $(jq '.images | length' <<<"$BODY") -ge 1 ]] || fail "$(t image_missing "$IMAGE")"
}

server_exists() {
    api GET "/servers?name=$SERVER_NAME"
    [[ "$STATUS" == 200 ]] || fail "$(t read_failed servers "$(api_error)")"
    [[ $(jq '.servers | length' <<<"$BODY") -ge 1 ]]
}

labels_json() {
    jq -cn --arg labels "$LABELS" '
        $labels | split(",") | map(select(length > 0) | split("=") | {key: .[0], value: (.[1:] | join("="))})
        | from_entries'
}

# --- Test modes ----------------------------------------------------------------------------

if [[ "${TEST_NOTIFICATION:-false}" == "true" ]]; then
    notify "$(t test_title)" "$(t test_body "$TYPE_UPPER")" 3 "white_check_mark"
    t test_sent
    echo
    exit 0
fi

if [[ "$CREATE" == "true" || "${TEST_CREATION:-false}" == "true" ]]; then
    if [[ -z "$SERVER_NAME" || -z "$SSH_KEY" || -z "$LOCATIONS" ]]; then
        fail "$(t config_missing)"
    fi
fi

if [[ "${TEST_CREATION:-false}" == "true" ]]; then
    prepare_creation
    # No-op write: saves the SSH key with its own name and labels. It only passes if the token
    # can write, which is what creation will need.
    api PUT "/ssh_keys/$SSH_KEY_ID" "$SSH_KEY_JSON"
    [[ "$STATUS" == 200 ]] || fail "$(t no_write "$(api_error)")"
    if server_exists; then
        situation=$(t ready_exists "$SERVER_NAME")
    else
        situation=$(t ready_none "$SERVER_NAME")
    fi
    message=$(t ready_body "$SSH_KEY" "${FIREWALL:--}" "$IMAGE" "$situation" "$CREATE" "$LOCATIONS")
    echo "$message"
    notify "$(t ready_title)" "$message" 3 "white_check_mark"
    exit 0
fi

# --- Availability --------------------------------------------------------------------------

types='[]'
page=1
while [[ -n "$page" && "$page" != "null" ]]; do
    api GET "/server_types?per_page=50&page=$page"
    [[ "$STATUS" == 200 ]] || fail "$(t read_failed server_types "$(api_error)")"
    types=$(jq -c --argjson acc "$types" '$acc + .server_types' <<<"$BODY")
    page=$(jq -r '.meta.pagination.next_page' <<<"$BODY")
done

if ! jq -e --arg t "$SERVER_TYPE" 'any(.[]; .name == $t)' <<<"$types" >/dev/null; then
    fail "$(t type_missing "$SERVER_TYPE")"
fi

# Available locations, sorted and comma separated (empty = none).
available=$(jq -r --arg t "$SERVER_TYPE" '
    [ .[] | select(.name == $t) | .locations[]?
      | select(.available == true)
      | (.name // .location // (.id | tostring)) ]
    | sort | join(",")' <<<"$types")

previous=$(cat "$STATE_FILE" 2>/dev/null || true)
t now "${available:-$(t none)}" "${previous:-$(t none)}"
echo

if [[ "$available" != "$previous" ]]; then
    echo "$available" >"$STATE_FILE"
    changed=true
fi

# --- Auto-create ---------------------------------------------------------------------------

chosen=""
if [[ "$CREATE" == "true" ]]; then
    for candidate in ${LOCATIONS//,/ }; do
        if [[ ",$available," == *",$candidate,"* ]]; then
            chosen="$candidate"
            break
        fi
    done
fi

if [[ -n "$chosen" ]]; then
    if server_exists; then
        t exists_body "$SERVER_NAME"
        echo
        notify "$(t exists_title)" "$(t exists_body "$SERVER_NAME")" 3 "information_source"
        created=true
        exit 0
    fi

    prepare_creation
    request=$(jq -n \
        --arg name "$SERVER_NAME" --arg type "$SERVER_TYPE" --arg location "$chosen" \
        --arg image "$IMAGE" --arg key "$SSH_KEY" --arg firewall "$FIREWALL_ID" \
        --argjson labels "$(labels_json)" \
        '{name: $name, server_type: $type, location: $location, image: $image,
          ssh_keys: [$key],
          public_net: {enable_ipv4: true, enable_ipv6: true},
          start_after_create: true, labels: $labels}
         + (if $firewall == "" then {} else {firewalls: [{firewall: ($firewall | tonumber)}]} end)')

    t creating "$SERVER_NAME" "$SERVER_TYPE" "$chosen"
    echo
    api POST "/servers" "$request"

    if [[ "$STATUS" != 201 ]]; then
        code=$(jq -r '.error.code // ""' <<<"$BODY" 2>/dev/null || true)
        case "$code" in
        resource_unavailable | resource_limit_exceeded)
            # The window closed between the check and the request. Try again next time.
            t retry "$(api_error)"
            echo
            ;;
        uniqueness_error)
            t exists_body "$SERVER_NAME"
            echo
            created=true
            notify "$(t exists_title)" "$(t exists_body "$SERVER_NAME")" 3 "information_source"
            ;;
        *)
            fail "$(t create_failed "$SERVER_NAME" "$(api_error)")"
            ;;
        esac
        exit 0
    fi

    server_id=$(jq -r '.server.id' <<<"$BODY")
    created=true

    backup=$(t backup_off)
    if [[ "$BACKUPS" == "true" ]]; then
        # Backups are a separate action, and a brand-new server stays locked for a few seconds.
        backup=$(t backup_failed)
        for _ in $(seq 1 12); do
            api POST "/servers/$server_id/actions/enable_backup"
            if [[ "$STATUS" == 201 ]]; then
                backup=$(t backup_on)
                break
            fi
            sleep 10
        done
    fi
    t created_log "$server_id" "$backup"
    echo

    notify "$(t created_title)" "$(t created_body "$SERVER_NAME" "$SERVER_TYPE" "$chosen" "$backup")" 5 "tada"
    exit 0
fi

# --- Notification only ---------------------------------------------------------------------

if [[ "$changed" == "true" ]]; then
    if [[ -n "$available" ]]; then
        extra=$(t hurry)
        if [[ "$CREATE" == "true" ]]; then
            extra=$(t outside "$LOCATIONS")
        fi
        notify "$(t available_title "$TYPE_UPPER")" "$(t available_body "$available" "$extra")" 5 "rotating_light"
    else
        notify "$(t soldout_title "$TYPE_UPPER")" "$(t soldout_body)" 2 "hourglass"
    fi
fi
