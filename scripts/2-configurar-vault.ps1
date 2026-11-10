<#
.SYNOPSIS
  EN: Sets up HashiCorp Vault for SMTP2Graph and stores the Service Principal
      credentials (Tenant ID, Client ID, Client Secret) in it.
  PT: Configura o HashiCorp Vault do SMTP2Graph e guarda nele as credenciais
      do Service Principal (Tenant ID, Client ID, Client Secret).

.HOW TO USE / COMO USAR
  1. docker compose up -d --build        (in / em D:\SMTP2Graph)
  2. cd D:\SMTP2Graph\scripts
  3. Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
  4. .\2-configurar-vault.ps1

  EN: First run = initializes Vault (shows the unseal key and root token ONCE),
      creates the read-only policy and the AppRole for the bridge, and asks
      for the Service Principal data. Next runs = menu.
  PT: Primeira execução = inicializa o Vault (mostra a chave de desbloqueio e
      o root token UMA vez), cria a política somente leitura e o AppRole da
      ponte, e pede os dados do Service Principal. Próximas execuções = menu.
#>
param(
    [string]$VaultAddr = "http://127.0.0.1:8210"
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Raiz         = Split-Path -Parent $PSScriptRoot
$PastaAppRole = Join-Path $Raiz "vault\approle"
$PastaUnseal  = Join-Path $Raiz "vault\unseal"
$ApiSegredo   = "secret/data/smtp2graph/entra"   # caminho do segredo na API (KV v2)
$Politica     = "smtp2graph-read"
$Role         = "smtp2graph"
$RegexGuid    = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'

# ------------------------------------------------------------------ helpers

function Titulo([string]$en, [string]$pt) {
    Write-Host ""
    Write-Host "=== $en / $pt ===" -ForegroundColor Cyan
}

function Msg([string]$en, [string]$pt, [string]$cor = "White") {
    Write-Host "  $en" -ForegroundColor $cor
    Write-Host "  $pt" -ForegroundColor DarkGray
}

function Ler-Secreto([string]$prompt) {
    $seguro = Read-Host -Prompt $prompt -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($seguro)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr).Trim() }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Perguntar-SimNao([string]$prompt, [bool]$padrao) {
    $sufixo = if ($padrao) { "[Y/n] (S/n)" } else { "[y/N] (s/N)" }
    $r = (Read-Host -Prompt "$prompt $sufixo").Trim().ToLower()
    if ($r -eq "") { return $padrao }
    return ($r -in @("y", "yes", "s", "sim"))
}

function Texto-Erro($err) {
    $msg = $err.Exception.Message
    if ($err.ErrorDetails -and $err.ErrorDetails.Message) {
        try {
            $j = $err.ErrorDetails.Message | ConvertFrom-Json
            if ($j.errors) { $msg = ($j.errors -join "; ") }
            elseif ($j.error_description) { $msg = ($j.error_description -split "`r?`n")[0] }
        } catch { $msg = $err.ErrorDetails.Message }
    }
    return $msg
}

function Invoke-Vault {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        $Body = $null,
        [string]$Token = ""
    )
    $headers = @{}
    if ($Token) { $headers["X-Vault-Token"] = $Token }
    $p = @{ Method = $Method; Uri = "$VaultAddr/v1/$Path"; Headers = $headers; UseBasicParsing = $true }
    if ($null -ne $Body) {
        $p["Body"] = ($Body | ConvertTo-Json -Depth 10 -Compress)
        $p["ContentType"] = "application/json"
    }
    return Invoke-RestMethod @p
}

function Salvar-Arquivo([string]$pasta, [string]$nome, [string]$conteudo) {
    if (-not (Test-Path $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null }
    [IO.File]::WriteAllText((Join-Path $pasta $nome), $conteudo)
}

function Status-Selo { return Invoke-Vault -Method Get -Path "sys/seal-status" }

function Aguardar-Ativo {
    # Depois do desbloqueio, o Vault leva alguns segundos para ficar pronto.
    for ($i = 0; $i -lt 30; $i++) {
        try { Invoke-Vault -Method Get -Path "sys/health" | Out-Null; return }
        catch { Start-Sleep -Seconds 2 }
    }
    throw "Vault did not become active / O Vault não ficou ativo a tempo"
}

function Desbloquear([string]$chave = "") {
    $s = Status-Selo
    if (-not $s.sealed) { Msg "Vault is already unsealed." "O Vault já está desbloqueado." "Green"; return }
    if (-not $chave) { $chave = Ler-Secreto "Unseal key / Chave de desbloqueio" }
    $r = Invoke-Vault -Method Put -Path "sys/unseal" -Body @{ key = $chave }
    if ($r.sealed) { throw "Unseal failed / Desbloqueio falhou" }
    Aguardar-Ativo
    Msg "Vault unsealed." "Vault desbloqueado." "Green"
}

function Pedir-RootToken {
    while ($true) {
        $t = Ler-Secreto "Root token"
        try {
            Invoke-Vault -Method Get -Path "auth/token/lookup-self" -Token $t | Out-Null
            return $t
        } catch {
            Msg "Invalid token: $(Texto-Erro $_)" "Token inválido. Tente de novo." "Red"
        }
    }
}

# ------------------------------------------------------------------ setup steps

function Configurar-Base([string]$token) {
    Titulo "Configuring Vault" "Configurando o Vault"

    $mounts = Invoke-Vault -Method Get -Path "sys/mounts" -Token $token
    if (-not ($mounts.PSObject.Properties.Name -contains "secret/")) {
        Invoke-Vault -Method Post -Path "sys/mounts/secret" -Token $token `
            -Body @{ type = "kv"; options = @{ version = "2" }; description = "SMTP2Graph secrets" } | Out-Null
    }
    Msg "[OK] KV v2 secrets engine at secret/" "[OK] Cofre de segredos KV v2 em secret/" "Green"

    $hcl = "path `"$ApiSegredo`" {`n  capabilities = [`"read`"]`n}`n"
    Invoke-Vault -Method Put -Path "sys/policies/acl/$Politica" -Token $token -Body @{ policy = $hcl } | Out-Null
    Msg "[OK] Policy '$Politica' (read-only on secret/smtp2graph/entra)" `
        "[OK] Política '$Politica' (somente leitura em secret/smtp2graph/entra)" "Green"

    $auths = Invoke-Vault -Method Get -Path "sys/auth" -Token $token
    if (-not ($auths.PSObject.Properties.Name -contains "approle/")) {
        Invoke-Vault -Method Post -Path "sys/auth/approle" -Token $token -Body @{ type = "approle" } | Out-Null
    }
    Invoke-Vault -Method Post -Path "auth/approle/role/$Role" -Token $token -Body @{
        token_policies     = $Politica
        token_ttl          = "1h"
        token_max_ttl      = "4h"
        secret_id_ttl      = "0"
        secret_id_num_uses = 0
    } | Out-Null
    Msg "[OK] AppRole '$Role' for the bridge" "[OK] AppRole '$Role' para a ponte" "Green"
}

function Novo-AppRole([string]$token) {
    $arquivoSecret = Join-Path $PastaAppRole "secret_id"
    $antigo = ""
    if (Test-Path $arquivoSecret) { $antigo = (Get-Content $arquivoSecret -Raw).Trim() }

    $roleId   = (Invoke-Vault -Method Get  -Path "auth/approle/role/$Role/role-id"   -Token $token).data.role_id
    $secretId = (Invoke-Vault -Method Post -Path "auth/approle/role/$Role/secret-id" -Token $token -Body @{}).data.secret_id
    Salvar-Arquivo $PastaAppRole "role_id"   $roleId
    Salvar-Arquivo $PastaAppRole "secret_id" $secretId

    if ($antigo) {
        try {
            Invoke-Vault -Method Post -Path "auth/approle/role/$Role/secret-id/destroy" -Token $token `
                -Body @{ secret_id = $antigo } | Out-Null
        } catch { }
    }
    Msg "[OK] AppRole credentials saved in vault\approle\ (role_id, secret_id)" `
        "[OK] Credenciais do AppRole salvas em vault\approle\ (role_id, secret_id)" "Green"
}

function Ler-Guid([string]$rotulo) {
    while ($true) {
        $v = (Read-Host -Prompt $rotulo).Trim()
        if ($v -match $RegexGuid) { return $v }
        Msg "Invalid format. Expected: 00000000-0000-0000-0000-000000000000" `
            "Formato inválido. Esperado: 00000000-0000-0000-0000-000000000000" "Red"
    }
}

function Testar-Entra([string]$tenant, [string]$clientId, [string]$secret) {
    $corpo = @{
        client_id     = $clientId
        client_secret = $secret
        scope         = "https://graph.microsoft.com/.default"
        grant_type    = "client_credentials"
    }
    try {
        Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" `
            -Body $corpo -ContentType "application/x-www-form-urlencoded" -UseBasicParsing | Out-Null
        return ""
    } catch {
        return (Texto-Erro $_)
    }
}

function Gravar-ServicePrincipal([string]$token) {
    Titulo "Service Principal (Microsoft Entra ID)" "Service Principal (Microsoft Entra ID)"
    Msg "Find these values in Entra ID > App registrations > your app > Overview." `
        "Veja estes valores em Entra ID > Registros de aplicativo > seu app > Visão geral."
    Write-Host ""

    $tenant   = Ler-Guid "Tenant ID (Directory ID / ID do diretório)"
    $clientId = Ler-Guid "Client ID (Application ID / ID do aplicativo)"
    while ($true) {
        $secret = Ler-Secreto "Client Secret VALUE / VALOR do segredo (hidden / oculto)"
        if (-not $secret) { continue }
        if ($secret -match $RegexGuid) {
            Msg "This looks like the Secret ID, not the secret VALUE. Copy the 'Value' column." `
                "Isso parece o ID do segredo, não o VALOR. Copie a coluna 'Valor'." "Yellow"
            if (-not (Perguntar-SimNao "Use it anyway? / Usar mesmo assim?" $false)) { continue }
        }
        break
    }

    Write-Host ""
    Msg "Testing sign-in to Microsoft Entra ID..." "Testando o login no Microsoft Entra ID..." "Yellow"
    $erro = Testar-Entra $tenant $clientId $secret
    if ($erro) {
        Msg "Sign-in FAILED: $erro" "O login FALHOU (confira Tenant ID, Client ID e o VALOR do segredo)." "Red"
        if (-not (Perguntar-SimNao "Save to Vault anyway? / Gravar no Vault mesmo assim?" $false)) {
            Msg "Nothing was saved." "Nada foi gravado." "Yellow"
            return
        }
    } else {
        Msg "[OK] Sign-in succeeded." "[OK] Login realizado com sucesso." "Green"
    }

    Invoke-Vault -Method Post -Path $ApiSegredo -Token $token -Body @{
        data = @{ tenant_id = $tenant; client_id = $clientId; client_secret = $secret }
    } | Out-Null
    $secret = $null

    Msg "[OK] Credentials stored in Vault at secret/smtp2graph/entra" `
        "[OK] Credenciais guardadas no Vault em secret/smtp2graph/entra" "Green"
    Msg "The bridge picks them up within 5 minutes, or now with: docker compose restart smtp2graph" `
        "A ponte pega em até 5 minutos, ou agora com: docker compose restart smtp2graph"
}

function Primeira-Configuracao {
    Titulo "First-time initialization" "Inicialização (primeira vez)"
    $init = Invoke-Vault -Method Put -Path "sys/init" -Body @{ secret_shares = 1; secret_threshold = 1 }
    $chave = $init.keys_base64[0]
    $root  = $init.root_token

    Write-Host ""
    Write-Host "  ****************************************************************" -ForegroundColor Yellow
    Write-Host "   SAVE THESE TWO VALUES NOW (password manager). SHOWN ONLY ONCE!" -ForegroundColor Yellow
    Write-Host "   GUARDE ESTES DOIS VALORES AGORA (cofre de senhas). SÓ APARECEM UMA VEZ!" -ForegroundColor Yellow
    Write-Host "  ****************************************************************" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   Unseal key / Chave de desbloqueio : $chave"
    Write-Host "   Root token                        : $root"
    Write-Host ""
    Msg "Without the unseal key, the data in Vault can NEVER be recovered." `
        "Sem a chave de desbloqueio, os dados do Vault NUNCA mais podem ser recuperados." "Red"
    do { $ok = (Read-Host -Prompt "Type OK after saving / Digite OK depois de guardar").Trim().ToUpper() } while ($ok -ne "OK")
    Clear-Host

    Desbloquear $chave
    Configurar-Base $root
    Novo-AppRole $root

    Titulo "Automatic unseal" "Desbloqueio automático"
    Msg "Vault locks itself (sealed) every time it restarts. Auto-unseal saves the key in" `
        "O Vault se tranca (sealed) toda vez que reinicia. O auto-unseal salva a chave em"
    Msg "vault\unseal\unseal.key so it unlocks by itself. Recommended for an unattended server." `
        "vault\unseal\unseal.key para ele destrancar sozinho. Recomendado para servidor sem operador."
    if (Perguntar-SimNao "Enable auto-unseal? / Ativar o auto-unseal?" $true) {
        Salvar-Arquivo $PastaUnseal "unseal.key" $chave
        Msg "[OK] Auto-unseal enabled." "[OK] Auto-unseal ativado." "Green"
    } else {
        Msg "After every restart, run this script and choose option 2 (unseal)." `
            "Depois de cada reinício, rode este script e escolha a opção 2 (desbloquear)." "Yellow"
    }
    $chave = $null

    Gravar-ServicePrincipal $root
    $root = $null

    Titulo "Done" "Concluído"
    Msg "Check the bridge: docker compose logs -f smtp2graph" "Confira a ponte: docker compose logs -f smtp2graph" "Green"
    Msg "Expected: 'Login na Microsoft (OAuth) OK'" "Esperado: 'Login na Microsoft (OAuth) OK'" "Green"
}

function Mostrar-Status {
    $s = Status-Selo
    Titulo "Status" "Status"
    Write-Host "  Vault address / Endereço    : $VaultAddr"
    Write-Host "  Initialized / Inicializado  : $($s.initialized)"
    Write-Host "  Sealed / Selado             : $($s.sealed)"
    Write-Host "  AppRole files / Arquivos    : $((Test-Path (Join-Path $PastaAppRole 'role_id')) -and (Test-Path (Join-Path $PastaAppRole 'secret_id')))"
    Write-Host "  Auto-unseal                 : $(Test-Path (Join-Path $PastaUnseal 'unseal.key'))"
}

# ------------------------------------------------------------------ main

Titulo "SMTP2Graph - HashiCorp Vault setup" "SMTP2Graph - configuração do HashiCorp Vault"

try { $selo = Status-Selo }
catch {
    Msg "Cannot reach Vault at $VaultAddr. Start it first: cd D:\SMTP2Graph ; docker compose up -d" `
        "Não consegui falar com o Vault em $VaultAddr. Ligue antes: cd D:\SMTP2Graph ; docker compose up -d" "Red"
    exit 1
}

try {
    if (-not $selo.initialized) {
        Primeira-Configuracao
        exit 0
    }

    while ($true) {
        Write-Host ""
        Write-Host "  1) Store/update Service Principal credentials  | Gravar/atualizar credenciais do Service Principal"
        Write-Host "  2) Unseal Vault                                 | Desbloquear o Vault (unseal)"
        Write-Host "  3) Generate new AppRole for the bridge          | Gerar novo AppRole para a ponte"
        Write-Host "  4) Status                                       | Status"
        Write-Host "  0) Exit                                         | Sair"
        $op = (Read-Host -Prompt "Option / Opção").Trim()
        switch ($op) {
            "1" { if ((Status-Selo).sealed) { Desbloquear }; $t = Pedir-RootToken; Configurar-Base $t; Gravar-ServicePrincipal $t; $t = $null }
            "2" { Desbloquear }
            "3" { if ((Status-Selo).sealed) { Desbloquear }; $t = Pedir-RootToken; Configurar-Base $t; Novo-AppRole $t; $t = $null
                  Msg "Restart the bridge: docker compose restart smtp2graph" "Reinicie a ponte: docker compose restart smtp2graph" "Yellow" }
            "4" { Mostrar-Status }
            "0" { exit 0 }
            default { Msg "Invalid option." "Opção inválida." "Red" }
        }
    }
} catch {
    Msg "ERROR: $(Texto-Erro $_)" "ERRO: veja a mensagem acima." "Red"
    exit 1
}
