#!/usr/bin/env bash
# Invoice Ninja on Azure. Run from Git Bash on your PC after `az login`. See azure/README.md.
#
#   ./deploy.sh                      create/repair all Azure resources and (re)start the app
#   ./deploy.sh update [version]     backup, pull code from GitHub, switch to <version>, restart
#   ./deploy.sh ops <command>        run on the VM: start | stop | backup | list | restore <name>
#   ./deploy.sh rebuild-vm           replace the VM with a fresh one (data is kept)
#   ./deploy.sh rotate-mail-secret   renew the SMTP secret (expires every 2 years)
#   ./deploy.sh status               show URL, version and container status
set -euo pipefail
export MSYS_NO_PATHCONV=1   # stop Git Bash rewriting /subscriptions/... into Windows paths

LOCATION=${LOCATION:-germanywestcentral}
RG_APP=${RG_APP:-rg-innvoice-app}
RG_DATA=${RG_DATA:-rg-innvoice-data}
VM=${VM:-vm-innvoice}
VM_SIZE=${VM_SIZE:-Standard_B2als_v2}
DNS_LABEL=${DNS_LABEL:-innvoice}
ADMIN_EMAIL=${ADMIN_EMAIL:-madhan@inn-trade.de}
REPO=${REPO:-https://github.com/mad12blue/dockerfiles.git}
BRANCH=${BRANCH:-debian}
DEFAULT_TAG=${DEFAULT_TAG:-5.13.43}
DOCKER_VERSION=${DOCKER_VERSION:-29.8.2}
SUBSCRIPTION=${SUBSCRIPTION:-innvoice-sub}

# Always work in this subscription (also makes it the CLI default for the README commands)
az account set --subscription "$SUBSCRIPTION" \
  || { echo "ERROR: subscription $SUBSCRIPTION not found - run az login" >&2; exit 1; }
SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
SUFFIX=${SUB_ID:0:6}
KV=kv-innvoice-$SUFFIX
ST=stinnvoice$SUFFIX
ECS=ecs-innvoice-$SUFFIX
ACS=acs-innvoice-$SUFFIX
DISK=disk-innvoice-data
IP=pip-innvoice
NSG=nsg-innvoice
SMTP_APP=app-innvoice-smtp
SMTP_ROLE="InnVoice ACS SMTP Sender"
FQDN=$DNS_LABEL.$LOCATION.cloudapp.azure.com
REMOTE_OPS="bash /opt/invoiceninja/debian/azure/ops.sh"

step() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
exists() { "$@" -o none 2>/dev/null; }

kv_get() { az keyvault secret show --vault-name "$KV" -n "$1" --query value -o tsv 2>/dev/null || true; }
kv_set() { az keyvault secret set --vault-name "$KV" -n "$1" --value "$2" -o none; }
kv_seed() { grep -qix "$1" <<< "$KV_NAMES" || kv_set "$1" "$2"; }

# assign <principal-object-id> <principal-type> <role> <scope>
assign() {
  [ -n "$(az role assignment list --assignee "$1" --role "$3" --scope "$4" --query '[0].id' -o tsv)" ] && return
  for _ in 1 2 3 4 5 6; do
    az role assignment create --assignee-object-id "$1" --assignee-principal-type "$2" \
      --role "$3" --scope "$4" -o none 2>/dev/null && return
    sleep 20   # new identities and roles take a moment to replicate
  done
  az role assignment create --assignee-object-id "$1" --assignee-principal-type "$2" --role "$3" --scope "$4" -o none
}

# Run commands on the VM as root and fail if they fail (Azure does not pass the exit code back)
vm_run() {
  local out
  out=$(az vm run-command invoke -g "$RG_APP" -n "$VM" --command-id RunShellScript \
    --scripts "set -e" "$1" "echo __OK__" --query 'value[0].message' -o tsv)
  sed -e '/^Enable succeeded: *$/d' -e '/^__OK__$/d' -e '/^\[std\(out\|err\)\] *$/d' <<< "$out"
  grep -q '^__OK__$' <<< "$out" && return
  echo "ERROR: the command failed on the VM (see the output above)" >&2
  return 1
}

CLOUD_INIT='#cloud-config
package_update: true
package_upgrade: true
packages: [git, jq]
swap:
  filename: /swapfile
  size: 2G
  maxsize: 2G
write_files:
  - path: /etc/docker/daemon.json
    content: |
      {"log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}
  - path: /etc/systemd/system/apt-daily-upgrade.timer.d/innvoice.conf
    content: |
      # Security updates once a week, Sunday 03:00 UTC
      [Timer]
      OnCalendar=
      OnCalendar=Sun *-*-* 03:00
      RandomizedDelaySec=0
  - path: /etc/apt/apt.conf.d/52innvoice
    content: |
      Unattended-Upgrade::Automatic-Reboot "true";
      Unattended-Upgrade::Automatic-Reboot-Time "now";
runcmd:
  - systemctl daemon-reload
  - curl -fsSL https://get.docker.com | sh -s -- --version __DOCKER_VERSION__
  - apt-mark hold docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin
  - curl -fsSL https://aka.ms/InstallAzureCLIDeb | bash
  - |
    for i in $(seq 60); do
      DEV=$(readlink -f /dev/disk/azure/data/by-lun/0 /dev/disk/azure/scsi1/lun0 2>/dev/null | head -1)
      [ -b "$DEV" ] && break; sleep 2
    done
    blkid "$DEV" || mkfs.ext4 -L innvoice-data "$DEV"
    mkdir -p /data
    grep -q innvoice-data /etc/fstab || echo "LABEL=innvoice-data /data ext4 defaults,nofail 0 2" >> /etc/fstab
    mount -a'

deploy() {
  step "Azure services (registered once per subscription)"
  for ns in Microsoft.KeyVault Microsoft.Storage Microsoft.Network Microsoft.Compute Microsoft.Insights Microsoft.Communication; do
    [ "$(az provider show -n "$ns" --query registrationState -o tsv)" = Registered ] && continue
    echo "    registering $ns (1-5 minutes)"
    az provider register -n "$ns" --wait -o none
  done

  step "Resource groups"
  az group create -n "$RG_APP" -l "$LOCATION" -o none
  az group create -n "$RG_DATA" -l "$LOCATION" -o none

  step "Key Vault $KV"
  exists az keyvault show -n "$KV" -g "$RG_DATA" || az keyvault create -n "$KV" -g "$RG_DATA" -l "$LOCATION" \
    --enable-rbac-authorization true --enable-purge-protection true --retention-days 90 -o none
  KV_ID=$(az keyvault show -n "$KV" -g "$RG_DATA" --query id -o tsv)
  assign "$(az ad signed-in-user show --query id -o tsv)" User "Key Vault Secrets Officer" "$KV_ID"
  for _ in $(seq 30); do
    KV_NAMES=$(az keyvault secret list --vault-name "$KV" --query '[].name' -o tsv 2>/dev/null) && break
    sleep 10   # waiting for the new permission
  done
  KV_NAMES=$(az keyvault secret list --vault-name "$KV" --query '[].name' -o tsv)

  step "Secrets (only created if missing, never overwritten)"
  kv_seed APP-KEY "base64:$(openssl rand -base64 32)"
  kv_seed DB-PASSWORD "$(openssl rand -hex 24)"
  kv_seed DB-ROOT-PASSWORD "$(openssl rand -hex 24)"
  kv_seed IN-USER-EMAIL "$ADMIN_EMAIL"
  kv_seed IN-PASSWORD "$(openssl rand -hex 12)"
  kv_seed APP-DEBUG false
  kv_seed REQUIRE-HTTPS true
  kv_seed TAG "$DEFAULT_TAG"
  kv_set AZURE-FQDN "$FQDN"

  step "Backup storage $ST"
  exists az storage account show -n "$ST" -g "$RG_DATA" || az storage account create -n "$ST" -g "$RG_DATA" \
    -l "$LOCATION" --sku Standard_GRS --kind StorageV2 --min-tls-version TLS1_2 \
    --allow-blob-public-access false --allow-shared-key-access false -o none
  az storage account blob-service-properties update -n "$ST" -g "$RG_DATA" \
    --enable-delete-retention true --delete-retention-days 14 \
    --enable-container-delete-retention true --container-delete-retention-days 14 -o none
  exists az storage container-rm show --storage-account "$ST" -n backups -g "$RG_DATA" \
    || az storage container-rm create --storage-account "$ST" -n backups -g "$RG_DATA" -o none
  # Backups cannot be changed or deleted for 7 days, not even from a compromised VM
  [ "$(az storage container immutability-policy show --account-name "$ST" -c backups -g "$RG_DATA" \
      --query immutabilityPeriodSinceCreationInDays -o tsv 2>/dev/null)" = 7 ] \
    || az storage container immutability-policy create --account-name "$ST" -c backups -g "$RG_DATA" --period 7 -o none
  az storage account management-policy create --account-name "$ST" -g "$RG_DATA" -o none --policy \
    '{"rules":[{"enabled":true,"name":"expire-backups","type":"Lifecycle","definition":{"actions":{"baseBlob":{"delete":{"daysAfterModificationGreaterThan":30}}},"filters":{"blobTypes":["blockBlob"],"prefixMatch":["backups/"]}}}]}'
  ST_ID=$(az storage account show -n "$ST" -g "$RG_DATA" --query id -o tsv)

  step "Static IP $FQDN and data disk"
  exists az network public-ip show -n "$IP" -g "$RG_DATA" || az network public-ip create -n "$IP" -g "$RG_DATA" \
    -l "$LOCATION" --sku Standard --allocation-method Static --dns-name "$DNS_LABEL" -o none
  exists az disk show -n "$DISK" -g "$RG_DATA" || az disk create -n "$DISK" -g "$RG_DATA" -l "$LOCATION" \
    --size-gb 32 --sku Premium_LRS -o none
  exists az lock show -n keep-data -g "$RG_DATA" || az lock create -n keep-data -g "$RG_DATA" \
    --lock-type CanNotDelete --notes "Holds Invoice Ninja data and backups" -o none

  step "Firewall: web open, SSH only from this PC"
  exists az network nsg show -n "$NSG" -g "$RG_APP" || az network nsg create -n "$NSG" -g "$RG_APP" -l "$LOCATION" -o none
  az network nsg rule create -g "$RG_APP" --nsg-name "$NSG" -n allow-web --priority 100 \
    --protocol '*' --destination-port-ranges 80 443 --access Allow -o none
  az network nsg rule create -g "$RG_APP" --nsg-name "$NSG" -n allow-ssh --priority 110 \
    --protocol Tcp --destination-port-ranges 22 --source-address-prefixes "$(curl -fsS https://api.ipify.org)/32" \
    --access Allow -o none

  step "VM $VM"
  if ! exists az vm show -n "$VM" -g "$RG_APP"; then
    az vm create -n "$VM" -g "$RG_APP" -l "$LOCATION" --size "$VM_SIZE" --image Ubuntu2404 \
      --admin-username azureuser --generate-ssh-keys \
      --os-disk-size-gb 30 --storage-sku StandardSSD_LRS --os-disk-delete-option Delete \
      --attach-data-disks "$(az disk show -n "$DISK" -g "$RG_DATA" --query id -o tsv)" --data-disk-delete-option Detach \
      --public-ip-address "$(az network public-ip show -n "$IP" -g "$RG_DATA" --query id -o tsv)" \
      --nic-delete-option Delete --nsg "$NSG" \
      --assign-identity '[system]' --tags kv="$KV" st="$ST" \
      --custom-data "${CLOUD_INIT//__DOCKER_VERSION__/$DOCKER_VERSION}" -o none
  fi
  VM_PRINCIPAL=$(az vm show -n "$VM" -g "$RG_APP" --query identity.principalId -o tsv)
  assign "$VM_PRINCIPAL" ServicePrincipal "Key Vault Secrets User" "$KV_ID"
  assign "$VM_PRINCIPAL" ServicePrincipal "Storage Blob Data Contributor" "$ST_ID/blobServices/default/containers/backups"

  step "Alert: email if no backup arrives for 12 hours"
  az monitor action-group create -n ag-innvoice -g "$RG_DATA" --short-name innvoice \
    --action email admin "$(kv_get IN-USER-EMAIL)" -o none
  exists az monitor metrics alert show -n backup-missing -g "$RG_DATA" || az monitor metrics alert create \
    -n backup-missing -g "$RG_DATA" --scopes "$ST_ID" --condition "total Ingress < 10240" \
    --window-size 12h --evaluation-frequency 1h --severity 2 --action ag-innvoice \
    --description "No Invoice Ninja backup uploaded in the last 12 hours" -o none

  setup_mail

  step "App on the VM (the first run downloads images and takes several minutes)"
  vm_run "cloud-init status --wait > /dev/null || true
    mountpoint -q /data || { echo 'ERROR: data disk not mounted at /data'; exit 1; }
    [ -d /opt/invoiceninja/.git ] || git clone -b $BRANCH $REPO /opt/invoiceninja
    $REMOTE_OPS start"

  status
}

status() {
  cat <<EOF

URL:       https://$(kv_get APP-DOMAIN | grep . || echo "$FQDN")
Version:   $(kv_get TAG)
Login:     $(kv_get IN-USER-EMAIL)
Password:  az keyvault secret show --vault-name $KV -n IN-PASSWORD --query value -o tsv
           (only used for the very first login - change it in the app afterwards)
EOF
  vm_run "docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'"
}

setup_mail() {
  local from domain sender domain_id state acs_id app_id sp_id
  from=$(kv_get MAIL-FROM-ADDRESS)
  if [ -z "$from" ]; then
    step "Email: skipped (add MAIL-FROM-ADDRESS to Key Vault to enable)"
    return
  fi
  domain=${from#*@}
  sender=${from%@*}
  step "Email via Azure Communication Services for $domain"
  az extension add --name communication --upgrade -y -o none 2>/dev/null || true

  exists az communication email show -n "$ECS" -g "$RG_DATA" || az communication email create -n "$ECS" \
    -g "$RG_DATA" --location global --data-location Europe -o none
  exists az communication email domain show --domain-name "$domain" --email-service-name "$ECS" -g "$RG_DATA" \
    || az communication email domain create --domain-name "$domain" --email-service-name "$ECS" -g "$RG_DATA" \
      --location global --domain-management CustomerManaged -o none
  domain_id=$(az communication email domain show --domain-name "$domain" --email-service-name "$ECS" -g "$RG_DATA" --query id -o tsv)

  state=$(az communication email domain show --domain-name "$domain" --email-service-name "$ECS" -g "$RG_DATA" \
    --query '[verificationStates.Domain.status, verificationStates.SPF.status, verificationStates.DKIM.status, verificationStates.DKIM2.status]' -o tsv)
  if [ "$(grep -cx Verified <<< "$state")" -lt 4 ]; then
    echo "Add these DNS records for $domain, wait ~15 minutes, then re-run ./deploy.sh:"
    az communication email domain show --domain-name "$domain" --email-service-name "$ECS" -g "$RG_DATA" \
      --query '[verificationRecords.Domain, verificationRecords.SPF, verificationRecords.DKIM, verificationRecords.DKIM2]' -o table
    for t in Domain SPF DKIM DKIM2; do
      az communication email domain initiate-verification --domain-name "$domain" --email-service-name "$ECS" \
        -g "$RG_DATA" --verification-type "$t" -o none 2>/dev/null || true
    done
    echo "(Email stays off until all four records are verified.)"
    return
  fi

  if exists az communication show -n "$ACS" -g "$RG_DATA"; then
    az communication update -n "$ACS" -g "$RG_DATA" --linked-domains "$domain_id" -o none
  else
    az communication create -n "$ACS" -g "$RG_DATA" --location global --data-location Europe \
      --linked-domains "$domain_id" -o none
  fi
  az communication email domain sender-username create --email-service-name "$ECS" --domain-name "$domain" \
    -g "$RG_DATA" --sender-username "$sender" --username "$sender" -o none
  acs_id=$(az communication show -n "$ACS" -g "$RG_DATA" --query id -o tsv)

  # SMTP login = Entra app with a send-only custom role on the ACS resource
  app_id=$(az ad app list --display-name "$SMTP_APP" --query '[0].appId' -o tsv)
  [ -n "$app_id" ] || app_id=$(az ad app create --display-name "$SMTP_APP" --query appId -o tsv)
  sp_id=$(az ad sp show --id "$app_id" --query id -o tsv 2>/dev/null || az ad sp create --id "$app_id" --query id -o tsv)
  [ -n "$(az role definition list --name "$SMTP_ROLE" --query '[0].id' -o tsv)" ] || az role definition create -o none --role-definition \
    "{\"Name\":\"$SMTP_ROLE\",\"IsCustom\":true,\"Description\":\"Send email through ACS SMTP\",\"Actions\":[\"Microsoft.Communication/CommunicationServices/Read\",\"Microsoft.Communication/CommunicationServices/Write\",\"Microsoft.Communication/EmailServices/write\"],\"AssignableScopes\":[\"/subscriptions/$SUB_ID/resourceGroups/$RG_DATA\"]}"
  assign "$sp_id" ServicePrincipal "$SMTP_ROLE" "$acs_id"

  kv_set MAIL-MAILER smtp
  kv_set MAIL-HOST smtp.azurecomm.net
  kv_set MAIL-PORT 587
  kv_set MAIL-ENCRYPTION tls
  kv_set MAIL-USERNAME "$ACS.$app_id.$TENANT_ID"
  [ -n "$(kv_get MAIL-PASSWORD)" ] || new_mail_secret "$app_id"
  echo "Email enabled: $from"
}

new_mail_secret() {
  local pw
  pw=$(az ad app credential reset --id "$1" --years 2 --display-name smtp --query password -o tsv 2>/dev/null)
  kv_set MAIL-PASSWORD "$pw"
}

update() {
  local new=${1:-} old
  old=$(kv_get TAG)
  if [ -n "$new" ] && [ "$new" != "$old" ]; then
    curl -fsS -o /dev/null "https://hub.docker.com/v2/repositories/invoiceninja/invoiceninja-debian/tags/$new" \
      || die "version $new does not exist on Docker Hub (invoiceninja/invoiceninja-debian)"
    kv_set TAG "$new"
  fi
  step "Updating to $(kv_get TAG) (was $old) - a backup is taken first"
  if ! vm_run "$REMOTE_OPS update"; then
    cat <<EOF >&2

Update failed. To go back to $old:
  ./deploy.sh update $old
and if the app still misbehaves, restore the backup taken just before ("...-pre-update"):
  ./deploy.sh ops list
  ./deploy.sh ops restore <name>
EOF
    exit 1
  fi
  status
}

rebuild_vm() {
  echo "This deletes $VM and builds a fresh one. The data disk, IP, Key Vault and backups are kept."
  read -r -p "Type 'rebuild' to continue: " answer
  [ "$answer" = rebuild ] || die "cancelled"
  vm_run "$REMOTE_OPS backup pre-rebuild && $REMOTE_OPS stop" \
    || echo "WARNING: could not back up / stop the app first - continuing with the latest backup available"
  az vm delete -g "$RG_APP" -n "$VM" --yes
  ssh-keygen -R "$FQDN" > /dev/null 2>&1 || true
  deploy
}

case ${1:-deploy} in
  deploy) deploy ;;
  update) update "${2:-}" ;;
  ops) shift; vm_run "$REMOTE_OPS $*" ;;
  rebuild-vm) rebuild_vm ;;
  status) status ;;
  rotate-mail-secret)
    app_id=$(az ad app list --display-name "$SMTP_APP" --query '[0].appId' -o tsv)
    [ -n "$app_id" ] || die "email is not set up yet"
    new_mail_secret "$app_id"
    vm_run "$REMOTE_OPS start"
    echo "New SMTP secret stored in Key Vault and app restarted. Next renewal: in 2 years."
    ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
