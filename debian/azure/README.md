# Invoice Ninja on Azure

Runs Invoice Ninja on one Azure VM, with HTTPS, automatic backups and all settings stored in Azure Key Vault.

- [How it works](#how-it-works)
- [First-time setup](#first-time-setup)
- [After setup: test everything once](#after-setup-test-everything-once)
- [Settings (Key Vault)](#settings-key-vault)
- [Add your own domain](#add-your-own-domain)
- [Turn on email](#turn-on-email)
- [Update Invoice Ninja](#update-invoice-ninja)
- [Backups and restore](#backups-and-restore)
- [What runs automatically](#what-runs-automatically)
- [When something goes wrong](#when-something-goes-wrong)
- [Rules: never do this](#rules-never-do-this)
- [Command reference](#command-reference)
- [Limits and known risks](#limits-and-known-risks)

---

## How it works

```
                 Internet (HTTPS)
                        │
┌─ rg-innvoice-app ─────▼─────────────────────────────┐   disposable: can be deleted
│  VM  vm-innvoice  (Ubuntu 24.04, B2s)               │   and rebuilt at any time
│   Caddy (HTTPS) → nginx → Invoice Ninja → MySQL     │
│                                          → Redis    │
└──────────────────────┬──────────────────────────────┘
                       │ uses
┌─ rg-innvoice-data ───▼─────────────────────────────┐   protected by a delete lock
│  Data disk     database + uploaded files (/data)    │
│  Static IP     innvoice.germanywestcentral.cloudapp.azure.com
│  Key Vault     all settings and secrets             │
│  Storage       backups every 6 h, kept 30 days      │
│  Email (ACS)   sending invoices (optional)          │
│  Alert         emails you if backups stop           │
└─────────────────────────────────────────────────────┘
```

The VM holds nothing you would lose. Your data lives on the **data disk**, and copies go to **Blob Storage** every 6 hours. Settings live in **Key Vault**. If the VM breaks, you build a new one and it picks up the same data.

### Files

| File | Runs on | Purpose |
|---|---|---|
| `deploy.sh` | your PC | Creates or repairs everything in Azure, and runs commands on the VM |
| `ops.sh` | the VM | Start, stop, backup, restore, update |
| `docker-compose.azure.yml` | the VM | Adds HTTPS, pins versions, stores data on the data disk |
| `Caddyfile` | the VM | HTTPS configuration |

Invoice Ninja's own files (`docker-compose.yml`, `.env`, `Dockerfile` …) are **not changed**, so updating your fork from Invoice Ninja never conflicts.

### Monthly cost (estimate)

| Item | €/month |
|---|---|
| VM B2s | ~33 |
| OS disk + data disk | ~10 |
| Static IP | ~4 |
| Storage, Key Vault, alert, email | ~2 |
| **Total** | **~50** |

---

## First-time setup

### 1. What you need

- An Azure subscription where you are **Owner**.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) and **Git Bash** (comes with Git for Windows).
- A GitHub account with **two-factor authentication turned on**. The VM runs the code from your fork, so protect that account.

### 2. Fork the repository

1. Open <https://github.com/invoiceninja/dockerfiles> and click **Fork**. The fork is created as `mad12blue/dockerfiles`.
2. In Git Bash, point your local copy at your fork:
   ```bash
   cd path/to/dockerfiles
   git remote rename origin upstream
   git remote add origin https://github.com/mad12blue/dockerfiles.git
   ```
3. Commit and push the Azure files. The VM downloads them from GitHub, so they must be pushed **before** deploying.
   ```bash
   git add debian/azure
   git commit -m "Add Azure deployment"
   git push -u origin debian
   ```

### 3. Deploy

```bash
az login
cd debian/azure
./deploy.sh
```

The first run takes **15–25 minutes**. It creates all resources, prepares the VM and starts the app. When it finishes it prints:

```
URL:       https://innvoice.germanywestcentral.cloudapp.azure.com
Version:   5.13.43
Login:     madhan@inn-trade.de
Password:  az keyvault secret show --vault-name kv-innvoice-xxxxxx -n IN-PASSWORD ...
```

Run the password command to see your first password.

> **If it fails with "DNS name already taken"**, someone else uses `innvoice` in this region. Pick another name:
> `DNS_LABEL=innvoice-app ./deploy.sh`

`deploy.sh` is safe to run again at any time. It only creates what is missing and never overwrites passwords.

---

## After setup: test everything once

Do this on the first day, while there is no real data yet.

| # | Test | How | Expected |
|---|---|---|---|
| 1 | Login | Open the URL and log in | Invoice Ninja dashboard |
| 2 | **Change the admin password** | In the app: *Settings → User Details* | The Key Vault password is only for the very first login |
| 3 | Backup | `./deploy.sh ops backup test` | `Backup …-test uploaded` |
| 4 | List | `./deploy.sh ops list` | Shows the backup |
| 5 | Restore | Create a test client, then `./deploy.sh ops restore <name from step 4>` | The test client is gone again |
| 6 | Reboot | `az vm restart -g rg-innvoice-app -n vm-innvoice`, wait 5 minutes | App works again by itself |
| 7 | Rebuild | `./deploy.sh rebuild-vm` | Fresh VM, same data, same URL |
| 8 | Uptime monitor | See below | You get an email when the site is down |
| 9 | Backup alert | See below | You get an email when backups stop |

### Uptime monitor (free, outside Azure)

Nothing in Azure tells you when the website is down. Use a free external check:

1. Create a free account at <https://uptimerobot.com>.
2. Add a monitor: type **Keyword**, URL `https://<your URL>/health`, keyword `API is healthy`, interval 5 minutes.
3. Add your email as the alert contact.

Because it runs outside Azure, it still alerts you if Azure itself has a problem.

### Test the backup alert

The alert should email you when no backup has arrived for 12 hours. Test it once:

```bash
ssh azureuser@<your URL> 'sudo mv /etc/cron.d/innvoice /root/innvoice.cron'
# wait ~13 hours, an email "backup-missing" should arrive
./deploy.sh ops start        # puts the backup schedule back
```

If no email arrives, tell whoever maintains this setup. The alert needs a different design.

---

## Settings (Key Vault)

**Key Vault is the only place you change settings.** Every secret becomes a setting in Invoice Ninja:
Key Vault name `MAIL-FROM-NAME` → Invoice Ninja setting `MAIL_FROM_NAME`.

Anything **not** in Key Vault uses the default from Invoice Ninja's `debian/.env`.

### Change a setting

```bash
KV=$(az keyvault list -g rg-innvoice-data --query '[0].name' -o tsv)
az keyvault secret set --vault-name $KV -n MAIL-FROM-NAME --value "InnVoice"
./deploy.sh ops start
```

Or use the Azure portal: **Key Vault → Secrets → + Generate/Import**. Then run `./deploy.sh ops start`. The portal also keeps a history of every value.

### Settings created by `deploy.sh`

| Key Vault name | Meaning | Change it? |
|---|---|---|
| `APP-KEY` | Encryption key for sensitive data | ❌ **Never** |
| `DB-PASSWORD`, `DB-ROOT-PASSWORD` | Database passwords | ❌ **Never** |
| `IN-USER-EMAIL`, `IN-PASSWORD` | First login (used once) | Not needed; change them in the app |
| `TAG` | Invoice Ninja version | Use `./deploy.sh update <version>` |
| `AZURE-FQDN` | The Azure address | Managed by `deploy.sh` |
| `APP-DEBUG`, `REQUIRE-HTTPS` | `false` / `true` | Leave as is |
| `MAIL-*` | Email login (after turning on email) | Managed by `deploy.sh` |

### Settings you may add

| Key Vault name | Example | Effect |
|---|---|---|
| `APP-DOMAIN` | `app.innvoice.de` | Your own address → [Add your own domain](#add-your-own-domain) |
| `MAIL-FROM-ADDRESS` | `rechnung@innvoice.de` | Turns on email → [Turn on email](#turn-on-email) |
| `MAIL-FROM-NAME` | `InnVoice` | Sender name in emails |
| `MYSQL-TAG`, `NGINX-TAG`, `REDIS-TAG`, `CADDY-TAG` | `8.4.12` | Override a pinned helper version. Only do this after reading their release notes. |

---

## Add your own domain

Example: `app.innvoice.de`.

1. At your DNS provider, create a **CNAME** record:
   `app.innvoice.de` → `innvoice.germanywestcentral.cloudapp.azure.com`
2. Wait until it works. `nslookup app.innvoice.de` should show the Azure IP.
3. Add the setting and restart:
   ```bash
   az keyvault secret set --vault-name $KV -n APP-DOMAIN --value app.innvoice.de
   ./deploy.sh ops start
   ```

The HTTPS certificate is created automatically. The Azure address keeps working too, so old links still open.
If the DNS record is not ready yet, the app keeps running on the Azure address and prints a warning, so nothing breaks.

---

## Turn on email

Email goes through **Azure Communication Services**, which costs about €0.25 per 1,000 emails.
Until email is turned on, Invoice Ninja **cannot send** invoices or password resets; they are only written to a log.

1. Set the sender address and run the deploy:
   ```bash
   az keyvault secret set --vault-name $KV -n MAIL-FROM-ADDRESS --value rechnung@innvoice.de
   ./deploy.sh
   ```
2. It prints a table of **DNS records** (1 TXT for ownership, 1 TXT for SPF, 2 CNAMEs for DKIM). Add them at your DNS provider **exactly** as shown.
   Recommended extra record: TXT `_dmarc.innvoice.de` → `v=DMARC1; p=none; rua=mailto:madhan@inn-trade.de`
3. Wait ~15 minutes (sometimes up to a few hours), then run `./deploy.sh` again. Repeat until it says **Email enabled**.
4. Send a test invoice to yourself.

**The email password expires after 2 years.** Put a reminder in your calendar, then run:
```bash
./deploy.sh rotate-mail-secret
```

New email accounts are limited to about **30 emails a minute and 100 an hour**. If you send more, ask Azure support to raise the limit.

---

## Update Invoice Ninja

Updates **never happen by accident**: the version is pinned in Key Vault (`TAG`).

1. Check the latest version and read its release notes:
   <https://github.com/invoiceninja/invoiceninja/releases>
2. If Invoice Ninja changed its Docker files, update your fork: on GitHub, open your fork and click **Sync fork**. It's safe, because your `azure/` folder is never touched.
3. Update:
   ```bash
   ./deploy.sh update 5.13.44
   ```
   This **backs up first**, downloads the latest code from your fork, downloads the new version, restarts, and upgrades the database automatically. A mistyped version is rejected before anything changes.

`./deploy.sh update` without a version only pulls the latest code from your fork (for example a fix to these scripts) and restarts.

### Roll back

```bash
./deploy.sh update 5.13.43           # the previous version
./deploy.sh ops list                 # find the "...-pre-update" backup
./deploy.sh ops restore <name>       # needed, because the newer version may have changed the database
```

---

## Backups and restore

| What | Details |
|---|---|
| When | Every 6 hours (00:00, 06:00, 12:00, 18:00 UTC), plus before every update, restore and rebuild |
| What | Full database + uploaded files (logos, documents) |
| Where | Blob Storage in `rg-innvoice-data`, with a copy in a second Azure region |
| Kept | 30 days |
| Protection | Cannot be changed or deleted for 7 days, not even by a hacked VM. Deleted backups can be recovered for a further 14 days. |
| Alert | Email if no backup arrives for 12 hours |

```bash
./deploy.sh ops backup [label]   # extra backup now, e.g. "before-cleanup"
./deploy.sh ops list             # all backups, oldest first
./deploy.sh ops restore <name>   # restore one (takes a "pre-restore" backup first)
```

A restore replaces **all** current data with the backup. Uploaded files that were added after the backup are kept.

### Keep an extra copy outside Azure (recommended monthly)

If you ever lose access to your Azure subscription, its backups are gone with it. Once a month, download the latest backup:
**Azure portal → Storage accounts → stinnvoice… → Containers → backups → newest folder → download both files.**
Store them somewhere safe (they contain all your business data).

---

## What runs automatically

| What | When | Notes |
|---|---|---|
| Backups | Every 6 hours | Alert if missing |
| Ubuntu security updates | Sundays 03:00 UTC | Reboots by itself if needed; the app comes back by itself |
| HTTPS certificates | Before they expire | Caddy renews them |
| App start after reboot | Every boot | Service `innvoice` starts everything in the right order |
| Log cleanup | Continuous | Docker logs are capped at 30 MB per container |

What does **not** happen automatically: Invoice Ninja updates, Docker updates, version changes of the helper programs, and the email password renewal.

---

## When something goes wrong

Work down the list and stop at the first step that fixes it.

| Step | Command | Time |
|---|---|---|
| 1. Look | `./deploy.sh status` | 1 min |
| 2. Restart the app | `./deploy.sh ops start` | 2 min |
| 3. Restart the VM | `az vm restart -g rg-innvoice-app -n vm-innvoice` | 5 min |
| 4. Repair Azure resources | `./deploy.sh` | 5 min |
| 5. Fresh VM | `./deploy.sh rebuild-vm` | 20 min |
| 6. Restore data | `./deploy.sh ops list` → `./deploy.sh ops restore <name>` | 10 min |

Steps 1–5 never touch your data. Only step 6 does.

### Typical messages

| Message | Meaning / fix |
|---|---|
| `data disk is not mounted at /data` | The data disk is not attached. Check in the portal: VM → Disks. Then step 5. |
| `… would not be stored on the data disk` | Invoice Ninja changed its `docker-compose.yml`. The app was **not** started, to protect your data. The volume names in `docker-compose.azure.yml` need adjusting. |
| `Key Vault not reachable - starting with the previous settings` | Temporary Azure problem. The app runs with the last known settings. |
| `does not point to … yet` | The DNS record for `APP-DOMAIN` is missing or not active yet. |
| `version … does not exist on Docker Hub` | Typo in the version number. |
| `the command failed on the VM` | The lines above it show the reason. For more: `ssh azureuser@<URL> 'sudo journalctl -u innvoice -n 100'` |
| SSH `Connection timed out` | Your PC's IP changed. Run `./deploy.sh` to allow your new IP. `./deploy.sh ops …` works without SSH. |
| SSH `REMOTE HOST IDENTIFICATION HAS CHANGED` | Expected after a rebuild: `ssh-keygen -R <URL>` |

---

## Rules: never do this

1. **Never change or delete `APP-KEY`.** Saved payment gateway keys and other encrypted data become unreadable.
2. **Never change `DB-PASSWORD` or `DB-ROOT-PASSWORD` in Key Vault.** The database keeps the old password and the app can't connect.
3. **Never delete the resource group `rg-innvoice-data`** or remove its lock `keep-data`. It holds your data and backups.
4. **Never edit Invoice Ninja's own files** (`docker-compose.yml`, `.env`, …). Put changes in `azure/`.
5. **Never jump MySQL major versions** (e.g. 8.4 → 9.x) without a backup and a test.
6. **Keep 2FA on your GitHub account.** Whoever controls your fork controls what the VM runs.

`rg-innvoice-app` can be deleted at any time without losing data; `./deploy.sh` recreates it.

---

## Command reference

All commands run in Git Bash from `debian/azure`, after `az login`.

| Command | What it does |
|---|---|
| `./deploy.sh` | Create or repair everything, then restart the app |
| `./deploy.sh status` | URL, version, container status |
| `./deploy.sh update [version]` | Backup → latest code → (new version) → restart |
| `./deploy.sh rebuild-vm` | Replace the VM with a fresh one (asks for confirmation) |
| `./deploy.sh rotate-mail-secret` | Renew the email password (every 2 years) |
| `./deploy.sh ops start` | Reload settings from Key Vault and restart |
| `./deploy.sh ops stop` | Stop the app (data is kept) |
| `./deploy.sh ops backup [label]` | Backup now |
| `./deploy.sh ops list` | List backups |
| `./deploy.sh ops restore <name>` | Restore a backup |

Optional settings for `deploy.sh` (put them before the command, e.g. `VM_SIZE=Standard_B2ms ./deploy.sh`):
`LOCATION`, `VM_SIZE`, `DNS_LABEL`, `ADMIN_EMAIL`, `REPO`, `BRANCH`, `DEFAULT_TAG`, `DOCKER_VERSION`.
`VM_SIZE` and `DOCKER_VERSION` only apply when a VM is created (first deploy or `rebuild-vm`).

---

## Limits and known risks

| Topic | Details |
|---|---|
| One VM | During updates, restarts and Sunday patching the app is briefly offline (usually 1–3 minutes). |
| One region | If Germany West Central is down, the app is down. The backups also have a copy in another region, but moving there is manual. |
| Up to 6 hours of loss | If the data disk itself is damaged, you return to the last backup. |
| Performance | B2s suits a small team. If the app feels slow or PDF generation fails, use a bigger VM: `az vm resize -g rg-innvoice-app -n vm-innvoice --size Standard_B2ms` (~€65/month). |
| Data disk size | 32 GB. To grow it: stop the VM, resize the disk in the portal, start the VM, then run `sudo resize2fs $(findfs LABEL=innvoice-data)` on the VM. |
| Key Vault deletion | Deleted vaults are kept for 90 days and the name stays blocked. That's a safety feature. |
| Docker Hub | Images are downloaded from Docker Hub. If it is unreachable, restarts use the copies already on the VM. |
