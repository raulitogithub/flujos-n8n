# =============================================================
# deploy-n8n.ps1  -  Despliega Citastest.json en n8n (Hetzner)
# Uso: .\deploy-n8n.ps1
# Requiere: openssh (incluido en Windows 10/11) y curl
# =============================================================

# ---- CONFIGURACION ----------------------------------------
$SERVER_IP    = "91.99.22.64"
$SSH_USER     = "root"
$SSH_PASS     = "RmMipUjHmKFe"
$N8N_URL      = "https://n8napp.frecdigital.com"
$WORKFLOW_ID  = "ZXSTk5D5dA0iZA0w"
$LOCAL_JSON   = "$PSScriptRoot\Citastest.json"

# API Key: genera una en n8n > Settings > API > Create API Key
# Pegala aqui la primera vez que ejecutes el script.
$N8N_API_KEY  = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJjMWQ2MDU5Mi1jZTY3LTRiYjUtYWMyZC1kN2QyYzQ0YjZjYzEiLCJpc3MiOiJuOG4iLCJhdWQiOiJwdWJsaWMtYXBpIiwianRpIjoiMmY2Y2I4MzctNzJlMS00ZTYzLWJkNDMtYWFjMmU1ZGRiOGI0IiwiaWF0IjoxNzc4OTExMjI5LCJleHAiOjE3ODE0OTYwMDB9.jAdQKUqfkE_i77fngh3eDheOhPz-egSNHqBFRwgq_uA"
# -----------------------------------------------------------

# ---- VALIDACIONES -----------------------------------------
if (-not (Test-Path $LOCAL_JSON)) {
    Write-Error "No se encuentra $LOCAL_JSON"; exit 1
}

if ([string]::IsNullOrWhiteSpace($N8N_API_KEY)) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "  PRIMERA EJECUCION: necesitas un API Key" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "1. Abre https://n8napp.frecdigital.com"
    Write-Host "2. Ve a Settings > n8n API > Create an API key"
    Write-Host "3. Copia la clave y pegala en la variable `$N8N_API_KEY de este script"
    Write-Host ""
    exit 0
}

# Ignorar advertencias de certificados SSL (compatible con PS 5.1)
if (-not ([System.Management.Automation.PSTypeName]'ServerCertificateValidationCallback').Type) {
    $certCallback = @"
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public class ServerCertificateValidationCallback
{
    public static void Ignore()
    {
        if(ServicePointManager.ServerCertificateValidationCallback ==null){
            ServicePointManager.ServerCertificateValidationCallback += 
                delegate (
                    Object obj2,
                    X509Certificate certificate,
                    X509Chain chain,
                    SslPolicyErrors errors
                )
                {
                    return true;
                };
        }
    }
}
"@
    Add-Type $certCallback
}
[ServerCertificateValidationCallback]::Ignore()

# ---- SUBIR EL FLUJO VIA API REST --------------------------
Write-Host ""
Write-Host ">>> Leyendo $LOCAL_JSON ..." -ForegroundColor Cyan
$workflowJson = Get-Content $LOCAL_JSON -Raw -Encoding UTF8
$workflowObj = $workflowJson | ConvertFrom-Json
$workflowName = $workflowObj.name

Write-Host ">>> Buscando flujo por nombre: '$workflowName' ..." -ForegroundColor Cyan

$headers = @{
    "X-N8N-API-KEY" = $N8N_API_KEY
    "Content-Type"  = "application/json"
}

# Buscar flujo por nombre en la lista de flujos
try {
    $allWorkflows = Invoke-RestMethod `
        -Uri "$N8N_URL/api/v1/workflows?limit=100" `
        -Method GET `
        -Headers $headers
    
    $existingWorkflow = $allWorkflows.data | Where-Object { $_.name -eq $workflowName } | Select-Object -First 1
    
    if ($existingWorkflow) {
        $exists = $true
        $existingId = if ($existingWorkflow.id -is [array]) { $existingWorkflow.id[0] } else { $existingWorkflow.id }
        $existingId = $existingId.ToString().Trim()
        Write-Host "    Flujo encontrado: '$($existingWorkflow.name)' (ID: $existingId)" -ForegroundColor Green
    } else {
        $exists = $false
        Write-Host "    Flujo NO encontrado -- se creara como nuevo." -ForegroundColor Yellow
    }
} catch {
    Write-Error "Error al buscar flujos: $_"
    exit 1
}

if ($exists) {
    # ---- ACTUALIZAR flujo existente -----------------------
    Write-Host ">>> Actualizando flujo '$workflowName' ..." -ForegroundColor Cyan
    try {
        # Remover campos read-only para actualización
        $workflowObjClean = $workflowObj | Select-Object -Property * -ExcludeProperty id, active, versionId, meta, tags
        
        # Limpiar settings (solo propiedades permitidas)
        $workflowObjClean.settings = @{
            executionOrder = "v1"
        }
        
        $workflowJsonClean = $workflowObjClean | ConvertTo-Json -Depth 100
        
        $response = Invoke-RestMethod `
            -Uri "$N8N_URL/api/v1/workflows/$existingId" `
            -Method PUT `
            -Headers $headers `
            -Body $workflowJsonClean
        Write-Host "    Flujo actualizado correctamente." -ForegroundColor Green
        $newId = $existingId
    } catch {
        Write-Error "Error al actualizar: $_"
        exit 1
    }
} else {
    # ---- CREAR flujo nuevo --------------------------------
    Write-Host ">>> Creando flujo nuevo ..." -ForegroundColor Cyan
    try {
        # Remover campos read-only pero mantener settings minimalista
        $workflowObjClean = $workflowObj | Select-Object -Property * -ExcludeProperty id, active, versionId, meta, tags
        
        # Crear settings válido (solo propiedades permitidas)
        $workflowObjClean.settings = @{
            executionOrder = "v1"
        }
        
        $workflowJsonClean = $workflowObjClean | ConvertTo-Json -Depth 100
        
        $response = Invoke-RestMethod `
            -Uri "$N8N_URL/api/v1/workflows" `
            -Method POST `
            -Headers $headers `
            -Body $workflowJsonClean
        Write-Host "    Flujo creado. Nuevo ID: $($response.id)" -ForegroundColor Green
        $newId = $response.id
    } catch {
        Write-Error "Error al crear: $_"
        exit 1
    }
}

# ---- ACTIVAR el flujo -------------------------------------
Write-Host ">>> Activando flujo $newId ..." -ForegroundColor Cyan
try {
    Invoke-RestMethod `
        -Uri "$N8N_URL/api/v1/workflows/$newId/activate" `
        -Method POST `
        -Headers $headers | Out-Null
    Write-Host "    Flujo ACTIVO." -ForegroundColor Green
} catch {
    Write-Warning "No se pudo activar automaticamente. Activalo manualmente en n8n."
}

# ---- RESUMEN ----------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Despliegue completado" -ForegroundColor Cyan
Write-Host "  URL n8n : $N8N_URL" -ForegroundColor Cyan
Write-Host "  Flujo ID: $newId" -ForegroundColor Cyan
Write-Host "  Estado  : ACTIVO" -ForegroundColor Cyan
Write-Host "  Abre el flujo en:" -ForegroundColor Cyan
Write-Host "  $N8N_URL/workflow/$newId" -ForegroundColor White
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
