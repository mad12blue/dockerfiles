#!/usr/bin/env bash
# Runs ON the VM as root. From your PC use:  ./deploy.sh ops <command>   (see azure/README.md)
#
#   start            load settings from Key Vault and (re)start the app
#   stop             stop the app (data is kept)
#   backup [label]   database + uploaded files -> Blob Storage
#   list             list backups
#   restore <name>   restore a backup from `list` (a "pre-restore" backup is taken first)
#   update           backup, pull code from GitHub, pull images, restart
set -euo pipefail

REPO_DIR=/opt/invoiceninja
APP_DIR=$REPO_DIR/debian
SELF=$APP_DIR/azure/ops.sh
ENV_FILE=/etc/innvoice/app.env
UNIT=innvoice
CONTAINER=backups

die() { echo "ERROR: $*" >&2; exit 1; }

WORK=$(mktemp -d)   # temporary files of this run, removed on exit
trap 'rm -rf "$WORK"' EXIT

# Key Vault and storage account names come from the VM's tags (set by deploy.sh)
vm_tag() {
  curl -fsS -H Metadata:true "http://169.254.169.254/metadata/instance/compute/tagsList?api-version=2021-02-01" \
    | jq -r --arg n "$1" '.[] | select(.name == $n) | .value'
}
KV=$(vm_tag kv)
ST=$(vm_tag st)

dc() {
  docker compose --project-directory "$APP_DIR" \
    -f "$APP_DIR/docker-compose.yml" -f "$APP_DIR/azure/docker-compose.azure.yml" \
    --env-file "$ENV_FILE" "$@"
}

login() { az login --identity -o none; }

first_ip() { getent ahostsv4 "$1" | awk 'NR == 1 { print $1 }'; }

# ---------------------------------------------------------------- settings

# Invoice Ninja's .env template + every Key Vault secret (NAME-X -> NAME_X) + derived values
write_env() {
  declare -A kv=()
  local names name key line tmp fqdn host sites
  names=$(az keyvault secret list --vault-name "$KV" --query "[?attributes.enabled].name" -o tsv) || return 1
  for name in $names; do
    key=${name//-/_}
    kv[${key^^}]=$(az keyvault secret show --vault-name "$KV" -n "$name" --query value -o tsv) || return 1
  done

  fqdn=${kv[AZURE_FQDN]:?missing in Key Vault}
  host=$fqdn
  sites=$fqdn
  if [ -n "${kv[APP_DOMAIN]:-}" ]; then
    if [ "$(first_ip "${kv[APP_DOMAIN]}")" = "$(first_ip "$fqdn")" ]; then
      host=${kv[APP_DOMAIN]}
      sites="$fqdn, ${kv[APP_DOMAIN]}"
    else
      echo "WARNING: ${kv[APP_DOMAIN]} does not point to $fqdn yet - serving only $fqdn" >&2
    fi
  fi
  kv[APP_URL]="https://$host"
  kv[SITE_ADDRESSES]=$sites
  kv[APP_ENV]=${kv[APP_ENV]:-production}
  kv[APP_DEBUG]=${kv[APP_DEBUG]:-false}          # never inherit "true" from the template
  kv[REQUIRE_HTTPS]=${kv[REQUIRE_HTTPS]:-true}
  kv[MYSQL_DATABASE]=${kv[DB_DATABASE]:-ninja}
  kv[MYSQL_USER]=${kv[DB_USERNAME]:-ninja}
  kv[MYSQL_PASSWORD]=${kv[DB_PASSWORD]:?missing in Key Vault}
  kv[MYSQL_ROOT_PASSWORD]=${kv[DB_ROOT_PASSWORD]:?missing in Key Vault}

  install -d -m 700 /etc/innvoice
  tmp=$(mktemp)
  sed 's/\r$//' "$APP_DIR/.env" | while IFS= read -r line; do
    key=${line%%=*}
    [[ $line =~ ^[A-Z0-9_]+= ]] && [ -n "${kv[$key]+x}" ] && continue
    printf '%s\n' "$line"
  done > "$tmp"
  printf '\n# From Key Vault %s\n' "$KV" >> "$tmp"
  for key in "${!kv[@]}"; do printf "%s='%s'\n" "$key" "${kv[$key]}"; done >> "$tmp"
  install -m 600 "$tmp" "$ENV_FILE"
  rm -f "$tmp"
}

refresh_env() {
  if login && write_env; then return; fi
  [ -f "$ENV_FILE" ] || die "cannot read Key Vault and no previous settings exist"
  echo "WARNING: Key Vault not reachable - starting with the previous settings" >&2
}

# Refuse to start if the database or uploads would not be stored on the data disk
# (e.g. Invoice Ninja renamed a volume in docker-compose.yml upstream).
check_volume() {  # <config json> <service> <path in container> <expected path on disk>
  local src dev name actual
  src=$(jq -r --arg s "$2" --arg t "$3" '.services[$s].volumes[]? | select(.target == $t) | .source' <<< "$1")
  dev=$(jq -r --arg v "$src" '.volumes[$v].driver_opts.device // empty' <<< "$1")
  [ "$dev" = "$4" ] || die "$2 data ($3) would not be stored on the data disk ($4).
       docker-compose.yml probably changed upstream - adjust azure/docker-compose.azure.yml first."
  name=$(jq -r --arg v "$src" '.volumes[$v].name' <<< "$1")
  if docker volume inspect "$name" > /dev/null 2>&1; then
    actual=$(docker volume inspect -f '{{index .Options "device"}}' "$name")
    [ "$actual" = "$4" ] || die "Docker volume $name points to '$actual' instead of $4"
  fi
}

check_volumes() {
  local cfg
  cfg=$(dc config --format json)
  check_volume "$cfg" mysql /var/lib/mysql /data/mysql
  check_volume "$cfg" app /var/www/html/storage /data/storage
}

# ---------------------------------------------------------------- start / stop

# The app runs as systemd service "innvoice": it starts in the right order after a reboot
# and stops cleanly before a shutdown. `start` and `stop` go through that service.
install_service() {
  cat > /etc/systemd/system/$UNIT.service <<EOF
[Unit]
Description=Invoice Ninja (Docker Compose)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target
RequiresMountsFor=/data

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash $SELF _service-start
ExecStop=/bin/bash $SELF _service-stop
TimeoutStartSec=30min
TimeoutStopSec=5min

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable -q $UNIT
  printf 'SHELL=/bin/bash\n0 */6 * * * root bash %s backup >> /var/log/innvoice-backup.log 2>&1\n' \
    "$SELF" > /etc/cron.d/innvoice
}

start() {
  local since
  install_service
  since=$(date '+%F %T')
  if systemctl restart $UNIT; then
    journalctl -u $UNIT --since "$since" -o cat --no-pager | tail -n 20
  else
    journalctl -u $UNIT --since "$since" -o cat --no-pager | tail -n 60
    die "start failed (full log on the VM: journalctl -u $UNIT)"
  fi
}

stop() { systemctl stop $UNIT; echo "Stopped (data is kept). Start again with: start"; }

_service-start() {
  mountpoint -q /data || die "data disk is not mounted at /data"
  mkdir -p /data/storage /data/mysql /data/caddy
  refresh_env
  check_volumes
  dc pull -q || echo "WARNING: could not pull images - using the local ones" >&2
  dc up -d --no-build --remove-orphans --wait --wait-timeout 900
  dc ps
}

_service-stop() { dc stop; }

# ---------------------------------------------------------------- backups

backup() {
  local name tmp=$WORK/backup
  login
  name="$(date -u +%Y-%m-%dT%H%M)${1:+-$1}"
  rm -rf "$tmp" && mkdir "$tmp"
  dc exec -T mysql sh -c 'exec mysqldump --single-transaction --routines -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"' \
    | gzip > "$tmp/db.sql.gz"
  tar -czf "$tmp/storage.tar.gz" -C /data/storage --exclude=./framework --exclude=./logs .
  az storage blob upload-batch --auth-mode login --account-name "$ST" -d "$CONTAINER" \
    --destination-path "$name" -s "$tmp" -o none
  rm -rf "$tmp"
  echo "Backup $name uploaded"
}

list() {
  login
  az storage blob list --auth-mode login --account-name "$ST" -c "$CONTAINER" \
    --query "[?ends_with(name, '/db.sql.gz')].name" -o tsv | sed 's|/db.sql.gz$||' | sort
}

restore() {
  local name=${1:?usage: ops.sh restore <name from ops.sh list>} tmp=$WORK/restore
  login
  mkdir -p "$tmp"
  az storage blob download-batch --auth-mode login --account-name "$ST" -s "$CONTAINER" \
    --pattern "$name/*" -d "$tmp" -o none
  [ -f "$tmp/$name/db.sql.gz" ] || die "backup $name not found (see: list)"
  backup pre-restore
  dc stop app
  dc exec -T mysql sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE \`$MYSQL_DATABASE\`; CREATE DATABASE \`$MYSQL_DATABASE\`"'
  gunzip -c "$tmp/$name/db.sql.gz" \
    | dc exec -T mysql sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"'
  tar -xzf "$tmp/$name/storage.tar.gz" -C /data/storage
  start
  echo "Restored $name"
}

# ---------------------------------------------------------------- update

update() {
  backup pre-update
  git -C "$REPO_DIR" pull --ff-only
  refresh_env
  dc pull -q            # fails here (app still running) if a version does not exist
  bash "$SELF" start    # the freshly pulled version of this script
  docker image prune -af > /dev/null
  echo "Update complete"
}

# ---------------------------------------------------------------- main

cmd=${1:-}
shift || true
case $cmd in
  backup | restore | update)
    exec 9> /run/innvoice.lock
    flock -w 3600 9 || die "another backup/restore/update is still running"
    "$cmd" "$@"
    ;;
  start | stop | list | _service-start | _service-stop) "$cmd" "$@" ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
