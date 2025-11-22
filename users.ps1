#Requires -Version 7.0
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$query = @"
WITH UserRoles AS (
    SELECT 
        drm.member_principal_id,
        STRING_AGG(r.name, ', ') WITHIN GROUP (ORDER BY r.name) AS roles,
        MAX(CASE WHEN r.name IN ('db_owner','db_securityadmin','db_accessadmin') THEN 1 ELSE 0 END) AS tiene_roles_admin
    FROM sys.database_role_members drm
    JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id
    GROUP BY drm.member_principal_id
)
SELECT  
    ROW_NUMBER() OVER (ORDER BY 
        CASE 
            WHEN dp.authentication_type = 1 AND (sp.sid IS NULL OR sp.is_disabled = 1) THEN 0
            WHEN ur.tiene_roles_admin = 1 THEN 1
            WHEN dp.type = 'S' THEN 2
            ELSE 3
        END, dp.name
    ) AS Num,
    dp.name AS Usuario,
    ISNULL(ur.roles, 'Sin roles') AS RolesDB,
    dp.type_desc + ' [' + CASE dp.authentication_type
        WHEN 1 THEN 'INSTANCE'
        WHEN 2 THEN 'DATABASE'
        WHEN 3 THEN 'WINDOWS'
        WHEN 4 THEN 'AZURE AD'
        ELSE 'N/A'
    END + ']' AS TipoUsuario,
    FORMAT(dp.modify_date, 'yyyy-MM-dd') + ' (' + 
    CAST(DATEDIFF(DAY, dp.modify_date, SYSDATETIME()) / 365 AS VARCHAR) + ' anos ' +
    CAST((DATEDIFF(DAY, dp.modify_date, SYSDATETIME()) % 365) / 30 AS VARCHAR) + ' meses y ' +
    CAST(DATEDIFF(DAY, dp.modify_date, SYSDATETIME()) % 30 AS VARCHAR) + ' dias)' AS Antiguedad,
    CASE
        WHEN sp.sid IS NULL AND dp.sid IS NOT NULL AND dp.sid <> 0x00 AND dp.authentication_type = 1 THEN 'Huerfano'
        WHEN sp.is_disabled = 1 THEN 'Deshabilitado'
        WHEN sp.sid IS NOT NULL THEN 'Activo'
        WHEN dp.authentication_type = 2 THEN 'Contenido'
        ELSE 'Sin login'
    END AS Estado,
    CASE
        WHEN dp.authentication_type = 1 AND (sp.sid IS NULL OR sp.is_disabled = 1) THEN 'ALTO - Usuario huerfano sin login asociado'
        WHEN ur.tiene_roles_admin = 1 THEN 'ALTO - Posee roles administrativos (db_owner, db_securityadmin o db_accessadmin)'
        WHEN dp.type = 'S' THEN 'MEDIO - Utiliza autenticacion SQL'
        ELSE 'BAJO - Usuario sin privilegios elevados'
    END AS NivelRiesgo
FROM sys.database_principals dp
LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
LEFT JOIN UserRoles ur ON dp.principal_id = ur.member_principal_id
WHERE dp.type IN ('S','U','G','E','X','C','K')
  AND dp.name NOT IN ('dbo','guest','INFORMATION_SCHEMA','sys','public')
  AND dp.is_fixed_role = 0
  AND dp.principal_id > 4
ORDER BY Num;
"@

# Verificar autenticacion
Write-Host "`nVerificando autenticacion Azure..." -ForegroundColor Cyan
$context = az account show --output json 2>$null | ConvertFrom-Json
if (-not $context) {
    Write-Host "No autenticado. Ejecuta: az login" -ForegroundColor Red
    exit 1
}
Write-Host "Autenticado como: $($context.user.name)`n" -ForegroundColor Green

Write-Host "Obteniendo inventario de servidores SQL..." -ForegroundColor Cyan
$servers = az sql server list --output json | ConvertFrom-Json
Write-Host "Servidores encontrados: $($servers.Count)`n" -ForegroundColor Green

# Menu de seleccion de servidores
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "SERVIDORES DISPONIBLES" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$serverIndex = 1
$serverMap = @{}
foreach ($srv in ($servers | Sort-Object name)) {
    Write-Host ("{0,3}. {1,-40} ({2})" -f $serverIndex, $srv.name, $srv.resourceGroup) -ForegroundColor White
    $serverMap[$serverIndex] = $srv
    $serverIndex++
}

Write-Host "========================================`n" -ForegroundColor Cyan
Write-Host "Opciones:" -ForegroundColor Yellow
Write-Host "  [t] Procesar TODOS los servidores" -ForegroundColor Green
Write-Host "  [#] Seleccionar servidor por numero`n" -ForegroundColor Green
Write-Host "Ingrese su opcion: " -NoNewline -ForegroundColor Yellow
$seleccion = Read-Host

# Filtrar servidores segun seleccion
$serversToProcess = @()
$processingMode = ""

if ($seleccion -eq 't' -or $seleccion -eq 'T') {
    $serversToProcess = $servers
    $processingMode = "TODOS"
    Write-Host "`nProcesando TODOS los servidores...`n" -ForegroundColor Green
}
elseif ($seleccion -match '^\d+$') {
    $selectedNumber = [int]$seleccion
    if ($serverMap.ContainsKey($selectedNumber)) {
        $serversToProcess = @($serverMap[$selectedNumber])
        $processingMode = "SERVIDOR: $($serverMap[$selectedNumber].name)"
        Write-Host "`nProcesando servidor: $($serverMap[$selectedNumber].name)`n" -ForegroundColor Green
    }
    else {
        Write-Host "`nNumero invalido. Abortando." -ForegroundColor Red
        exit 1
    }
}
else {
    Write-Host "`nOpcion invalida. Abortando." -ForegroundColor Red
    exit 1
}

$stats = @{
    ResourceGroups = @{}
    TotalServers = 0
    TotalDatabases = 0
    Exitosas = 0
    ErrorFirewall = 0
    ErrorPermisos = 0
    ErrorAuth = 0
    ErrorOtros = 0
}

$serversByRG = $serversToProcess | Group-Object -Property resourceGroup

Write-Host "Recopilando informacion previa..." -ForegroundColor Cyan
$progressBar = 0
foreach ($srv in $serversToProcess) {
    $progressBar++
    Write-Progress -Activity "Analizando estructura" -Status "$progressBar de $($serversToProcess.Count)" -PercentComplete (($progressBar / $serversToProcess.Count) * 100)

    $stats.TotalServers++
    if (-not $stats.ResourceGroups.ContainsKey($srv.resourceGroup)) {
        $stats.ResourceGroups[$srv.resourceGroup] = $true
    }

    $databases = az sql db list --resource-group $srv.resourceGroup --server $srv.name --output json 2>$null | ConvertFrom-Json
    $stats.TotalDatabases += $databases.Count
}
Write-Progress -Activity "Analizando estructura" -Completed
Write-Host "Analisis completado`n" -ForegroundColor Green

# Inicializar markdown
$markdown = "# INVENTARIO DE USUARIOS - AZURE SQL DATABASE`n`n"
$markdown += "**Fecha:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  `n"
$markdown += "**Usuario:** $($context.user.name)  `n"
$markdown += "**Suscripcion:** $($context.name)  `n"
$markdown += "**Alcance:** $processingMode`n`n"

# Placeholder para resumen
$resumenPlaceholder = "RESUMEN_PLACEHOLDER"
$markdown += $resumenPlaceholder

$markdown += "## INDICE DE GRUPOS DE RECURSOS`n`n"
$markdown += "> Esta tabla permite navegar rapidamente a cada grupo de recursos y sus servidores. Haga clic en los enlaces para ir directamente a cada seccion.`n`n"
$markdown += "| **#** | **Grupo de Recursos** | **Servidores** |`n"
$markdown += "|------:|:----------------------|:---------------|`n"

$indiceRG = ""
$rgNum = 0
foreach ($rg in ($serversByRG | Sort-Object Name)) {
    $rgNum++
    $rgName = $rg.Name
    $anchor = $rgName -replace '[^a-zA-Z0-9_-]', '-'
    
    $serverLinks = @()
    $srvNum = 0
    foreach ($srv in ($rg.Group | Sort-Object name)) {
        $srvNum++
        $srvAnchor = "$rgNum$srvNum-servidor-" + ($srv.name -replace '[^a-zA-Z0-9_-]', '-')
        $serverLinks += "[``$($srv.name)``](#$srvAnchor)"
    }
    
    $indiceRG += "| $rgNum | [``$rgName``](#${rgNum}-grupo-de-recursos-$anchor) | $($serverLinks -join ', ') |`n"
}
$markdown += $indiceRG
$markdown += "`n"

# Procesar cada grupo de recursos
$rgNum = 0
$statsExitosas = 0
$statsErrores = 0
$totalItems = ($serversByRG | ForEach-Object { $_.Group | ForEach-Object { 
    (az sql db list --resource-group $_.resourceGroup --server $_.name --output json 2>$null | ConvertFrom-Json).Count 
} } | Measure-Object -Sum).Sum

$processedItems = 0

Write-Host "Iniciando procesamiento de bases de datos...`n" -ForegroundColor Yellow

foreach ($rg in ($serversByRG | Sort-Object Name)) {
    $rgNum++
    $rgName = $rg.Name
    $anchor = $rgName -replace '[^a-zA-Z0-9_-]', '-'
    
    Write-Host "[$rgNum/$($serversByRG.Count)] $rgName" -ForegroundColor Cyan
    
    $markdown += "## ${rgNum}. Grupo de Recursos: ``$rgName```n`n"
    
    $serverNum = 0
    foreach ($srv in ($rg.Group | Sort-Object name)) {
        $serverNum++
        $srvAnchor = "$rgNum$serverNum-servidor-" + ($srv.name -replace '[^a-zA-Z0-9_-]', '-')
        
        Write-Host "  $rgNum.$serverNum. $($srv.name)" -ForegroundColor White
        
        $markdown += "### $rgNum.$serverNum. Servidor: ``$($srv.fullyQualifiedDomainName)```n`n"
        
        $databases = az sql db list --resource-group $srv.resourceGroup --server $srv.name --output json 2>$null | ConvertFrom-Json
        
        if ($databases.Count -eq 0) {
            $markdown += "_Sin bases de datos en este servidor._`n`n"
            continue
        }
        
        $dbNum = 0
        foreach ($db in ($databases | Sort-Object name)) {
            $dbNum++
            $processedItems++
            $percentComplete = [math]::Round(($processedItems / $totalItems) * 100, 1)
            
            Write-Progress -Activity "Procesando bases de datos" -Status "$processedItems de $totalItems ($percentComplete%)" -PercentComplete $percentComplete
            Write-Host "    $rgNum.$serverNum.$dbNum. $($db.name)" -NoNewline -ForegroundColor DarkGray
            
            $markdown += "#### $rgNum.$serverNum.$dbNum. Base de Datos: ``$($db.name)``"
            
            if ($db.name -eq 'master') {
                $markdown += " _(Nivel Servidor)_"
            }
            
            $markdown += "`n`n"
            
            try {
                $errorFile = [System.IO.Path]::GetTempFileName()
                $result = sqlcmd -S $srv.fullyQualifiedDomainName -d $db.name -G -C -Q $query -h -1 -s "|" -W 2>$errorFile
                
                if ($LASTEXITCODE -eq 0 -and $result) {
                    $statsExitosas++
                    Write-Host " - OK" -ForegroundColor Green
                    
                    $markdown += "| **#** | **Usuario** | **Roles DB** | **Tipo Usuario** | **Antiguedad** | **Estado Login** | **Nivel Riesgo** |`n"
                    $markdown += "|------:|:------------|:-------------|:-----------------|:---------------|:-----------------|:------------------|`n"
                    
                    $result | Where-Object { $_ -match '\|' } | ForEach-Object {
                        $fields = $_ -split '\|' | ForEach-Object { $_.Trim() }
                        if ($fields.Count -ge 7) {
                            $markdown += "| $($fields[0]) | $($fields[1]) | $($fields[2]) | $($fields[3]) | $($fields[4]) | $($fields[5]) | $($fields[6]) |`n"
                        }
                    }
                    $markdown += "`n"
                }
                else {
                    $statsErrores++
                    $errorMsg = Get-Content $errorFile -Raw -ErrorAction SilentlyContinue
                    
                    if ($errorMsg -match "firewall|IP address|sp_set_firewall_rule") {
                        $stats.ErrorFirewall++
                        $errorType = "Firewall bloqueado"
                        
                        if ($errorMsg -match "IP address '([0-9.]+)'") {
                            $ip = $matches[1]
                            $detalle = "Tu direccion IP $ip no esta autorizada en el firewall del servidor."
                            $solucion = "Solicitar al administrador agregar regla de firewall para IP $ip o ejecutar en master: ``sp_set_firewall_rule``"
                        } else {
                            $detalle = "La IP del cliente no esta autorizada."
                            $solucion = "Agregar regla de firewall en Azure Portal o mediante comando az sql server firewall-rule"
                        }
                        
                        Write-Host " - Firewall" -ForegroundColor Red
                    }
                    elseif ($errorMsg -match "permission|denied|not authorized|Error 18456") {
                        $stats.ErrorPermisos++
                        $errorType = "Sin permisos de acceso"
                        $detalle = "El usuario autenticado no tiene permisos para leer esta base de datos."
                        $solucion = "Solicitar al administrador: agregar usuario al rol db_datareader o como administrador Azure AD del servidor"
                        Write-Host " - Sin permisos" -ForegroundColor Red
                    }
                    elseif ($errorMsg -match "login.*failed|authentication|Error 18456|token-identified") {
                        $stats.ErrorAuth++
                        $errorType = "Error de autenticacion"
                        $detalle = "La autenticacion Azure AD fallo o el usuario no esta registrado en el servidor."
                        $solucion = "Verificar que tu cuenta este agregada como usuario en el servidor SQL o como administrador Azure AD"
                        Write-Host " - Auth fallida" -ForegroundColor Red
                    }
                    elseif ($errorMsg -match "Cannot open server") {
                        $stats.ErrorOtros++
                        $errorType = "Servidor inaccesible"
                        $detalle = "No se puede establecer conexion con el servidor."
                        $solucion = "Verificar que el servidor este activo y accesible desde tu ubicacion"
                        Write-Host " - Inaccesible" -ForegroundColor Red
                    }
                    else {
                        $stats.ErrorOtros++
                        $errorType = "Error de conexion"
                        $detalle = "Error no especificado al intentar conectar."
                        $solucion = "Revisar logs del servidor o contactar al administrador"
                        Write-Host " - Error" -ForegroundColor Red
                    }
                    
                    $markdown += "> **Nota:** No se pudo acceder a esta base de datos.  `n"
                    $markdown += "> **Error:** $errorType  `n"
                    $markdown += "> **Detalle:** $detalle  `n"
                    $markdown += "> **Solucion:** $solucion`n`n"
                }
                
                Remove-Item $errorFile -Force -ErrorAction SilentlyContinue
            }
            catch {
                $statsErrores++
                $stats.ErrorOtros++
                Write-Host " - Excepcion" -ForegroundColor Red
                $markdown += "> **Nota:** Excepcion inesperada al intentar conectar.  `n"
                $markdown += "> **Detalle:** $($_.Exception.Message)  `n"
                $markdown += "> **Solucion:** Verificar conectividad de red y permisos`n`n"
            }
        }
        
        $markdown += "`n"
    }
}

Write-Progress -Activity "Procesando bases de datos" -Completed

# Construir resumen ejecutivo
$resumen = "## RESUMEN EJECUTIVO`n`n"
$resumen += "> Este resumen presenta el panorama global del inventario, incluyendo metricas de acceso exitoso y detalle de errores encontrados durante el proceso.`n`n"
$resumen += "| **Metrica** | **Valor** | **Detalle** |`n"
$resumen += "|:------------|----------:|:------------|`n"
$resumen += "| Grupos de recursos | $($stats.ResourceGroups.Count) | Total de grupos analizados |`n"
$resumen += "| Servidores SQL | $($stats.TotalServers) | Servidores en toda la suscripcion |`n"
$resumen += "| Bases de datos totales | $($stats.TotalDatabases) | Incluye master y bases de usuario |`n"
$resumen += "| Accesos exitosos | $statsExitosas | Bases consultadas correctamente |`n"
$resumen += "| Accesos denegados | $statsErrores | Bases con errores de acceso |`n"

if ($statsErrores -gt 0) {
    $resumen += "| **Firewall bloqueado** | $($stats.ErrorFirewall) | IP no autorizada en servidor |`n"
    $resumen += "| **Sin permisos** | $($stats.ErrorPermisos) | Usuario sin rol de lectura |`n"
    $resumen += "| **Autenticacion fallida** | $($stats.ErrorAuth) | Usuario no registrado |`n"
    $resumen += "| **Otros errores** | $($stats.ErrorOtros) | Errores de conectividad u otros |`n"
}

$resumen += "`n"

# Reemplazar placeholder
$markdown = $markdown -replace $resumenPlaceholder, $resumen

# Mostrar resumen en consola
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "RESUMEN EJECUTIVO" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Grupos de recursos:  $($stats.ResourceGroups.Count)" -ForegroundColor White
Write-Host "Servidores:          $($stats.TotalServers)" -ForegroundColor White
Write-Host "Bases de datos:      $($stats.TotalDatabases)" -ForegroundColor White
Write-Host "Exitosas:            $statsExitosas" -ForegroundColor Green
Write-Host "Errores:             $statsErrores" -ForegroundColor $(if($statsErrores -gt 0){'Red'}else{'Green'})

if ($statsErrores -gt 0) {
    Write-Host "`nDetalle de errores:" -ForegroundColor Yellow
    if ($stats.ErrorFirewall -gt 0) { Write-Host "  Firewall:        $($stats.ErrorFirewall)" -ForegroundColor Red }
    if ($stats.ErrorPermisos -gt 0) { Write-Host "  Permisos:        $($stats.ErrorPermisos)" -ForegroundColor Red }
    if ($stats.ErrorAuth -gt 0) { Write-Host "  Autenticacion:   $($stats.ErrorAuth)" -ForegroundColor Red }
    if ($stats.ErrorOtros -gt 0) { Write-Host "  Otros:           $($stats.ErrorOtros)" -ForegroundColor Red }
}
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "Exportar a Markdown? (S/N): " -NoNewline -ForegroundColor Yellow
$export = Read-Host

if ($export -eq 'S' -or $export -eq 's') {
    # Generar nombre de archivo segun alcance
    if ($processingMode -eq "TODOS") {
        $mdPath = ".\inventario-usuarios-todos-$(Get-Date -Format 'yyyyMMdd-HHmmss').md"
    }
    else {
        $serverName = $serversToProcess[0].name -replace '[^a-zA-Z0-9_-]', '-'
        $mdPath = ".\inventario-usuarios-$serverName-$(Get-Date -Format 'yyyyMMdd-HHmmss').md"
    }
    $markdown | Out-File -FilePath $mdPath -Encoding UTF8
    Write-Host "Exportado: $mdPath" -ForegroundColor Green
} else {
    Write-Host "Exportacion cancelada" -ForegroundColor Yellow
}