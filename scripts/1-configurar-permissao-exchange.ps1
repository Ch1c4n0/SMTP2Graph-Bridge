<#
.SYNOPSIS
  Dá ao aplicativo do Entra ID permissão para enviar e-mail SOMENTE pela caixa de notas.
  (Recurso "RBAC para Aplicativos" do Exchange Online)

.COMO USAR
  1. Abra o PowerShell (não precisa ser administrador do Windows).
  2. Vá até esta pasta:   cd D:\SMTP2Graph\scripts
  3. Rode (trocando os valores):
     .\1-configurar-permissao-exchange.ps1 `
        -AppId    "ID do aplicativo (cliente)" `
        -ObjectId "ID do objeto (da tela Aplicativos empresariais)" `
        -Caixa    "notas@suaempresa.com.br"

  No Linux: use ./1-configurar-permissao-exchange.sh (mesmos parâmetros).

  Se aparecer erro de "execução de scripts desabilitada", rode antes:
     Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#>
param(
    [Parameter(Mandatory = $true)][string]$AppId,
    [Parameter(Mandatory = $true)][string]$ObjectId,
    [Parameter(Mandatory = $true)][string]$Caixa,
    [string]$NomeApp = "SMTP2Graph - Envio de Notas Fiscais",
    [string]$NomeEscopo = "SMTP2Graph - Caixa de Notas",
    # Login por código (para Linux / servidores sem navegador)
    [switch]$UseDeviceCode
)

$ErrorActionPreference = "Stop"

Write-Host "`n[1/5] Verificando o módulo do Exchange Online..." -ForegroundColor Cyan
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Host "      Instalando o módulo ExchangeOnlineManagement (só na primeira vez)..."
    Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force
}
Import-Module ExchangeOnlineManagement

Write-Host "[2/5] Conectando ao Exchange Online (vai abrir uma janela de login)..." -ForegroundColor Cyan
if ($UseDeviceCode) {
    Write-Host "      Abra o link mostrado em qualquer computador e digite o código. / Open the link on any computer and type the code."
    Connect-ExchangeOnline -Device -ShowBanner:$false
} else {
    Connect-ExchangeOnline -ShowBanner:$false
}

Write-Host "[3/5] Apresentando o aplicativo ao Exchange..." -ForegroundColor Cyan
$sp = $null
try { $sp = Get-ServicePrincipal -Identity $AppId -ErrorAction Stop } catch { }
if ($sp) {
    Write-Host "      Já existia. Seguindo em frente."
} else {
    New-ServicePrincipal -AppId $AppId -ObjectId $ObjectId -DisplayName $NomeApp | Out-Null
    Write-Host "      Criado."
}

Write-Host "[4/5] Criando o escopo que contém só a caixa $Caixa ..." -ForegroundColor Cyan
$escopo = $null
try { $escopo = Get-ManagementScope -Identity $NomeEscopo -ErrorAction Stop } catch { }
if ($escopo) {
    Write-Host "      Escopo já existia: $($escopo.RecipientFilter)"
} else {
    New-ManagementScope -Name $NomeEscopo -RecipientRestrictionFilter "PrimarySmtpAddress -eq '$Caixa'" | Out-Null
    Write-Host "      Criado."
}

Write-Host "[5/5] Dando a permissão 'Application Mail.Send' limitada ao escopo..." -ForegroundColor Cyan
$atribuicao = $null
try {
    $atribuicao = Get-ManagementRoleAssignment -RoleAssignee $AppId -ErrorAction Stop |
        Where-Object { $_.Role -eq "Application Mail.Send" -and $_.CustomResourceScope -eq $NomeEscopo }
} catch { }
if ($atribuicao) {
    Write-Host "      Permissão já existia."
} else {
    New-ManagementRoleAssignment -App $AppId -Role "Application Mail.Send" -CustomResourceScope $NomeEscopo | Out-Null
    Write-Host "      Permissão criada."
}

Write-Host "`nTestando: o app pode enviar por $Caixa ?" -ForegroundColor Yellow
Test-ServicePrincipalAuthorization -Identity $AppId -Resource $Caixa | Format-Table RoleName, GrantedPermissions, InScope -AutoSize

Write-Host "Resultado esperado: InScope = True." -ForegroundColor Green
Write-Host "A permissão pode levar de 30 minutos a 2 horas para começar a valer no envio." -ForegroundColor Green
Write-Host "Dica: teste com outra caixa (ex.: a sua). Deve aparecer InScope = False.`n"

Disconnect-ExchangeOnline -Confirm:$false
