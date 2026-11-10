<p align="center">
  <img src="https://img.shields.io/badge/Docker-2496ED?style=for-the-badge&logo=docker&logoColor=white" alt="Docker">
  <img src="https://img.shields.io/badge/HashiCorp-000000?style=for-the-badge&logo=hashicorp&logoColor=white" alt="HashiCorp">
  <img src="https://img.shields.io/badge/IBM-052FAD?style=for-the-badge&logo=ibm&logoColor=white" alt="IBM">
  <img src="https://img.shields.io/badge/Microsoft-0078D4?style=for-the-badge&logo=microsoft&logoColor=white" alt="Microsoft">
</p>

<h1 align="center">SMTP2Graph</h1>

<p align="center">
  <b>SMTP → Microsoft Graph bridge, with credentials protected by HashiCorp Vault</b><br>
  <i>Ponte SMTP → Microsoft Graph, com credenciais protegidas pelo HashiCorp Vault</i>
</p>

<p align="center">
  🇺🇸 <a href="#english"><b>English</b></a> &nbsp;·&nbsp; 🇧🇷 <a href="#português"><b>Português</b></a>
</p>

---

# English

A complete, step-by-step guide for letting an application that **only supports SMTP settings** (ERP, invoice issuer, legacy system) send e-mail to **external customers** through **Microsoft 365**, using modern authentication (OAuth). The Service Principal credentials are protected in **HashiCorp Vault**. It runs on **Windows** (Docker Desktop) and on **Linux** (Docker Engine): every step shows the commands for both.

> 💡 The same content is available in **GUIA.html**, which is easier to read. Double-click it to open it in your browser.

## 1. What it is and how it works

Think of the bridge as a **"translator"**. Your application speaks SMTP, the "old language" of e-mail. Microsoft prefers the Graph API with OAuth, the "new", more secure language. The bridge sits in the middle and translates. The **vault** stores the "key" the bridge uses to sign in to Microsoft.

```
 ┌───────────────┐ SMTP (port 25)  ┌───────────────┐   AppRole    ┌─────────────────┐
 │ Your app      │ ──────────────► │  SMTP2Graph   │ ───────────► │ HashiCorp Vault │
 │ (ERP/invoices)│                 │   (Docker)    │ ◄─────────── │ Tenant/Client ID│
 └───────────────┘                 └───────┬───────┘  credentials │ and secret      │
                                           │                      └─────────────────┘
                                           │ HTTPS + OAuth (Microsoft Graph)
                                           ▼
 ┌───────────────┐                 ┌───────────────┐
 │ External      │ ◄────────────── │ Microsoft 365 │
 │ customer      │ e-mail+invoice  │ notas@company │
 └───────────────┘                 └───────────────┘
```

**The three containers:**

| Container | Role |
|---|---|
| `smtp2graph-vault` | **HashiCorp Vault**, a secrets vault. It stores the Service Principal's Tenant ID, Client ID and secret, encrypted |
| `smtp2graph-vault-unseal` | (Optional) Unseals Vault automatically when the computer restarts |
| `smtp2graph` | The **bridge**: receives SMTP from the application and delivers it to Microsoft through Graph |

**What the bridge does with each e-mail:**

1. Receives the e-mail from the application over SMTP.
2. Checks three things: the **bridge username/password**, whether the **sender** is the allowed mailbox (e.g. `notas@suaempresa.com.br`), and whether the connection comes from an **allowed network**.
3. Uses the Service Principal credentials **read from Vault** to request a **token** (a ~1-hour "pass") from Microsoft.
4. Delivers the **whole e-mail, with attachments**, to Microsoft through the Graph API.
5. Tells the application whether it worked (`250`), whether to retry later (`451`) or whether something must be fixed (`550`).

**Why this is secure:**

- The **Service Principal secret is never stored in a text file**. It is encrypted inside Vault.
- The bridge signs in to Vault with an **AppRole** that has **READ-only** access to a single path (`secret/smtp2graph/entra`).
- The Entra ID app can only send **from the invoice mailbox**, thanks to RBAC for Applications (Step 4).
- The application **never knows any Microsoft 365 password**.
- Vault **only accepts connections from this machine** (`127.0.0.1`) and from the internal Docker network.
- To **rotate** the Service Principal secret, just update it in Vault. The bridge picks it up within 5 minutes, with no restart.

> ℹ️ **HashiCorp Vault** is a HashiCorp product. HashiCorp has been an **IBM** company since 2025. This project uses the free Community edition.

## 2. What is in this folder

```
D:\SMTP2Graph\
├── README.md                ← this guide (English and Portuguese)
├── GUIA.html                ← the same guide, for the browser
├── docker-compose.yml       ← starts Vault + auto-unseal + bridge (PRODUCTION)
├── .env.example             ← configuration template (copy to .env); contains NO secrets
├── .gitignore / .gitattributes
├── ponte\                   ← the bridge program (Python, commented)
│   ├── smtp2graph.py
│   ├── healthcheck.py
│   ├── requirements.txt
│   └── Dockerfile
├── vault\
│   ├── config\vault.hcl     ← Vault server configuration
│   ├── auto-unseal.sh       ← unseals Vault after a restart (optional)
│   ├── approle\             ← receives role_id and secret_id (the bridge's Vault login)
│   └── unseal\              ← receives unseal.key (only if auto-unseal is enabled)
├── certs\                   ← (optional) certificates to encrypt SMTP
├── scripts\                  ← Windows (.ps1) and Linux (.sh)
│   ├── 1-configurar-permissao-exchange.ps1 / .sh  ← Step 4, Option A (RBAC, recommended)
│   ├── 1b-permissao-via-graph.ps1 / .sh           ← Step 4, Option B (Microsoft Graph)
│   ├── 2-configurar-vault.ps1 / .sh               ← sets up Vault and stores the Service Principal (Step 8)
│   ├── 3-liberar-firewall-windows.ps1             ← firewall on Windows (Step 10)
│   └── 3-liberar-firewall-linux.sh                ← firewall on Linux (Step 10)
└── app-teste\               ← TEST application with an SMTP settings screen
```

## 3. Before you start

| What | Why | How to check |
|---|---|---|
| 🪟 **Docker Desktop** installed and running | To run Vault, the bridge and the test app | PowerShell: `docker version` (must show *Client* and *Server*) |
| 🐧 **Docker Engine** + **compose plugin**, **curl** | Same, on Linux | `docker compose version` and `curl --version` |
| 🐧 (optional) **PowerShell 7** (`pwsh`) | Step 4 on Linux. Or run Step 4 from any Windows PC | `pwsh --version` |
| 🐧 (optional) **Azure CLI** (`az`) | Step 4, Option B on Linux | `az version` |
| **Exchange Administrator** account | To create the mailbox and grant the permission | Microsoft 365 admin → Roles |
| **Application Administrator** (or Global) account | To register the app in Entra ID | Entra admin → Roles |
| Access to the domain's **DNS** | SPF, DKIM and DMARC (anti-spam) | Your DNS provider |
| This machine's **internal IP** | The application will point to it | PowerShell: `ipconfig` → "IPv4 Address" |
| A **password manager** (Bitwarden, 1Password, KeePass...) | To store Vault's unseal key and root token | — |

**🪟 Windows or 🐧 Linux?** The examples use `D:\SMTP2Graph` on Windows and `/opt/smtp2graph` on Linux. To move the folder from a Windows PC to a Linux server:

```powershell
scp -r D:\SMTP2Graph usuario@servidor:/opt/smtp2graph
```

On Linux, run the scripts with `bash scripts/<name>.sh`. Scripts that need administrator rights ask for `sudo` by themselves.

> ⚠️ **Production on Windows:** Docker Desktop only starts **after someone signs in to Windows**. For real production, use an **always-on server**: Linux with Docker Engine, or Windows with automatic sign-in and Docker Desktop set to start with it (*Settings → General → Start Docker Desktop when you sign in*).

**Write these down as you go** (you will type them in Step 8):

| Item | Value |
|---|---|
| Sending mailbox | `notas@suaempresa.com.br` |
| Directory (Tenant) ID | |
| Application (Client) ID | |
| Object ID (from *Enterprise applications*) | |
| Secret value (Client Secret) | |
| Secret expiry date | |

## Part A — Configure Microsoft 365

### Step 1 — Create the sending mailbox

We will create a **shared mailbox**. It needs no license and nobody signs in to it: it is just the "official sender" of the invoices.

1. Go to **https://admin.exchange.microsoft.com**.
2. Open **Recipients → Mailboxes → Add a shared mailbox**.
3. **Display name:** `Notas Fiscais - Your Company`. **Address:** `notas@suaempresa.com.br`.
4. Click **Create**.
5. (Recommended) Add as **members** the people who should see customer replies.

### Step 2 — Register the app in Entra ID

The "app" (Service Principal) is the **bridge's identity** inside Microsoft, like a badge.

1. Go to **https://entra.microsoft.com** → **Identity → Applications → App registrations → + New registration**.
2. **Name:** `SMTP2Graph - Invoice Sending`. **Account types:** *This organizational directory only*. **Redirect URI:** leave empty.
3. Click **Register**. On **Overview**, write down:
   - **Application (client) ID** → the *Client ID*
   - **Directory (tenant) ID** → the *Tenant ID*
4. Go to **Identity → Applications → Enterprise applications**, open the app and write down its **Object ID**.

> ⚠️ The "Object ID" under *App registrations* is **different** from the one under *Enterprise applications*. Use the one from **Enterprise applications**.

### Step 3 — Create the app secret

1. **App registrations** → your app → **Certificates & secrets → + New client secret**.
2. Description: `smtp2graph-production`. Expiry: up to 24 months.
3. **Copy the "Value" column IMMEDIATELY**, because it is only shown now. Do not confuse it with the "Secret ID".

> 🔐 This value goes into **Vault** in Step 8. After that, **delete it** from your notes.
>
> 📅 Set a calendar reminder **30 days before it expires**.

**API permissions: do NOT add anything.** Do not grant `Mail.Send` under *API permissions*, because that would let the app send e-mail **as anyone in the company**. The permission is granted in the next step, **scoped to the invoice mailbox**.

### Step 4 — Grant send permission ONLY for the invoice mailbox

The app needs permission to **send mail**, but only **as the invoice mailbox**. There are two ways to do it. **Pick ONE.**

| | Option A — RBAC for Applications | Option B — Microsoft Graph commands |
|---|---|---|
| Where the permission lives | Exchange Online | Entra ID (Microsoft Graph) |
| Default reach | **Only** the invoice mailbox | **ALL** mailboxes in the company |
| How it is restricted | Built in (management scope) | Application Access Policy (legacy) |
| Microsoft's recommendation | ✅ Recommended | ⚠️ Microsoft advises against creating new Application Access Policies |

> 🛑 **Do not mix them.** If Mail.Send is granted in Entra ID (Option B), it applies to the whole company and the Exchange scope from Option A **no longer limits anything**. Using Option A? Make sure Mail.Send is **not** granted in Entra ID. Use the check at the end of this step.

> ℹ️ This step does **not** need to run on the Docker server. You can run it from any administrator PC.

#### Option A — RBAC for Applications (recommended)

🪟 **Windows (PowerShell):**

```powershell
cd D:\SMTP2Graph\scripts
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\1-configurar-permissao-exchange.ps1 `
   -AppId    "APPLICATION-ID" `
   -ObjectId "OBJECT-ID-FROM-ENTERPRISE-APPLICATIONS" `
   -Caixa    "notas@suaempresa.com.br"
```

🐧 **Linux (bash + PowerShell 7):**

```bash
cd /opt/smtp2graph
bash scripts/1-configurar-permissao-exchange.sh \
   -AppId    "APPLICATION-ID" \
   -ObjectId "OBJECT-ID-FROM-ENTERPRISE-APPLICATIONS" \
   -Caixa    "notas@suaempresa.com.br"
```

On Linux, sign-in uses a **code**: open the link shown on any computer and type the code. If `pwsh` is not installed, the script shows how to install it.

Sign in with the **Exchange Administrator** account. Expected result at the end: **InScope = True**.

| Command the script runs | In plain English |
|---|---|
| `New-ServicePrincipal` | "Exchange, meet the SMTP2Graph app." |
| `New-ManagementScope` | "Create a group containing **only** the `notas@...` mailbox." |
| `New-ManagementRoleAssignment` | "Give the app **send mail** permission, only inside that group." |
| `Test-ServicePrincipalAuthorization` | "Check that it is right." |

#### Option B — Microsoft Graph commands

Here the permission is granted directly on the app in Entra ID, with Microsoft Graph commands. Technically this creates an **app role assignment** of `Mail.Send` (type *Application*) from the "Microsoft Graph" Service Principal to your app. It is the same as clicking **API permissions → Add → Mail.Send → Grant admin consent** in the portal, only by command.

**B.1 — Grant Mail.Send**

🪟 **Windows — Microsoft Graph PowerShell:**

```powershell
Install-Module Microsoft.Graph.Applications -Scope CurrentUser
# Sign in with a Global Administrator or Privileged Role Administrator account
Connect-MgGraph -Scopes "Application.Read.All","AppRoleAssignment.ReadWrite.All"

# "Microsoft Graph" Service Principal (its appId is the same in every tenant)
$graphSp  = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
# The Mail.Send permission of type Application
$mailSend = $graphSp.AppRoles | Where-Object { $_.Value -eq "Mail.Send" -and $_.AllowedMemberTypes -contains "Application" }
# YOUR app's Service Principal
$appSp    = Get-MgServicePrincipal -Filter "appId eq 'APPLICATION-ID'"

New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $appSp.Id `
    -PrincipalId $appSp.Id -ResourceId $graphSp.Id -AppRoleId $mailSend.Id
```

🐧 **Linux — Azure CLI calling the Graph API:**

```bash
az login --use-device-code --allow-no-subscriptions

GRAPH_SP=$(az ad sp show --id 00000003-0000-0000-c000-000000000000 --query id -o tsv)
MAIL_SEND=$(az ad sp show --id 00000003-0000-0000-c000-000000000000 \
  --query "appRoles[?value=='Mail.Send' && contains(allowedMemberTypes,'Application')].id | [0]" -o tsv)
APP_SP=$(az ad sp show --id APPLICATION-ID --query id -o tsv)

az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$APP_SP/appRoleAssignments" \
  --headers "Content-Type=application/json" \
  --body "{\"principalId\":\"$APP_SP\",\"resourceId\":\"$GRAPH_SP\",\"appRoleId\":\"$MAIL_SEND\"}"
```

> ⚠️ After B.1, the app can send as **anyone in the company**. Do B.2 right away.

**B.2 — Restrict to the invoice mailbox (Application Access Policy)**

These commands (`New-DistributionGroup`, `New-ApplicationAccessPolicy`, `Test-ApplicationAccessPolicy`) are **not** Microsoft Graph commands. They belong to **Exchange Online PowerShell**. The `Connect-MgGraph` sign-in from B.1 does **not** work for them: you need a **separate sign-in to Exchange Online**.

| What | Details |
|---|---|
| Module | `ExchangeOnlineManagement` (install once) |
| Sign-in command | `Connect-ExchangeOnline` |
| Account | A Microsoft 365 user with the **Exchange Administrator** role (or Global Administrator) |
| Windows | Runs in PowerShell 5.1 or 7. A Microsoft sign-in window opens |
| Linux | Runs in `pwsh` with `-Device`: open the link on any computer and type the code |

```powershell
# 1) Install the module (first time only)
Install-Module ExchangeOnlineManagement -Scope CurrentUser

# 2) Sign in to Exchange Online with the Exchange Administrator account
Connect-ExchangeOnline -UserPrincipalName admin@suaempresa.com.br
#    Linux (pwsh): Connect-ExchangeOnline -UserPrincipalName admin@suaempresa.com.br -Device

# Mail-enabled security group containing only the invoice mailbox
New-DistributionGroup -Name "SMTP2Graph - Remetentes" -Alias smtp2graph-remetentes `
    -Type Security -Members notas@suaempresa.com.br

# The app can only reach members of that group
New-ApplicationAccessPolicy -AppId APPLICATION-ID `
    -PolicyScopeGroupId smtp2graph-remetentes@suaempresa.com.br `
    -AccessRight RestrictAccess -Description "SMTP2Graph: invoice mailbox only"

# Test: Granted for the invoice mailbox, Denied for any other
Test-ApplicationAccessPolicy -Identity notas@suaempresa.com.br -AppId APPLICATION-ID
Test-ApplicationAccessPolicy -Identity your.name@suaempresa.com.br -AppId APPLICATION-ID
```

**Ready-made scripts for Option B** (they do B.1 and B.2, with confirmations):

```powershell
# Windows
.\1b-permissao-via-graph.ps1 -AppId "APPLICATION-ID" -Acao Conceder -Caixa "notas@suaempresa.com.br"
```

```bash
# Linux
bash scripts/1b-permissao-via-graph.sh conceder   APPLICATION-ID
bash scripts/1b-permissao-via-graph.sh restringir APPLICATION-ID notas@suaempresa.com.br
```

#### Check with Microsoft Graph (recommended for both options)

This shows whether the app has Mail.Send granted in Entra ID:

```powershell
.\1b-permissao-via-graph.ps1 -AppId "APPLICATION-ID" -Acao Verificar        # Windows
```

```bash
bash scripts/1b-permissao-via-graph.sh verificar APPLICATION-ID              # Linux
```

| Your choice | Expected result |
|---|---|
| Option A (RBAC) | `Mail.Send (Entra): not granted`. If it shows **GRANTED**, remove it with `-Acao Remover` / `remover` |
| Option B (Graph) | `Mail.Send (Entra): GRANTED`, **and** `Test-ApplicationAccessPolicy` = `Granted` for the invoice mailbox only |

> ⏳ Either way, the permission can take **30 minutes to 2 hours** to take effect.

> 🔄 **After changing any permission in this step, restart the bridge:** `docker compose restart smtp2graph`. The bridge reuses its Microsoft access token for up to about 1 hour, so a permission granted after its last sign-in only applies after a restart. If the error continues, wait for propagation and restart again.

> ⚠️ **Option B needs B.1 AND B.2.** B.2 (Application Access Policy) only *restricts*; it grants nothing. `Test-ApplicationAccessPolicy` says `Granted` even when Mail.Send was never granted, so always confirm with `-Acao Verificar`. And `Test-ServicePrincipalAuthorization` only applies to Option A: with Option B it says "couldn't be found", which is normal.

### Step 5 — Configure DNS (to stay out of spam)

**SPF**: the domain's TXT record (only one is allowed):

```
v=spf1 include:spf.protection.outlook.com -all
```

**DKIM**: at **https://security.microsoft.com** → **Email & collaboration → Policies & rules → Threat policies → Email authentication settings → DKIM**. Create in DNS the two CNAME records the screen shows (`selector1._domainkey` and `selector2._domainkey`), then enable signing.

**DMARC**: a TXT record named `_dmarc`:

```
v=DMARC1; p=none; rua=mailto:dmarc@suaempresa.com.br
```

After a few weeks without problems, change it to `p=quarantine`.

## Part B — HashiCorp Vault and the bridge

### Step 6 — Fill in the .env file (no secrets!)

🪟 **Windows:**

```powershell
cd D:\SMTP2Graph
Copy-Item .env.example .env
notepad .env
```

🐧 **Linux:**

```bash
cd /opt/smtp2graph
cp .env.example .env
chmod 600 .env
nano .env
```

| Variable | What to enter | Example |
|---|---|---|
| `ALLOWED_SENDERS` | The invoice mailbox (several: comma-separated) | `notas@suaempresa.com.br` |
| `SMTP_USERNAME` | A username **you make up** for the application | `app-notas` |
| `SMTP_PASSWORD` | A password **you make up** (12+ characters) | `Gere-Uma-Senha-Sua-2026` |
| `VAULT_ADDR` | Vault address (do not change) | `http://vault:8200` |
| `VAULT_REFRESH_SECONDS` | How often the bridge re-reads Vault | `300` (5 min) |
| `ALLOWED_NETWORKS` | Allowed IP ranges | leave as is |
| `LOG_LEVEL` | `INFO` normally, `DEBUG` for troubleshooting | `INFO` |

> 🔐 The **Tenant ID, Client ID and secret do NOT go in `.env`**: they go into Vault in Step 8.
>
> 🔐 `SMTP_USERNAME` and `SMTP_PASSWORD` are **not Microsoft 365 credentials**. They are a "front-door password" between the application and the bridge.

### Step 7 — Start the containers

```powershell
cd D:\SMTP2Graph            # Linux: cd /opt/smtp2graph
docker compose up -d --build
docker compose ps
```

On Linux, if you get `permission denied ... docker.sock`, put `sudo` in front of the `docker` commands (or add your user to the `docker` group).

At this point it is **normal** to see:

- `smtp2graph-vault` as **unhealthy**: Vault has not been initialized yet. It becomes *healthy* after Step 8.
- The bridge waiting for Vault. Check it with `docker compose logs smtp2graph`:

```
INFO    Credenciais do Service Principal: HashiCorp Vault (http://vault:8200)
WARNING Aguardando o Vault: o Vault está SELADO (sealed)... Nova tentativa em 15s.
```

(The bridge logs are in Portuguese. "Aguardando o Vault" means "waiting for Vault".)

### Step 8 — Set up Vault and store the Service Principal

This is the main step. The script does everything and **asks for the Service Principal data**.

🪟 **Windows:**

```powershell
cd D:\SMTP2Graph\scripts
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\2-configurar-vault.ps1
```

🐧 **Linux:**

```bash
cd /opt/smtp2graph
sudo bash scripts/2-configurar-vault.sh
```

Both versions ask the same questions and have the same menu. The Linux version uses the Vault CLI **inside** the container, so the server only needs Docker and curl. It also sets the owner of the `vault/approle` files so the bridge can read them.

**What happens, in order:**

1. **Vault initialization.** The script shows **two values that are displayed ONLY ONCE**:

   | Value | What it is for |
   |---|---|
   | **Unseal key** | Unlocks Vault after every restart. **Without it, the data in Vault can never be recovered** |
   | **Root token** | Vault's "administrator password". You will use it to update the secret in the future |

   👉 **Store both in your password manager** and type `OK`. The screen is cleared right after.

2. **Automatic configuration:** the script creates the `secret/` store, the read-only `smtp2graph-read` policy and the bridge's AppRole, and saves `role_id` and `secret_id` in `vault\approle\`.

3. **Auto-unseal:** the script asks whether Vault should **unseal itself** after a restart.
   - **Yes (recommended for an unattended server):** the key is saved in `vault\unseal\unseal.key` (on Linux, with `chmod 600`).
   - **No (more secure):** after each restart, run the script and choose **option 2** to unseal.

4. **Service Principal data:** the script asks for:

   | Prompt | What to type |
   |---|---|
   | `Tenant ID` | Directory ID (Step 2) |
   | `Client ID` | Application ID (Step 2) |
   | `Client Secret VALUE` | The secret **Value** (Step 3). Typing is **hidden** |

   Before saving, the script **tests the sign-in to Microsoft**. If you see **[OK] Sign-in succeeded**, the credentials are stored in Vault at `secret/smtp2graph/entra`.

> ⚖️ **About auto-unseal:** it is convenient, but anyone who can read the `vault\unseal\` folder **and** the Docker volume can open the vault. Protect `D:\SMTP2Graph` (Properties → Security: Administrators only). On Linux: `sudo chown -R root:root /opt/smtp2graph/vault/unseal && sudo chmod 700 /opt/smtp2graph/vault/unseal`. For maximum security, leave it off and unseal manually. An advanced alternative is auto-unseal with Azure Key Vault (`seal "azurekeyvault"` in `vault.hcl`).

### Step 9 — Check that the bridge started

```powershell
docker compose ps
docker compose logs --tail 20 smtp2graph
```

All three containers should be **Up**, with `smtp2graph-vault` and `smtp2graph` **healthy**. What you **want to see** in the log:

```
INFO    Credenciais do Service Principal: HashiCorp Vault (http://vault:8200)
INFO    Login na Microsoft (OAuth) OK para o app e5f6a7b8-...
INFO    Ouvindo SMTP em 0.0.0.0:2525
INFO    Autenticação SMTP: LIGADA | TLS (STARTTLS): desligado
```

("Login na Microsoft OK" = Microsoft sign-in OK; "Ouvindo SMTP" = listening for SMTP.)

And port 25 responding:

```powershell
Test-NetConnection -ComputerName localhost -Port 25      # Windows → TcpTestSucceeded : True
```

```bash
nc -zv 127.0.0.1 25                                       # Linux   → succeeded / open
```

### Step 10 — Firewall (only if the application runs on ANOTHER machine)

🪟 **Windows** — open PowerShell **as Administrator**:

```powershell
cd D:\SMTP2Graph\scripts
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\3-liberar-firewall-windows.ps1 -RedeOrigem "192.168.0.0/24"
```

🐧 **Linux:**

```bash
cd /opt/smtp2graph
sudo bash scripts/3-liberar-firewall-linux.sh 192.168.0.0/24,172.16.0.0/12 --persistir
```

- `192.168.0.0/24` = your network (or just the application's IP). Separate several with commas.
- `172.16.0.0/12` = Docker's internal networks. Include it if you will use the test app, or an application in Docker on the same server.
- `--persistir` = re-apply the rule after a reboot (it creates the `smtp2graph-firewall` systemd service).
- To undo: `sudo bash scripts/3-liberar-firewall-linux.sh --remover`

> ⚠️ **Linux: `ufw` and `firewalld` do NOT protect ports published by Docker.** Docker writes its own iptables rules first. That is why the script uses Docker's own chain for this (`DOCKER-USER`).
>
> 🚫 **Never** port-forward port 25 on your router. The bridge is for **internal** use only.
>
> ℹ️ On **Docker Desktop (Windows)**, the bridge sees every connection as coming from Docker itself, so `ALLOWED_NETWORKS` in `.env` cannot filter by the real IP. On **Linux** the bridge sees the real IP, so `ALLOWED_NETWORKS` also works as an extra layer.

## Part C — Test with the test application

### Step 11 — Start the test app and send

```powershell
cd D:\SMTP2Graph\app-teste      # Linux: cd /opt/smtp2graph/app-teste
docker compose up -d --build
```

Open **http://localhost:8080** (on a Linux server without a browser, use **http://SERVER-IP:8080** from your PC) and fill in:

| Field | Value |
|---|---|
| Servidor SMTP (SMTP server) | `host.docker.internal` (pre-filled; means "this computer") |
| Porta (Port) | `25` |
| Usuário / Senha (Username / Password) | `SMTP_USERNAME` and `SMTP_PASSWORD` from `.env` |
| Segurança (Security) | `Nenhuma` (none — internal network) |
| Remetente (Sender) | `notas@suaempresa.com.br` |
| Destino (Recipient) | **one of your own e-mails outside the company** (Gmail, Outlook.com...) |

Two extra buttons help before sending:

- **Testar comunicação** (test connection): connects to the bridge, does the security and the sign-in, and asks whether the sender is accepted, **without sending any e-mail**. It does **not** check the Microsoft 365 permission (Step 4); that only shows up when you send.
- **Salvar configurações** (save settings): keeps the fields filled in the next time you open the page (stored in the `smtp2graph-app-teste-dados` Docker volume). The password is only saved if you tick **Salvar também a senha**; it is then stored as plain text inside the container.

Click **Enviar nota fiscal de teste** (send test invoice). **Expected:** a green banner, and the e-mail arrives with `DANFE_000123.pdf` and `NFe_000123.xml`.

In Gmail, open **⋮ → Show original** and check that it shows **SPF: PASS**, **DKIM: PASS** and **DMARC: PASS**.

**Security tests (recommended):**

| Test | Expected result |
|---|---|
| Wrong password | ❌ `535 Authentication credentials invalid` |
| No username | ❌ `530 Authentication required` |
| Sender `diretor@suaempresa.com.br` | ❌ `550 ... nao autorizado nesta ponte` (not allowed) |

Stop the test app when you are done: `docker compose down`, inside the `app-teste` folder.

## Part D — Connect the production application

### Step 12 — Configure the real application

| Application field | Value |
|---|---|
| **SMTP server / Host** | This machine's IP (e.g. `192.168.0.50`), or `localhost` if the app runs here |
| **Port** | `25` |
| **Username / Password** | `SMTP_USERNAME` / `SMTP_PASSWORD` from `.env` |
| **SSL/TLS** | None (STARTTLS only if you configured `certs\`) |
| **Sender (From)** | `notas@suaempresa.com.br`, **exactly** the allowed mailbox |
| **Reply-To** | optional, e.g. `financeiro@suaempresa.com.br` |

Before going live for customers, send **one real invoice to yourself**.

### ✅ Production checklist

- [ ] `notas@...` mailbox created
- [ ] App registered **without** `Mail.Send` under API permissions
- [ ] **InScope = True** for the invoice mailbox and **False** for other mailboxes
- [ ] SPF, DKIM and DMARC all **PASS**
- [ ] **Unseal key and root token stored in a password manager**
- [ ] Decided: auto-unseal **on** (folder protected) or **off** (manual unseal)
- [ ] Service Principal secret **deleted from your notes** (it now exists only in Vault)
- [ ] `.env` with strong `SMTP_USERNAME` and `SMTP_PASSWORD`
- [ ] `docker compose ps`: `smtp2graph-vault` and `smtp2graph` **healthy**
- [ ] Firewall open to the internal network only, no port forwarding
- [ ] NTFS permissions on `D:\SMTP2Graph` restricted to Administrators
- [ ] Vault volume backed up (see Maintenance)
- [ ] Reminder set to **rotate the secret** before it expires
- [ ] Machine always on, with Docker starting automatically

## Day-to-day maintenance

| Task | Command (in `D:\SMTP2Graph`) |
|---|---|
| Check status | `docker compose ps` |
| Latest sends | `docker compose logs --tail 50 smtp2graph` |
| Follow live | `docker compose logs -f smtp2graph` |
| Find an e-mail (Windows) | `docker compose logs smtp2graph \| Select-String "customer@company.com"` |
| Find an e-mail (Linux) | `docker compose logs smtp2graph \| grep "customer@company.com"` |
| Restart the bridge | `docker compose restart smtp2graph` |
| Apply `.env` changes | `docker compose up -d` |
| Stop everything | `docker compose down` |

> 🛑 **NEVER run `docker compose down -v`.** The `-v` flag **deletes the Vault volume**, with every secret in it.

### 🔑 Rotate the Service Principal secret (before it expires)

1. Entra ID → your app → **Certificates & secrets → + New client secret** → copy the **Value**.
2. Run `.\2-configurar-vault.ps1` (Linux: `sudo bash scripts/2-configurar-vault.sh`) → **option 1** → enter the **root token** and the new data.
3. The bridge picks up the new secret **by itself within 5 minutes**. To apply it now: `docker compose restart smtp2graph`.
4. Check for `Login na Microsoft (OAuth) OK` in the log, and only then delete the old secret in Entra ID.

### 🔓 Unseal Vault after a restart (if auto-unseal is off)

`.\2-configurar-vault.ps1` (Linux: `sudo bash scripts/2-configurar-vault.sh`) → **option 2** → paste the **unseal key**. The bridge recovers by itself within 15 seconds.

### 🔁 Rotate the bridge's Vault login (AppRole)

`.\2-configurar-vault.ps1` (Linux: `sudo bash scripts/2-configurar-vault.sh`) → **option 3**. The old `secret_id` is destroyed. Then run `docker compose restart smtp2graph`.

### 🖥️ Vault web UI

Open **http://127.0.0.1:8210/ui** (on a Linux server, create an SSH tunnel first: `ssh -L 8210:127.0.0.1:8210 user@server`), choose **Token** and sign in with the root token. The secret is under **secret → smtp2graph → entra**. The UI only opens from this machine.

### 💾 Vault backup

🪟 **Windows:**

```powershell
cd D:\SMTP2Graph
docker compose stop vault
docker run --rm -v smtp2graph-vault-data:/data -v ${PWD}\backup:/backup alpine tar czf /backup/vault-data.tgz -C /data .
docker compose start vault
```

🐧 **Linux:**

```bash
cd /opt/smtp2graph
docker compose stop vault
docker run --rm -v smtp2graph-vault-data:/data -v "$PWD/backup:/backup" alpine tar czf /backup/vault-data.tgz -C /data .
docker compose start vault
```

If auto-unseal is off, unseal Vault afterwards (option 2). Keep the backup somewhere safe. Remember that **the backup alone opens nothing**: you also need the unseal key.

## Important limits

| Limit | Value | If exceeded |
|---|---|---|
| Recipients per day (per mailbox) | **10,000** | Exchange blocks the mailbox for 24h |
| Messages per minute (per mailbox) | **30** | The bridge holds and waits automatically |
| E-mail size with attachments | **~2.9 MB** | Error `552` (an invoice is usually under 300 KB) |
| Recipients per e-mail | **100** (configurable) | Error `452` |

## Troubleshooting

First step, **always**: `docker compose logs --tail 50 smtp2graph`.

| Error | Cause | Fix |
|---|---|---|
| `Aguardando o Vault: o Vault está SELADO` | Vault restarted and is sealed | Script → option 2, or enable auto-unseal |
| `Aguardando o Vault: arquivos do AppRole ... não encontrados` | Vault not configured yet | Run `.\2-configurar-vault.ps1` (Step 8) |
| `Aguardando o Vault: segredo ... não encontrado` | Service Principal not stored | Script → option 1 |
| `o Vault recusou o login do AppRole` | Invalid `role_id`/`secret_id` | Script → option 3, then `docker compose restart smtp2graph` |
| `não consegui conectar no Vault` | Vault container stopped | `docker compose up -d` |
| Script: `Cannot reach Vault` | Vault is not running | `docker compose up -d` and `docker compose ps` |
| First run of `2-configurar-vault.ps1` shows the **menu** or asks for an unseal key you never received | The script is talking to **another Vault** on the same port (e.g. from another project). `smtp2graph-vault` shows only `8200/tcp` in `docker ps`, without `127.0.0.1:8210->` | `docker ps` to see who uses the port. Do not type the other Vault's key. Change the left side of `"127.0.0.1:8210:8200"` in `docker-compose.yml` to a free port, `docker compose up -d`, and run the script with `-VaultAddr http://127.0.0.1:<port>` |
| Script: `Bind for 127.0.0.1:8210 failed: port is already allocated` | Another program uses port 8210 | Same as above: pick a free port in `docker-compose.yml` and use `-VaultAddr` |
| `smtp2graph-vault` **unhealthy** | Vault not initialized or sealed | Step 8, or script option 2 |
| `manifest for hashicorp/vault:2.2 not found` | Image tag not available | In `docker-compose.yml`, change both lines to `hashicorp/vault:latest` |
| Lost the unseal key | It cannot be recovered | `docker compose down`, `docker volume rm smtp2graph-vault-data`, `docker compose up -d` and redo Step 8 |
| `AADSTS7000215: Invalid client secret` | The Secret ID was stored instead of the Value | Script → option 1, with the **Value** |
| `AADSTS7000222: ... expired` | Secret expired | See "Rotate the secret" above |
| `AADSTS700016` / `AADSTS90002` | Wrong Client ID or Tenant ID | Script → option 1 |
| `ErrorAccessDenied` | Step 4 permission missing or not active yet | Option A: check **InScope = True**. Option B: check `-Acao Verificar` = CONCEDIDO (B.1) and the policy (B.2). Wait up to 2 hours, then `docker compose restart smtp2graph` |
| `ErrorAccessDenied: Access to OData is disabled: [RAOP] : Blocked by tenant configured AppOnly AccessPolicy settings` | Option B: the Application Access Policy is blocking. Either Mail.Send (B.1) was never granted, the mailbox is not in the group, or the policy is still propagating | Run `.\1b-permissao-via-graph.ps1 -AppId ... -Acao Verificar`, `Get-ApplicationAccessPolicy` and `Get-DistributionGroupMember smtp2graph-remetentes`. If everything is right, wait up to 2 hours and run `docker compose restart smtp2graph` |
| Permission fixed, but the bridge still returns the same error | The bridge reuses its Microsoft access token for up to ~1 hour. A token issued before the change does not carry the new permission | `docker compose restart smtp2graph` (forces a new sign-in) |
| `Test-ServicePrincipalAuthorization`: `couldn't be found` | Normal if you used **Option B**: this command only checks Option A (RBAC) | With Option B use `Test-ApplicationAccessPolicy` and `-Acao Verificar`. Do not mix the two options |
| `Test-ApplicationAccessPolicy` = `Granted`, but sending still fails | This test only checks the restriction (B.2). It also says Granted when Mail.Send was never granted (B.1) or when no policy exists | Run `-Acao Verificar`: it must show `Mail.Send (Entra): CONCEDIDO` |
| `ErrorSendAsDenied` | From differs from the allowed mailbox | Sender = `notas@...` |
| `535` / `530` | Bridge username/password wrong or missing | Check the `.env` values in the application |
| `550 Remetente ... nao autorizado` | Sender not in `ALLOWED_SENDERS` | Fix the sender or `.env` |
| `port is already allocated` (port 25) | Another program uses port 25 | In the compose file, change to `"2525:2525"` and use port 2525 |
| `running scripts is disabled on this system` | PowerShell policy | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` |
| 🐧 `permission denied ... docker.sock` | User is not allowed to use Docker | Use `sudo`, or `sudo usermod -aG docker $USER` and sign in again |
| 🐧 `/usr/bin/env: 'bash\r': No such file` | Script saved with Windows line endings | `sed -i 's/\r$//' scripts/*.sh` |
| 🐧 Bridge: `arquivos do AppRole ... não encontrados`, but the files exist | The bridge (uid 10001) cannot read them | Run `sudo bash scripts/2-configurar-vault.sh` → option 3 (it fixes the owner) |
| 🐧 App on another machine cannot connect | Firewall rule or cloud security group | `sudo iptables -L DOCKER-USER -n`; also allow port 25 in your cloud firewall (internal only) |
| Option B: `Test-ApplicationAccessPolicy` = `Denied` for the invoice mailbox | The mailbox is not in the group, or the policy is still propagating | `Get-DistributionGroupMember smtp2graph-remetentes`; wait up to 1-2 hours |
| `Connect-MgGraph`: insufficient privileges | Account is not an admin | Granting Microsoft Graph application permissions needs a Global Administrator or Privileged Role Administrator account |
| E-mail lands in **spam** | Incomplete DNS | Step 5 |

## Glossary

| Term | Plain explanation |
|---|---|
| **SMTP** | The "classic" protocol for sending e-mail |
| **Microsoft Graph** | Microsoft 365's API (the door programs use) |
| **OAuth / token** | Modern sign-in: the program gets a temporary "pass" instead of using a password |
| **Service Principal** | An application's identity in Entra ID (Tenant ID + Client ID + secret) |
| **HashiCorp Vault** | A secrets vault: stores passwords and keys encrypted and controls who can read them |
| **Seal / Unseal** | Vault "locks itself" (sealed) on restart; the unseal key "unlocks" it |
| **Root token** | Vault's administrator password |
| **AppRole** | A program's login to Vault (role_id + secret_id) |
| **KV v2** | The Vault "drawer" type that stores secrets with version history |
| **RBAC for Applications** | Exchange feature that limits which mailboxes an app can use |
| **SPF / DKIM / DMARC** | DNS records that prove an e-mail is legitimate |
| **Docker / container** | A "box" with the program and everything it needs to run |

---

# Português

Guia completo, passo a passo, para fazer uma aplicação que **só tem configuração de SMTP** (ERP, emissor de nota fiscal, sistema legado) enviar e-mails para **clientes externos** pelo **Microsoft 365**, usando autenticação moderna (OAuth). As credenciais do Service Principal ficam protegidas no **HashiCorp Vault**. Funciona no **Windows** (Docker Desktop) e no **Linux** (Docker Engine): cada passo mostra os comandos dos dois.

> 💡 Este mesmo conteúdo está no arquivo **GUIA.html**, com visual mais confortável. Dê dois cliques nele para abrir no navegador.

## 1. O que é e como funciona

Pense na ponte como um **"tradutor"**. A sua aplicação fala SMTP, a "língua antiga" do e-mail. A Microsoft prefere a API do Graph com OAuth, a "língua nova" e mais segura. A ponte fica no meio, traduzindo. E o **cofre** (Vault) guarda a "chave" que a ponte usa para entrar na Microsoft.

```
 ┌───────────────┐ SMTP (porta 25) ┌───────────────┐   AppRole    ┌─────────────────┐
 │ Sua aplicação │ ──────────────► │  SMTP2Graph   │ ───────────► │ HashiCorp Vault │
 │ (ERP / NF-e)  │                 │   (Docker)    │ ◄─────────── │ Tenant/Client ID│
 └───────────────┘                 └───────┬───────┘  credenciais │ e segredo       │
                                           │                      └─────────────────┘
                                           │ HTTPS + OAuth (Microsoft Graph)
                                           ▼
 ┌───────────────┐                 ┌───────────────┐
 │ Cliente       │ ◄────────────── │ Microsoft 365 │
 │ externo       │ e-mail com a NF │ notas@empresa │
 └───────────────┘                 └───────────────┘
```

**Os três containers:**

| Container | Função |
|---|---|
| `smtp2graph-vault` | O **HashiCorp Vault**, um cofre de segredos. Guarda o Tenant ID, o Client ID e o segredo do Service Principal, criptografados |
| `smtp2graph-vault-unseal` | (Opcional) Destranca o Vault sozinho quando o computador reinicia |
| `smtp2graph` | A **ponte**: recebe o SMTP da aplicação e entrega para a Microsoft pelo Graph |

**O que a ponte faz a cada e-mail:**

1. Recebe o e-mail da aplicação por SMTP.
2. Confere três coisas: o **usuário/senha da ponte**, se o **remetente** é a caixa liberada (ex.: `notas@suaempresa.com.br`) e se a conexão vem de uma **rede permitida**.
3. Usa as credenciais do Service Principal, que **leu do Vault**, para pedir um **token** (um "passe" de ~1 hora) para a Microsoft.
4. Entrega o e-mail **inteiro, com anexos**, para a Microsoft pela API do Graph.
5. Responde para a aplicação se deu certo (`250`), se é para tentar de novo (`451`) ou se há um erro a corrigir (`550`).

**Por que isso é seguro:**

- O **segredo do Service Principal não fica em arquivo de texto**. Ele fica criptografado dentro do Vault.
- A ponte entra no Vault com um **AppRole** que só tem permissão de **LEITURA** em um único caminho (`secret/smtp2graph/entra`).
- O aplicativo no Entra ID só consegue enviar **pela caixa de notas**, por causa do RBAC para Aplicativos (Passo 4).
- A aplicação **não conhece nenhuma senha do Microsoft 365**.
- O Vault **só aceita conexões desta máquina** (`127.0.0.1`) e da rede interna do Docker.
- Para **trocar o segredo** do Service Principal, basta atualizar no Vault. A ponte percebe sozinha em até 5 minutos, sem reiniciar.

> ℹ️ O **HashiCorp Vault** é um produto da HashiCorp, empresa da **IBM** desde 2025. Aqui usamos a edição Community, que é gratuita.

## 2. O que tem nesta pasta

```
D:\SMTP2Graph\
├── README.md                ← este guia (inglês e português)
├── GUIA.html                ← o mesmo guia, para abrir no navegador
├── docker-compose.yml       ← liga Vault + auto-unseal + ponte (PRODUÇÃO)
├── .env.example             ← modelo de configuração (copie para .env); NÃO tem segredos
├── .gitignore / .gitattributes
├── ponte\                   ← programa da ponte (Python, comentado)
│   ├── smtp2graph.py
│   ├── healthcheck.py
│   ├── requirements.txt
│   └── Dockerfile
├── vault\
│   ├── config\vault.hcl     ← configuração do servidor Vault
│   ├── auto-unseal.sh       ← destranca o Vault após reinício (opcional)
│   ├── approle\             ← recebe role_id e secret_id (login da ponte no Vault)
│   └── unseal\              ← recebe unseal.key (só se ativar o auto-unseal)
├── certs\                   ← (opcional) certificados para criptografar o SMTP
├── scripts\                  ← Windows (.ps1) e Linux (.sh)
│   ├── 1-configurar-permissao-exchange.ps1 / .sh  ← Passo 4, Opção A (RBAC, recomendada)
│   ├── 1b-permissao-via-graph.ps1 / .sh           ← Passo 4, Opção B (Microsoft Graph)
│   ├── 2-configurar-vault.ps1 / .sh               ← configura o Vault e grava o Service Principal (Passo 8)
│   ├── 3-liberar-firewall-windows.ps1             ← firewall no Windows (Passo 10)
│   └── 3-liberar-firewall-linux.sh                ← firewall no Linux (Passo 10)
└── app-teste\               ← aplicação de TESTE, com tela de configuração SMTP
```

## 3. Antes de começar

| O quê | Para quê | Como conferir |
|---|---|---|
| 🪟 **Docker Desktop** instalado e rodando | Rodar Vault, ponte e app de teste | PowerShell: `docker version` (precisa mostrar *Client* e *Server*) |
| 🐧 **Docker Engine** + **plugin compose**, **curl** | O mesmo, no Linux | `docker compose version` e `curl --version` |
| 🐧 (opcional) **PowerShell 7** (`pwsh`) | Passo 4 no Linux. Ou faça o Passo 4 em qualquer PC Windows | `pwsh --version` |
| 🐧 (opcional) **Azure CLI** (`az`) | Passo 4, Opção B no Linux | `az version` |
| Conta **Administrador do Exchange** | Criar a caixa e dar a permissão | Admin do Microsoft 365 → Funções |
| Conta **Administrador de Aplicativos** (ou Global) | Registrar o aplicativo no Entra ID | Admin do Entra → Funções |
| Acesso ao **DNS** do domínio | SPF, DKIM e DMARC (anti-spam) | Registro.br, Cloudflare, GoDaddy... |
| **IP interno** desta máquina | A aplicação vai apontar para ele | PowerShell: `ipconfig` → "Endereço IPv4" |
| Um **cofre de senhas** (Bitwarden, 1Password, KeePass...) | Guardar a chave de desbloqueio e o root token do Vault | — |

**🪟 Windows ou 🐧 Linux?** Os exemplos usam `D:\SMTP2Graph` no Windows e `/opt/smtp2graph` no Linux. Para levar a pasta de um PC Windows para um servidor Linux:

```powershell
scp -r D:\SMTP2Graph usuario@servidor:/opt/smtp2graph
```

No Linux, rode os scripts com `bash scripts/<nome>.sh`. Os que precisam de administrador pedem o `sudo` sozinhos.

> ⚠️ **Produção no Windows:** o Docker Desktop só liga **depois que alguém faz login no Windows**. Para produção de verdade, use um **servidor sempre ligado**: Linux com Docker Engine, ou Windows com login automático e o Docker Desktop configurado para iniciar junto (*Settings → General → Start Docker Desktop when you sign in*).

**Anote conforme for avançando** (você vai digitar no Passo 8):

| Item | Valor |
|---|---|
| Caixa de envio | `notas@suaempresa.com.br` |
| ID do diretório (Tenant ID) | |
| ID do aplicativo (Client ID) | |
| ID do objeto (de *Aplicativos empresariais*) | |
| Valor do segredo (Client Secret) | |
| Data de vencimento do segredo | |

## Parte A — Configurar o Microsoft 365

### Passo 1 — Criar a caixa de e-mail de envio

Vamos criar uma **caixa compartilhada**. Ela não precisa de licença e ninguém faz login nela: ela é só o "remetente oficial" das notas.

1. Acesse **https://admin.exchange.microsoft.com**.
2. Vá em **Destinatários → Caixas de correio → Adicionar uma caixa de correio compartilhada**.
3. **Nome de exibição:** `Notas Fiscais - Sua Empresa`. **Endereço:** `notas@suaempresa.com.br`.
4. Clique em **Criar**.
5. (Recomendado) Adicione como **membros** as pessoas que devem ver as respostas dos clientes.

### Passo 2 — Registrar o aplicativo no Entra ID

O "aplicativo" (Service Principal) é a **identidade da ponte** dentro da Microsoft, como se fosse um crachá.

1. Acesse **https://entra.microsoft.com** → **Identidade → Aplicativos → Registros de aplicativo → + Novo registro**.
2. **Nome:** `SMTP2Graph - Envio de Notas Fiscais`. **Tipos de conta:** *Somente este diretório organizacional*. **URI de redirecionamento:** em branco.
3. Clique em **Registrar**. Na **Visão geral**, anote:
   - **ID do aplicativo (cliente)** → o *Client ID*
   - **ID do diretório (locatário)** → o *Tenant ID*
4. Vá em **Identidade → Aplicativos → Aplicativos empresariais**, abra o app e anote o **ID do objeto**.

> ⚠️ O "ID do objeto" de *Registros de aplicativo* é **diferente** do de *Aplicativos empresariais*. Use o de **Aplicativos empresariais**.

### Passo 3 — Criar o segredo do aplicativo

1. Em **Registros de aplicativo** → seu app → **Certificados e segredos → + Novo segredo do cliente**.
2. Descrição: `smtp2graph-producao`. Validade: até 24 meses.
3. **Copie IMEDIATAMENTE a coluna "Valor"**, porque ela só aparece agora. Não confunda com o "ID do segredo".

> 🔐 Esse valor vai para o **Vault** no Passo 8. Depois disso, **apague a anotação** do bloco de notas.
>
> 📅 Coloque um lembrete na agenda **30 dias antes do vencimento**.

**Permissões de API: NÃO adicione nada.** Não conceda `Mail.Send` em *Permissões de API*, porque isso deixaria o app enviar e-mail **como qualquer pessoa da empresa**. A permissão vai ser dada no próximo passo, **limitada à caixa de notas**.

### Passo 4 — Dar permissão de envio SÓ para a caixa de notas

O aplicativo precisa de permissão para **enviar e-mail**, mas só **como a caixa de notas**. Há dois jeitos de fazer isso. **Escolha UM.**

| | Opção A — RBAC para Aplicativos | Opção B — Comandos do Microsoft Graph |
|---|---|---|
| Onde a permissão fica | Exchange Online | Entra ID (Microsoft Graph) |
| Alcance padrão | **Só** a caixa de notas | **TODAS** as caixas da empresa |
| Como restringe | Já vem restrito (escopo de gerenciamento) | Application Access Policy (legado) |
| Recomendação da Microsoft | ✅ Recomendada | ⚠️ A Microsoft pede para não criar novas Application Access Policies |

> 🛑 **Não misture as duas.** Se o Mail.Send for concedido no Entra ID (Opção B), ele vale para a empresa toda, e o escopo do Exchange da Opção A **deixa de limitar**. Vai usar a Opção A? Garanta que o Mail.Send **não** esteja concedido no Entra ID, com a verificação no fim deste passo.

> ℹ️ Este passo **não** precisa rodar no servidor do Docker. Pode ser feito de qualquer PC de administrador.

#### Opção A — RBAC para Aplicativos (recomendada)

🪟 **Windows (PowerShell):**

```powershell
cd D:\SMTP2Graph\scripts
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\1-configurar-permissao-exchange.ps1 `
   -AppId    "ID-DO-APLICATIVO" `
   -ObjectId "ID-DO-OBJETO-DE-APLICATIVOS-EMPRESARIAIS" `
   -Caixa    "notas@suaempresa.com.br"
```

🐧 **Linux (bash + PowerShell 7):**

```bash
cd /opt/smtp2graph
bash scripts/1-configurar-permissao-exchange.sh \
   -AppId    "ID-DO-APLICATIVO" \
   -ObjectId "ID-DO-OBJETO-DE-APLICATIVOS-EMPRESARIAIS" \
   -Caixa    "notas@suaempresa.com.br"
```

No Linux, o login é por **código**: abra o link mostrado em qualquer computador e digite o código. Se o `pwsh` não estiver instalado, o script mostra como instalar.

Faça login com a conta de **Administrador do Exchange**. Resultado esperado no final: **InScope = True**.

| Comando que o script roda | Em português |
|---|---|
| `New-ServicePrincipal` | "Exchange, este é o aplicativo SMTP2Graph." |
| `New-ManagementScope` | "Crie um grupo que contém **só** a caixa `notas@...`." |
| `New-ManagementRoleAssignment` | "Dê ao app a permissão de **enviar e-mail**, só dentro desse grupo." |
| `Test-ServicePrincipalAuthorization` | "Confira se ficou certo." |

#### Opção B — Comandos do Microsoft Graph

Aqui a permissão é dada direto no aplicativo, no Entra ID, com comandos do Microsoft Graph. Tecnicamente, isso cria uma **atribuição de função de aplicativo** (*app role assignment*) da permissão `Mail.Send`, do tipo *Aplicativo*, do Service Principal "Microsoft Graph" para o seu app. É o mesmo que clicar em **Permissões de API → Adicionar → Mail.Send → Conceder consentimento do administrador** no portal, só que por comando.

**B.1 — Conceder o Mail.Send**

🪟 **Windows — Microsoft Graph PowerShell:**

```powershell
Install-Module Microsoft.Graph.Applications -Scope CurrentUser
# Login com conta de Administrador Global ou Administrador de Funções Privilegiadas
Connect-MgGraph -Scopes "Application.Read.All","AppRoleAssignment.ReadWrite.All"

# Service Principal do "Microsoft Graph" (o appId é o mesmo em todos os tenants)
$graphSp  = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
# A permissão Mail.Send do tipo Aplicativo
$mailSend = $graphSp.AppRoles | Where-Object { $_.Value -eq "Mail.Send" -and $_.AllowedMemberTypes -contains "Application" }
# O Service Principal do SEU app
$appSp    = Get-MgServicePrincipal -Filter "appId eq 'ID-DO-APLICATIVO'"

New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $appSp.Id `
    -PrincipalId $appSp.Id -ResourceId $graphSp.Id -AppRoleId $mailSend.Id
```

🐧 **Linux — Azure CLI chamando a API do Graph:**

```bash
az login --use-device-code --allow-no-subscriptions

GRAPH_SP=$(az ad sp show --id 00000003-0000-0000-c000-000000000000 --query id -o tsv)
MAIL_SEND=$(az ad sp show --id 00000003-0000-0000-c000-000000000000 \
  --query "appRoles[?value=='Mail.Send' && contains(allowedMemberTypes,'Application')].id | [0]" -o tsv)
APP_SP=$(az ad sp show --id ID-DO-APLICATIVO --query id -o tsv)

az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$APP_SP/appRoleAssignments" \
  --headers "Content-Type=application/json" \
  --body "{\"principalId\":\"$APP_SP\",\"resourceId\":\"$GRAPH_SP\",\"appRoleId\":\"$MAIL_SEND\"}"
```

> ⚠️ Depois do B.1, o app consegue enviar como **qualquer pessoa da empresa**. Faça o B.2 em seguida.

**B.2 — Restringir à caixa de notas (Application Access Policy)**

Estes comandos (`New-DistributionGroup`, `New-ApplicationAccessPolicy`, `Test-ApplicationAccessPolicy`) **não** são do Microsoft Graph. Eles são do **PowerShell do Exchange Online**. O login do `Connect-MgGraph` feito no B.1 **não** serve para eles: é preciso um **login separado no Exchange Online**.

| O quê | Detalhe |
|---|---|
| Módulo | `ExchangeOnlineManagement` (instala uma vez) |
| Comando de login | `Connect-ExchangeOnline` |
| Conta | Um usuário do Microsoft 365 com a função **Administrador do Exchange** (ou Administrador Global) |
| Windows | Roda no PowerShell 5.1 ou 7. Abre uma janela de login da Microsoft |
| Linux | Roda no `pwsh` com `-Device`: abra o link em qualquer computador e digite o código |

```powershell
# 1) Instalar o módulo (só na primeira vez)
Install-Module ExchangeOnlineManagement -Scope CurrentUser

# 2) Fazer login no Exchange Online com a conta de Administrador do Exchange
Connect-ExchangeOnline -UserPrincipalName admin@suaempresa.com.br
#    Linux (pwsh): Connect-ExchangeOnline -UserPrincipalName admin@suaempresa.com.br -Device

# Grupo de segurança habilitado para e-mail, só com a caixa de notas
New-DistributionGroup -Name "SMTP2Graph - Remetentes" -Alias smtp2graph-remetentes `
    -Type Security -Members notas@suaempresa.com.br

# O app só alcança os membros desse grupo
New-ApplicationAccessPolicy -AppId ID-DO-APLICATIVO `
    -PolicyScopeGroupId smtp2graph-remetentes@suaempresa.com.br `
    -AccessRight RestrictAccess -Description "SMTP2Graph: somente a caixa de notas"

# Teste: Granted para a caixa de notas, Denied para qualquer outra
Test-ApplicationAccessPolicy -Identity notas@suaempresa.com.br -AppId ID-DO-APLICATIVO
Test-ApplicationAccessPolicy -Identity seu.nome@suaempresa.com.br -AppId ID-DO-APLICATIVO
```

**Scripts prontos da Opção B** (fazem o B.1 e o B.2, pedindo confirmação):

```powershell
# Windows
.\1b-permissao-via-graph.ps1 -AppId "ID-DO-APLICATIVO" -Acao Conceder -Caixa "notas@suaempresa.com.br"
```

```bash
# Linux
bash scripts/1b-permissao-via-graph.sh conceder   ID-DO-APLICATIVO
bash scripts/1b-permissao-via-graph.sh restringir ID-DO-APLICATIVO notas@suaempresa.com.br
```

#### Verificar com o Microsoft Graph (recomendado nas duas opções)

Mostra se o app tem Mail.Send concedido no Entra ID:

```powershell
.\1b-permissao-via-graph.ps1 -AppId "ID-DO-APLICATIVO" -Acao Verificar      # Windows
```

```bash
bash scripts/1b-permissao-via-graph.sh verificar ID-DO-APLICATIVO            # Linux
```

| Sua escolha | Resultado esperado |
|---|---|
| Opção A (RBAC) | `Mail.Send (Entra): não concedido`. Se aparecer **CONCEDIDO**, remova com `-Acao Remover` / `remover` |
| Opção B (Graph) | `Mail.Send (Entra): CONCEDIDO` **e** `Test-ApplicationAccessPolicy` = `Granted` só para a caixa de notas |

> ⏳ Nas duas opções, a permissão pode levar de **30 minutos a 2 horas** para começar a valer.

> 🔄 **Depois de mudar qualquer permissão deste passo, reinicie a ponte:** `docker compose restart smtp2graph`. A ponte reaproveita o token de acesso da Microsoft por até cerca de 1 hora, então uma permissão dada depois do último login dela só vale depois de reiniciar. Se o erro continuar, espere a propagação e reinicie de novo.

> ⚠️ **A Opção B precisa do B.1 E do B.2.** O B.2 (Application Access Policy) só *restringe*; não dá permissão nenhuma. O `Test-ApplicationAccessPolicy` diz `Granted` mesmo quando o Mail.Send nunca foi concedido, então confirme sempre com `-Acao Verificar`. E o `Test-ServicePrincipalAuthorization` só vale para a Opção A: na Opção B ele diz "couldn't be found", e isso é normal.

### Passo 5 — Ajustar o DNS (para não cair no spam)

**SPF**: registro TXT do domínio (só pode existir um):

```
v=spf1 include:spf.protection.outlook.com -all
```

**DKIM**: em **https://security.microsoft.com** → **Email e colaboração → Políticas e regras → Políticas de ameaças → Configurações de autenticação de email → DKIM**. Crie no DNS os dois CNAME que a tela mostrar (`selector1._domainkey` e `selector2._domainkey`) e depois ative a assinatura.

**DMARC**: registro TXT com nome `_dmarc`:

```
v=DMARC1; p=none; rua=mailto:dmarc@suaempresa.com.br
```

Depois de algumas semanas sem problemas, mude para `p=quarantine`.

## Parte B — HashiCorp Vault e a ponte

### Passo 6 — Preencher o arquivo .env (sem segredos!)

🪟 **Windows:**

```powershell
cd D:\SMTP2Graph
Copy-Item .env.example .env
notepad .env
```

🐧 **Linux:**

```bash
cd /opt/smtp2graph
cp .env.example .env
chmod 600 .env
nano .env
```

| Variável | O que colocar | Exemplo |
|---|---|---|
| `ALLOWED_SENDERS` | A caixa de notas (várias: separe por vírgula) | `notas@suaempresa.com.br` |
| `SMTP_USERNAME` | Um usuário **que você inventa** para a aplicação | `app-notas` |
| `SMTP_PASSWORD` | Uma senha **que você inventa** (12+ caracteres) | `Gere-Uma-Senha-Sua-2026` |
| `VAULT_ADDR` | Endereço do Vault (não mude) | `http://vault:8200` |
| `VAULT_REFRESH_SECONDS` | De quanto em quanto tempo a ponte relê o Vault | `300` (5 min) |
| `ALLOWED_NETWORKS` | Faixas de IP permitidas | deixe como está |
| `LOG_LEVEL` | `INFO` normal, `DEBUG` para investigar | `INFO` |

> 🔐 O **Tenant ID, o Client ID e o segredo NÃO vão no `.env`**: eles vão para o Vault no Passo 8.
>
> 🔐 O `SMTP_USERNAME` e o `SMTP_PASSWORD` **não são do Microsoft 365**. São uma "senha de portaria" entre a aplicação e a ponte.

### Passo 7 — Ligar os containers

```powershell
cd D:\SMTP2Graph            # Linux: cd /opt/smtp2graph
docker compose up -d --build
docker compose ps
```

No Linux, se aparecer `permission denied ... docker.sock`, coloque `sudo` antes dos comandos `docker` (ou adicione seu usuário ao grupo `docker`).

Nesse momento é **normal** ver:

- `smtp2graph-vault` como **unhealthy**: o Vault ainda não foi inicializado. Ele fica *healthy* depois do Passo 8.
- A ponte esperando o Vault. Veja com `docker compose logs smtp2graph`:

```
INFO    Credenciais do Service Principal: HashiCorp Vault (http://vault:8200)
WARNING Aguardando o Vault: o Vault está SELADO (sealed)... Nova tentativa em 15s.
```

### Passo 8 — Configurar o Vault e guardar o Service Principal

Este é o passo principal. O script faz tudo e **pede os dados do Service Principal**.

🪟 **Windows:**

```powershell
cd D:\SMTP2Graph\scripts
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\2-configurar-vault.ps1
```

🐧 **Linux:**

```bash
cd /opt/smtp2graph
sudo bash scripts/2-configurar-vault.sh
```

As duas versões fazem as mesmas perguntas e têm o mesmo menu. A versão Linux usa o Vault CLI **de dentro** do container, então o servidor só precisa de Docker e curl. Ela também ajusta o dono dos arquivos de `vault/approle` para a ponte conseguir ler.

**O que vai acontecer, na ordem:**

1. **Inicialização do Vault.** O script mostra **dois valores que aparecem UMA ÚNICA VEZ**:

   | Valor | Para que serve |
   |---|---|
   | **Unseal key** (chave de desbloqueio) | Destranca o Vault depois de cada reinício. **Sem ela, os dados do Vault nunca mais podem ser recuperados** |
   | **Root token** | A "senha de administrador" do Vault. Você vai usar para atualizar o segredo no futuro |

   👉 **Guarde os dois no seu cofre de senhas** e digite `OK`. A tela é limpa em seguida.

2. **Configuração automática:** o script cria o cofre `secret/`, a política somente leitura `smtp2graph-read` e o AppRole da ponte, e salva `role_id` e `secret_id` em `vault\approle\`.

3. **Auto-unseal:** o script pergunta se você quer que o Vault **destranque sozinho** depois de reiniciar.
   - **Sim (recomendado para servidor sem operador):** a chave é salva em `vault\unseal\unseal.key` (no Linux, com `chmod 600`).
   - **Não (mais seguro):** depois de cada reinício, você roda o script e escolhe a **opção 2** para desbloquear.

4. **Dados do Service Principal:** o script pede:

   | Pergunta | O que digitar |
   |---|---|
   | `Tenant ID` | ID do diretório (Passo 2) |
   | `Client ID` | ID do aplicativo (Passo 2) |
   | `Client Secret VALUE` | **Valor** do segredo (Passo 3). A digitação fica **oculta** |

   Antes de gravar, o script **testa o login na Microsoft**. Se aparecer **[OK] Login realizado com sucesso**, as credenciais são guardadas no Vault em `secret/smtp2graph/entra`.

> ⚖️ **Sobre o auto-unseal:** ele é prático, mas quem conseguir ler a pasta `vault\unseal\` **e** o volume do Docker consegue abrir o cofre. Proteja a pasta `D:\SMTP2Graph` (Propriedades → Segurança: só Administradores). No Linux: `sudo chown -R root:root /opt/smtp2graph/vault/unseal && sudo chmod 700 /opt/smtp2graph/vault/unseal`. Para segurança máxima, deixe desligado e desbloqueie manualmente. Uma alternativa avançada é o auto-unseal pelo Azure Key Vault (`seal "azurekeyvault"` no `vault.hcl`).

### Passo 9 — Conferir se a ponte ligou

```powershell
docker compose ps
docker compose logs --tail 20 smtp2graph
```

Os três containers devem estar **Up**, com o `smtp2graph-vault` e o `smtp2graph` **healthy**. O que você **quer ver** no log:

```
INFO    Credenciais do Service Principal: HashiCorp Vault (http://vault:8200)
INFO    Login na Microsoft (OAuth) OK para o app e5f6a7b8-...
INFO    Ouvindo SMTP em 0.0.0.0:2525
INFO    Autenticação SMTP: LIGADA | TLS (STARTTLS): desligado
```

E a porta 25 respondendo:

```powershell
Test-NetConnection -ComputerName localhost -Port 25      # Windows → TcpTestSucceeded : True
```

```bash
nc -zv 127.0.0.1 25                                       # Linux   → succeeded / open
```

### Passo 10 — Firewall (só se a aplicação estiver em OUTRA máquina)

🪟 **Windows** — abra o PowerShell **como Administrador**:

```powershell
cd D:\SMTP2Graph\scripts
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\3-liberar-firewall-windows.ps1 -RedeOrigem "192.168.0.0/24"
```

🐧 **Linux:**

```bash
cd /opt/smtp2graph
sudo bash scripts/3-liberar-firewall-linux.sh 192.168.0.0/24,172.16.0.0/12 --persistir
```

- `192.168.0.0/24` = a sua rede (ou só o IP da aplicação). Separe várias por vírgula.
- `172.16.0.0/12` = as redes internas do Docker. Inclua se for usar o app de teste, ou uma aplicação em Docker no mesmo servidor.
- `--persistir` = reaplica a regra depois de reiniciar (cria o serviço `smtp2graph-firewall` no systemd).
- Para desfazer: `sudo bash scripts/3-liberar-firewall-linux.sh --remover`

> ⚠️ **Linux: o `ufw` e o `firewalld` NÃO protegem portas publicadas pelo Docker.** O Docker grava as regras de iptables dele antes. Por isso o script usa a cadeia própria do Docker para isso (`DOCKER-USER`).
>
> 🚫 **Nunca** faça "port forward" da porta 25 no roteador. A ponte é só para uso **interno**.
>
> ℹ️ No **Docker Desktop (Windows)**, a ponte "enxerga" todas as conexões como vindas do próprio Docker, então o `ALLOWED_NETWORKS` do `.env` não consegue filtrar pelo IP real. No **Linux**, a ponte vê o IP real, e o `ALLOWED_NETWORKS` funciona como mais uma camada.

## Parte C — Testar com a aplicação de teste

### Passo 11 — Ligar o app de teste e enviar

```powershell
cd D:\SMTP2Graph\app-teste      # Linux: cd /opt/smtp2graph/app-teste
docker compose up -d --build
```

Abra **http://localhost:8080** (num servidor Linux sem navegador, use **http://IP-DO-SERVIDOR:8080** a partir do seu PC) e preencha:

| Campo | Valor |
|---|---|
| Servidor SMTP | `host.docker.internal` (já vem preenchido; significa "este computador") |
| Porta | `25` |
| Usuário / Senha SMTP | o `SMTP_USERNAME` e o `SMTP_PASSWORD` do `.env` |
| Segurança | `Nenhuma (rede interna)` |
| Remetente | `notas@suaempresa.com.br` |
| Destino | **um e-mail seu de fora da empresa** (Gmail, Hotmail...) |

Dois botões extras ajudam antes de enviar:

- **Testar comunicação**: conecta na ponte, faz a segurança e o login e pergunta se o remetente é aceito, **sem enviar e-mail nenhum**. Ele **não** confere a permissão no Microsoft 365 (Passo 4); isso só aparece ao enviar.
- **Salvar configurações**: deixa os campos preenchidos da próxima vez que você abrir a página (fica no volume Docker `smtp2graph-app-teste-dados`). A senha só é salva se você marcar **Salvar também a senha**; nesse caso ela fica gravada em texto dentro do container.

Clique em **Enviar nota fiscal de teste**. **Esperado:** uma faixa verde e o e-mail chegando com `DANFE_000123.pdf` e `NFe_000123.xml`.

No Gmail, vá em **⋮ → Mostrar original** e confira se aparecem **SPF: PASS**, **DKIM: PASS** e **DMARC: PASS**.

**Testes de segurança (recomendado):**

| Teste | Resultado esperado |
|---|---|
| Senha errada | ❌ `535 Authentication credentials invalid` |
| Sem usuário | ❌ `530 Authentication required` |
| Remetente `diretor@suaempresa.com.br` | ❌ `550 ... nao autorizado nesta ponte` |

Desligue o app de teste quando terminar: `docker compose down`, dentro da pasta `app-teste`.

## Parte D — Ligar a aplicação de produção

### Passo 12 — Configurar a aplicação real

| Campo na aplicação | Valor |
|---|---|
| **Servidor SMTP / Host** | IP desta máquina (ex.: `192.168.0.50`), ou `localhost` se a aplicação roda aqui |
| **Porta** | `25` |
| **Usuário / Senha** | `SMTP_USERNAME` / `SMTP_PASSWORD` do `.env` |
| **SSL/TLS** | Nenhum (STARTTLS só se configurou `certs\`) |
| **Remetente (From)** | `notas@suaempresa.com.br`, **exatamente** a caixa liberada |
| **Responder para (Reply-To)** | opcional, ex.: `financeiro@suaempresa.com.br` |

Antes de liberar para os clientes, envie **uma nota real para você mesmo**.

### ✅ Checklist de produção

- [ ] Caixa `notas@...` criada
- [ ] App registrado **sem** `Mail.Send` em Permissões de API
- [ ] **InScope = True** para a caixa de notas e **False** para outras caixas
- [ ] SPF, DKIM e DMARC com **PASS**
- [ ] **Unseal key e root token guardados no cofre de senhas**
- [ ] Decidido: auto-unseal **ligado** (pasta protegida) ou **desligado** (desbloqueio manual)
- [ ] Segredo do Service Principal **apagado do bloco de notas** (agora ele só existe no Vault)
- [ ] `.env` com `SMTP_USERNAME` e `SMTP_PASSWORD` fortes
- [ ] `docker compose ps`: `smtp2graph-vault` e `smtp2graph` **healthy**
- [ ] Firewall liberado só para a rede interna, sem port forward
- [ ] Permissões NTFS de `D:\SMTP2Graph` restritas a Administradores
- [ ] Backup do volume do Vault feito (veja Manutenção)
- [ ] Lembrete para **renovar o segredo** antes de vencer
- [ ] Máquina sempre ligada, com o Docker iniciando sozinho

## Manutenção do dia a dia

| Tarefa | Comando (em `D:\SMTP2Graph`) |
|---|---|
| Ver status | `docker compose ps` |
| Últimos envios | `docker compose logs --tail 50 smtp2graph` |
| Acompanhar ao vivo | `docker compose logs -f smtp2graph` |
| Procurar um e-mail (Windows) | `docker compose logs smtp2graph \| Select-String "cliente@empresa.com"` |
| Procurar um e-mail (Linux) | `docker compose logs smtp2graph \| grep "cliente@empresa.com"` |
| Reiniciar a ponte | `docker compose restart smtp2graph` |
| Aplicar mudança no `.env` | `docker compose up -d` |
| Desligar tudo | `docker compose down` |

> 🛑 **NUNCA rode `docker compose down -v`.** O `-v` **apaga o volume do Vault**, com todos os segredos dentro.

### 🔑 Trocar o segredo do Service Principal (antes de vencer)

1. Entra ID → seu app → **Certificados e segredos → + Novo segredo do cliente** → copie o **Valor**.
2. Rode `.\2-configurar-vault.ps1` (Linux: `sudo bash scripts/2-configurar-vault.sh`) → **opção 1** → informe o **root token** e os dados novos.
3. A ponte pega o segredo novo **sozinha em até 5 minutos**. Para ser imediato: `docker compose restart smtp2graph`.
4. Confira no log `Login na Microsoft (OAuth) OK` e só então apague o segredo antigo no Entra ID.

### 🔓 Desbloquear o Vault depois de reiniciar (se o auto-unseal estiver desligado)

`.\2-configurar-vault.ps1` (Linux: `sudo bash scripts/2-configurar-vault.sh`) → **opção 2** → cole a **unseal key**. A ponte volta a funcionar sozinha em até 15 segundos.

### 🔁 Trocar o login da ponte no Vault (AppRole)

`.\2-configurar-vault.ps1` (Linux: `sudo bash scripts/2-configurar-vault.sh`) → **opção 3**. O `secret_id` antigo é destruído. Depois rode `docker compose restart smtp2graph`.

### 🖥️ Interface web do Vault

Abra **http://127.0.0.1:8210/ui** (num servidor Linux, crie antes um túnel SSH: `ssh -L 8210:127.0.0.1:8210 usuario@servidor`), escolha **Token** e entre com o root token. O segredo fica em **secret → smtp2graph → entra**. A interface só abre a partir desta máquina.

### 💾 Backup do Vault

🪟 **Windows:**

```powershell
cd D:\SMTP2Graph
docker compose stop vault
docker run --rm -v smtp2graph-vault-data:/data -v ${PWD}\backup:/backup alpine tar czf /backup/vault-data.tgz -C /data .
docker compose start vault
```

🐧 **Linux:**

```bash
cd /opt/smtp2graph
docker compose stop vault
docker run --rm -v smtp2graph-vault-data:/data -v "$PWD/backup:/backup" alpine tar czf /backup/vault-data.tgz -C /data .
docker compose start vault
```

Se o auto-unseal estiver desligado, desbloqueie o Vault depois disso (opção 2). Guarde o backup em local seguro. Lembre que **o backup sozinho não abre nada**: é preciso ter também a unseal key.

## Limites importantes

| Limite | Valor | Se passar |
|---|---|---|
| Destinatários por dia (por caixa) | **10.000** | O Exchange bloqueia a caixa por 24h |
| Mensagens por minuto (por caixa) | **30** | A ponte segura e espera sozinha |
| Tamanho do e-mail com anexos | **~2,9 MB** | Erro `552` (uma NF costuma ter menos de 300 KB) |
| Destinatários por e-mail | **100** (configurável) | Erro `452` |

## Solução de problemas

Primeiro passo, **sempre**: `docker compose logs --tail 50 smtp2graph`.

| Erro | Causa | Solução |
|---|---|---|
| `Aguardando o Vault: o Vault está SELADO` | O Vault reiniciou e está trancado | Script → opção 2, ou ative o auto-unseal |
| `Aguardando o Vault: arquivos do AppRole ... não encontrados` | O Vault ainda não foi configurado | Rode `.\2-configurar-vault.ps1` (Passo 8) |
| `Aguardando o Vault: segredo ... não encontrado` | O Service Principal não foi gravado | Script → opção 1 |
| `o Vault recusou o login do AppRole` | `role_id`/`secret_id` inválidos | Script → opção 3 e `docker compose restart smtp2graph` |
| `não consegui conectar no Vault` | O container do Vault está parado | `docker compose up -d` |
| Script: `Cannot reach Vault` | O Vault está desligado | `docker compose up -d` e `docker compose ps` |
| A primeira execução do `2-configurar-vault.ps1` mostra o **menu** ou pede uma unseal key que você nunca recebeu | O script está falando com **outro Vault** na mesma porta (ex.: de outro projeto). O `smtp2graph-vault` aparece só com `8200/tcp` no `docker ps`, sem `127.0.0.1:8210->` | `docker ps` para ver quem usa a porta. Não digite a chave do outro Vault. Troque o lado esquerdo de `"127.0.0.1:8210:8200"` no `docker-compose.yml` por uma porta livre, `docker compose up -d`, e rode o script com `-VaultAddr http://127.0.0.1:<porta>` |
| Script: `Bind for 127.0.0.1:8210 failed: port is already allocated` | Outro programa usa a porta 8210 | Igual ao item acima: escolha uma porta livre no `docker-compose.yml` e use `-VaultAddr` |
| `smtp2graph-vault` **unhealthy** | Vault não inicializado ou selado | Passo 8, ou opção 2 do script |
| `manifest for hashicorp/vault:2.2 not found` | Tag da imagem indisponível | No `docker-compose.yml`, troque as duas linhas para `hashicorp/vault:latest` |
| Perdi a unseal key | Não há como recuperar | `docker compose down`, `docker volume rm smtp2graph-vault-data`, `docker compose up -d` e refaça o Passo 8 |
| `AADSTS7000215: Invalid client secret` | Gravou o ID do segredo em vez do Valor | Script → opção 1, com o **Valor** |
| `AADSTS7000222: ... expired` | Segredo vencido | Veja "Trocar o segredo" acima |
| `AADSTS700016` / `AADSTS90002` | Client ID ou Tenant ID errado | Script → opção 1 |
| `ErrorAccessDenied` | Permissão do Passo 4 faltando ou ainda não vale | Opção A: confira **InScope = True**. Opção B: confira `-Acao Verificar` = CONCEDIDO (B.1) e a política (B.2). Espere até 2 horas e rode `docker compose restart smtp2graph` |
| `ErrorAccessDenied: Access to OData is disabled: [RAOP] : Blocked by tenant configured AppOnly AccessPolicy settings` | Opção B: a Application Access Policy está bloqueando. Ou o Mail.Send (B.1) não foi concedido, ou a caixa não está no grupo, ou a política ainda está propagando | Rode `.\1b-permissao-via-graph.ps1 -AppId ... -Acao Verificar`, `Get-ApplicationAccessPolicy` e `Get-DistributionGroupMember smtp2graph-remetentes`. Se estiver tudo certo, espere até 2 horas e rode `docker compose restart smtp2graph` |
| Permissão corrigida, mas a ponte continua com o mesmo erro | A ponte reaproveita o token de acesso da Microsoft por até ~1 hora. Um token emitido antes da mudança não tem a permissão nova | `docker compose restart smtp2graph` (força um login novo) |
| `Test-ServicePrincipalAuthorization`: `couldn't be found` | Normal se você usou a **Opção B**: esse comando só confere a Opção A (RBAC) | Na Opção B use `Test-ApplicationAccessPolicy` e `-Acao Verificar`. Não misture as duas opções |
| `Test-ApplicationAccessPolicy` = `Granted`, mas o envio continua falhando | Esse teste só confere a restrição (B.2). Ele também diz Granted quando o Mail.Send (B.1) nunca foi concedido ou quando não existe política | Rode `-Acao Verificar`: deve mostrar `Mail.Send (Entra): CONCEDIDO` |
| `ErrorSendAsDenied` | O From é diferente da caixa liberada | Remetente = `notas@...` |
| `535` / `530` | Usuário/senha **da ponte** errados ou ausentes | Confira na aplicação os valores do `.env` |
| `550 Remetente ... nao autorizado` | Remetente fora do `ALLOWED_SENDERS` | Corrija o remetente ou o `.env` |
| `port is already allocated` (porta 25) | Outro programa usa a porta 25 | No compose, troque para `"2525:2525"` e use a porta 2525 |
| `execução de scripts foi desabilitada` | Política do PowerShell | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` |
| 🐧 `permission denied ... docker.sock` | O usuário não pode usar o Docker | Use `sudo`, ou `sudo usermod -aG docker $USER` e entre de novo |
| 🐧 `/usr/bin/env: 'bash\r': No such file` | Script salvo com quebra de linha do Windows | `sed -i 's/\r$//' scripts/*.sh` |
| 🐧 Ponte: `arquivos do AppRole ... não encontrados`, mas os arquivos existem | A ponte (uid 10001) não consegue ler | Rode `sudo bash scripts/2-configurar-vault.sh` → opção 3 (ele corrige o dono) |
| 🐧 Aplicação em outra máquina não conecta | Regra do firewall ou security group da nuvem | `sudo iptables -L DOCKER-USER -n`; libere também a porta 25 no firewall da nuvem (só rede interna) |
| Opção B: `Test-ApplicationAccessPolicy` = `Denied` para a caixa de notas | A caixa não está no grupo, ou a política ainda está propagando | `Get-DistributionGroupMember smtp2graph-remetentes`; espere até 1-2 horas |
| `Connect-MgGraph`: privilégios insuficientes | A conta não é administradora | Conceder permissões de aplicativo do Microsoft Graph exige Administrador Global ou Administrador de Funções Privilegiadas |
| E-mail cai no **spam** | DNS incompleto | Passo 5 |

## Glossário

| Termo | Explicação simples |
|---|---|
| **SMTP** | O protocolo "clássico" de envio de e-mail |
| **Microsoft Graph** | A API (porta de entrada para programas) do Microsoft 365 |
| **OAuth / token** | Login moderno: o programa recebe um "passe" temporário em vez de usar senha |
| **Service Principal** | A identidade de um aplicativo no Entra ID (Tenant ID + Client ID + segredo) |
| **HashiCorp Vault** | Cofre de segredos: guarda senhas e chaves criptografadas e controla quem pode ler |
| **Seal / Unseal** | O Vault "se tranca" (sealed) ao reiniciar; a unseal key "destranca" |
| **Root token** | A senha de administrador do Vault |
| **AppRole** | Login de um programa no Vault (role_id + secret_id) |
| **KV v2** | O tipo de "gaveta" do Vault que guarda segredos com histórico de versões |
| **RBAC para Aplicativos** | Recurso do Exchange que limita quais caixas um aplicativo pode usar |
| **SPF / DKIM / DMARC** | Registros de DNS que provam que o e-mail é legítimo |
| **Docker / container** | Uma "caixinha" com o programa e tudo de que ele precisa para rodar |
