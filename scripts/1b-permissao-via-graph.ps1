<#
.SYNOPSIS
  EN: Manages the Mail.Send permission of the Service Principal using the
      Microsoft Graph PowerShell SDK (Option B of Step 4).
  PT: Gerencia a permissão Mail.Send do Service Principal usando os comandos
      do Microsoft Graph PowerShell (Opção B do Passo 4).

.ACTIONS / AÇÕES  (-Acao)
  Verificar  EN: shows whether the app has Mail.Send granted in Entra ID (tenant-wide).
             PT: mostra se o app tem Mail.Send concedido no Entra ID (vale para a empresa toda).
  Conceder   EN: grants Mail.Send (= "Grant admin consent"). Applies to ALL mailboxes!
             PT: concede Mail.Send (= "Conceder consentimento do administrador"). Vale para TODAS as caixas!
  Remover    EN: removes the Mail.Send grant (use this if you chose Option A / RBAC).
             PT: remove a concessão Mail.Send (use se você escolheu a Opção A / RBAC).
  Restringir EN: limits Mail.Send to one mailbox with an Application Access Policy (legacy).
             PT: limita o Mail.Send a uma caixa com uma Application Access Policy (legado).

.EXAMPLES / EXEMPLOS
  .\1b-permissao-via-graph.ps1 -AppId "ID-DO-APLICATIVO" -Acao Verificar
  .\1b-permissao-via-graph.ps1 -AppId "ID-DO-APLICATIVO" -Acao Conceder -Caixa "notas@suaempresa.com.br"
  .\1b-permissao-via-graph.ps1 -AppId "ID-DO-APLICATIVO" -Acao Remover
  Linux (pwsh): adicione / add  -UseDeviceCode
#>
param(
    [Parameter(Mandatory = $true)][string]$AppId,
    [ValidateSet("Verificar", "Conceder", "Remover", "Restringir")][string]$Acao = "Verificar",
    [string]$Caixa = "",
    [string]$Grupo = "smtp2graph-remetentes",
    [switch]$UseDeviceCode
)

$ErrorActionPreference = "Stop"
$GraphAppId = "00000003-0000-0000-c000-000000000000"   # "Microsoft Graph" (igual em todos os tenants)

function Msg([string]$en, [string]$pt, [string]$cor = "White") {
    Write-Host "  $en" -ForegroundColor $cor
    Write-Host "  $pt" -ForegroundColor DarkGray
}

function Restringir-ComAccessPolicy {
    if (-not $Caixa) { $script:Caixa = (Read-Host "Mailbox / Caixa (ex.: notas@suaempresa.com.br)").Trim() }
    Msg "Application Access Policies are LEGACY: Microsoft recommends RBAC for Applications (Option A) for new setups." `
        "As Application Access Policies são LEGADO: a Microsoft recomenda o RBAC para Aplicativos (Opção A) em novas instalações." "Yellow"

    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force
    }
    Import-Module ExchangeOnlineManagement
    if ($UseDeviceCode) { Connect-ExchangeOnline -Device -ShowBanner:$false } else { Connect-ExchangeOnline -ShowBanner:$false }

    # 1) Grupo de segurança habilitado para e-mail, contendo só a caixa de notas
    $g = $null
    try { $g = Get-DistributionGroup -Identity $Grupo -ErrorAction Stop } catch { }
    if (-not $g) {
        $g = New-DistributionGroup -Name "SMTP2Graph - Remetentes" -Alias $Grupo -Type Security -Members $Caixa
        Set-DistributionGroup -Identity $g.Identity -HiddenFromAddressListsEnabled $true
        Msg "[OK] Security group created: $($g.PrimarySmtpAddress)" "[OK] Grupo de segurança criado: $($g.PrimarySmtpAddress)" "Green"
    } else {
        try { Add-DistributionGroupMember -Identity $g.Identity -Member $Caixa -ErrorAction Stop } catch { }
    }

    # 2) Política: o app só alcança os membros do grupo
    $existente = Get-ApplicationAccessPolicy | Where-Object { $_.AppId -eq $AppId }
    if (-not $existente) {
        New-ApplicationAccessPolicy -AppId $AppId -PolicyScopeGroupId $g.PrimarySmtpAddress -AccessRight RestrictAccess `
            -Description "SMTP2Graph: somente a caixa de notas" | Out-Null
    }
    Msg "[OK] Application Access Policy applied." "[OK] Application Access Policy aplicada." "Green"

    Write-Host ""
    Test-ApplicationAccessPolicy -Identity $Caixa -AppId $AppId | Format-List Mailbox, AccessCheckResult
    Msg "Expected: AccessCheckResult = Granted. Test another mailbox: it must be Denied. May take up to 1-2 hours." `
        "Esperado: AccessCheckResult = Granted. Teste outra caixa: tem que dar Denied. Pode levar até 1-2 horas."
    Disconnect-ExchangeOnline -Confirm:$false
}

if ($Acao -eq "Restringir") { Restringir-ComAccessPolicy; exit 0 }

# ------------------------------------------------------------------ Microsoft Graph
Write-Host "`n[1/3] Microsoft Graph PowerShell module / módulo..." -ForegroundColor Cyan
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
    Install-Module Microsoft.Graph.Applications -Scope CurrentUser -Force
}
Import-Module Microsoft.Graph.Applications

Write-Host "[2/3] Connect-MgGraph (Application.Read.All, AppRoleAssignment.ReadWrite.All)..." -ForegroundColor Cyan
$escopos = @("Application.Read.All", "AppRoleAssignment.ReadWrite.All")
if ($UseDeviceCode) { Connect-MgGraph -Scopes $escopos -UseDeviceCode -NoWelcome }
else { Connect-MgGraph -Scopes $escopos -NoWelcome }

Write-Host "[3/3] $Acao..." -ForegroundColor Cyan
# O Service Principal do "Microsoft Graph" e a permissão (app role) Mail.Send do tipo Aplicativo
$graphSp = Get-MgServicePrincipal -Filter "appId eq '$GraphAppId'"
$mailSend = $graphSp.AppRoles | Where-Object { $_.Value -eq "Mail.Send" -and $_.AllowedMemberTypes -contains "Application" }
# O Service Principal do SEU app (o que aparece em "Aplicativos empresariais")
$appSp = Get-MgServicePrincipal -Filter "appId eq '$AppId'"
if (-not $appSp) {
    Msg "Service Principal not found for AppId $AppId (check Enterprise applications)." `
        "Service Principal não encontrado para o AppId $AppId (confira em Aplicativos empresariais)." "Red"
    exit 1
}
$atribuicoes = @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $appSp.Id -All |
    Where-Object { $_.AppRoleId -eq $mailSend.Id -and $_.ResourceId -eq $graphSp.Id })

switch ($Acao) {
    "Verificar" {
        Write-Host ""
        Write-Host "  App                : $($appSp.DisplayName)"
        Write-Host "  AppId              : $AppId"
        Write-Host "  Service Principal  : $($appSp.Id)   (= Object ID / ID do objeto)"
        Write-Host "  Mail.Send (Entra)  : $(if ($atribuicoes.Count -gt 0) { 'GRANTED / CONCEDIDO' } else { 'not granted / não concedido' })"
        Write-Host ""
        if ($atribuicoes.Count -gt 0) {
            Msg "The app can send as ANY mailbox unless an Application Access Policy restricts it." `
                "O app pode enviar como QUALQUER caixa, a menos que uma Application Access Policy restrinja." "Yellow"
            Msg "If you use Option A (RBAC), remove it: -Acao Remover" `
                "Se você usa a Opção A (RBAC), remova: -Acao Remover" "Yellow"
        } else {
            Msg "Good for Option A (RBAC): the permission comes only from the Exchange scope." `
                "Correto para a Opção A (RBAC): a permissão vem só do escopo do Exchange." "Green"
        }
    }
    "Conceder" {
        if ($atribuicoes.Count -gt 0) { Msg "Mail.Send is already granted." "Mail.Send já está concedido." "Green" }
        else {
            Msg "WARNING: Mail.Send granted in Entra ID applies to ALL mailboxes in the company." `
                "ATENÇÃO: Mail.Send concedido no Entra ID vale para TODAS as caixas da empresa." "Yellow"
            $r = (Read-Host "Continue? / Continuar? [y/N] (s/N)").Trim().ToLower()
            if ($r -notin @("y", "yes", "s", "sim")) { Disconnect-MgGraph | Out-Null; exit 0 }
            New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $appSp.Id -PrincipalId $appSp.Id `
                -ResourceId $graphSp.Id -AppRoleId $mailSend.Id | Out-Null
            Msg "[OK] Mail.Send granted (admin consent)." "[OK] Mail.Send concedido (consentimento do administrador)." "Green"
        }
        Disconnect-MgGraph | Out-Null
        $r = (Read-Host "Restrict to one mailbox now with an Application Access Policy? / Restringir a uma caixa agora? [Y/n] (S/n)").Trim().ToLower()
        if ($r -eq "" -or $r -in @("y", "yes", "s", "sim")) { Restringir-ComAccessPolicy }
        else {
            Msg "Without a restriction, the app can send as anyone. Restrict later: -Acao Restringir" `
                "Sem restrição, o app pode enviar como qualquer pessoa. Restrinja depois: -Acao Restringir" "Red"
        }
        exit 0
    }
    "Remover" {
        if ($atribuicoes.Count -eq 0) { Msg "Nothing to remove." "Nada para remover." "Green" }
        foreach ($a in $atribuicoes) {
            Remove-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $appSp.Id -AppRoleAssignmentId $a.Id
            Msg "[OK] Mail.Send grant removed." "[OK] Concessão Mail.Send removida." "Green"
        }
    }
}
Disconnect-MgGraph | Out-Null
