#Requires -Version 7.0
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$query = @"
WITH PermisosDirectos AS (
    SELECT
        dp.principal_id,
        STUFF((
            SELECT ', ' +
                dpm.permission_name +
                CASE dpm.state_desc
                    WHEN 'DENY' THEN ' (DENY)'
                    WHEN 'GRANT_WITH_GRANT_OPTION' THEN ' (WGO)'
                    ELSE ''
                END +
                CASE
                    WHEN dpm.class_desc = 'OBJECT_OR_COLUMN' THEN ' ON ' + ISNULL(OBJECT_SCHEMA_NAME(dpm.major_id) + '.' + OBJECT_NAME(dpm.major_id), 'obj')
                    WHEN dpm.class_desc = 'SCHEMA' THEN ' ON SCHEMA::' + ISNULL(SCHEMA_NAME(dpm.major_id), 'sch')
                    WHEN dpm.class_desc = 'DATABASE' THEN ' ON DATABASE'
                    ELSE ''
                END
            FROM sys.database_permissions dpm
            WHERE dpm.grantee_principal_id = dp.principal_id
            ORDER BY dpm.permission_name
            FOR XML PATH(''), TYPE
        ).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS permisos_directos,
        MAX(CASE
            WHEN dpm.permission_name IN ('CONTROL','ALTER ANY USER','ALTER ANY ROLE','IMPERSONATE','TAKE OWNERSHIP','CREATE DATABASE','DROP DATABASE','ALTER ANY DATABASE','ALTER ANY SCHEMA') THEN 1
            ELSE 0
        END) AS tiene_permisos_criticos_directos
    FROM sys.database_principals dp
    LEFT JOIN sys.database_permissions dpm ON dp.principal_id = dpm.grantee_principal_id
    GROUP BY dp.principal_id
),
RolesUsuario AS (
    SELECT
        drm.member_principal_id,
        STUFF((
            SELECT ', ' + r.name
            FROM sys.database_role_members drm2
            JOIN sys.database_principals r ON drm2.role_principal_id = r.principal_id
            WHERE drm2.member_principal_id = drm.member_principal_id
            ORDER BY
                CASE r.name
                    WHEN 'db_owner' THEN 1
                    WHEN 'db_securityadmin' THEN 2
                    WHEN 'db_accessadmin' THEN 3
                    WHEN 'db_ddladmin' THEN 4
                    WHEN 'loginmanager' THEN 5
                    WHEN 'dbmanager' THEN 6
                    WHEN 'db_backupoperator' THEN 7
                    WHEN 'db_datawriter' THEN 8
                    WHEN 'db_datareader' THEN 9
                    ELSE 10
                END,
                r.name
            FOR XML PATH(''), TYPE
        ).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS roles,
        MAX(CASE
            WHEN r.name IN ('db_owner','db_securityadmin','db_accessadmin','db_ddladmin','loginmanager','dbmanager') THEN 1
            ELSE 0
        END) AS tiene_roles_criticos
    FROM sys.database_role_members drm
    JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id
    GROUP BY drm.member_principal_id
)
SELECT
    ROW_NUMBER() OVER (ORDER BY
        CASE
            WHEN ru.tiene_roles_criticos = 1 OR pd.tiene_permisos_criticos_directos = 1 THEN 1
            WHEN ru.roles LIKE '%db_datawriter%' OR ru.roles LIKE '%db_datareader%' THEN 2
            WHEN dp.type = 'S' THEN 3
            ELSE 4
        END,
        dp.name
    ) AS [#],
    dp.name AS Usuario,
    dp.type_desc + ' [' +
    CASE dp.authentication_type
        WHEN 1 THEN 'SQL-LOGIN'
        WHEN 2 THEN 'SQL-CONTAINED'
        WHEN 3 THEN 'WINDOWS'
        WHEN 4 THEN 'AZURE-AD'
        ELSE 'N/A'
    END + ']' AS TipoUsuario,
    ISNULL(ru.roles, 'Sin roles') AS Roles,
    ISNULL(pd.permisos_directos, 'Sin permisos directos') AS PermisosDirectos,
    FORMAT(dp.create_date, 'yyyy-MM-dd') + ' (' +
    CAST(DATEDIFF(DAY, dp.create_date, GETDATE()) / 365 AS VARCHAR) + ' años ' +
    CAST((DATEDIFF(DAY, dp.create_date, GETDATE()) % 365) / 30 AS VARCHAR) + ' meses ' +
    CAST(DATEDIFF(DAY, dp.create_date, GETDATE()) % 30 AS VARCHAR) + ' días)' AS Antiguedad,
    CASE
        WHEN ru.tiene_roles_criticos = 1 THEN 'ALTO - Roles admin'
        WHEN pd.tiene_permisos_criticos_directos = 1 THEN 'ALTO - Permisos críticos'
        WHEN ru.roles LIKE '%db_datawriter%' OR ru.roles LIKE '%db_datareader%' THEN 'MEDIO - Lectura/escritura'
        WHEN dp.authentication_type = 2 THEN 'MEDIO - SQL contenido'
        WHEN dp.authentication_type = 1 THEN 'MEDIO - SQL login'
        ELSE 'BAJO'
    END AS NivelRiesgo
FROM sys.database_principals dp
LEFT JOIN PermisosDirectos pd ON dp.principal_id = pd.principal_id
LEFT JOIN RolesUsuario ru ON dp.principal_id = ru.member_principal_id
WHERE dp.type IN ('S','U','G','E','X','C','K')
  AND dp.name NOT LIKE '##MS_%'
  AND dp.name NOT IN ('dbo','guest','INFORMATION_SCHEMA','sys','public')
  AND dp.is_fixed_role = 0
  AND dp.principal_id > 4
ORDER BY [#];
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

# Nota de acronimos (una sola vez al inicio)
$markdown += "## NOTA DE ACRONIMOS Y CONVENCIONES`n`n"
$markdown += "> **WGO**: WITH GRANT OPTION - Permiso otorgado con capacidad de delegar  `n"
$markdown += "> **DENY**: Permiso explicitamente denegado (tiene precedencia sobre GRANT)  `n"
$markdown += "> **SQL-LOGIN**: Usuario autenticado mediante login de SQL Server a nivel instancia  `n"
$markdown += "> **SQL-CONTAINED**: Usuario de base de datos contenida con autenticacion SQL  `n"
$markdown += "> **WINDOWS**: Usuario autenticado mediante Windows/Active Directory  `n"
$markdown += "> **AZURE-AD**: Usuario autenticado mediante Azure Active Directory`n`n"

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
        
        # Ordenar bases de datos: master primero, luego las demas alfabeticamente
        $sortedDatabases = $databases | Sort-Object -Property @{Expression = {if ($_.name -eq 'master') {0} else {1}}}, name

        $dbNum = 0
        foreach ($db in $sortedDatabases) {
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

                    $markdown += "| **#** | **Usuario** | **Tipo Usuario** | **Roles** | **Permisos Directos** | **Antigüedad** | **Nivel Riesgo** |`n"
                    $markdown += "|------:|:------------|:-----------------|:----------|:----------------------|:---------------|:-----------------|`n"

                    $result | Where-Object { $_ -match '\|' } | ForEach-Object {
                        $fields = $_ -split '\|' | ForEach-Object { $_.Trim() }
                        if ($fields.Count -ge 7) {
                            # Convertir separadores de coma en <br> para roles y permisos directos
                            $roles = $fields[3] -replace ', ', '<br>'
                            $permisosDirectos = $fields[4] -replace ', ', '<br>'

                            $markdown += "| $($fields[0]) | $($fields[1]) | $($fields[2]) | $roles | $permisosDirectos | $($fields[5]) | $($fields[6]) |`n"
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

# Generar nombre base de archivo segun alcance
if ($processingMode -eq "TODOS") {
    $baseFileName = "inventario-usuarios-todos-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}
else {
    $serverName = $serversToProcess[0].name -replace '[^a-zA-Z0-9_-]', '-'
    $baseFileName = "inventario-usuarios-$serverName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}

# Menu de exportacion
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "OPCIONES DE EXPORTACION" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  [1] Exportar solo Markdown" -ForegroundColor Green
Write-Host "  [2] Exportar Markdown + PDF (Tema Light)" -ForegroundColor Green
Write-Host "  [3] Exportar Markdown + PDF (Tema Dark)" -ForegroundColor Green
Write-Host "  [4] Exportar Markdown + Ambos PDFs (Light y Dark)" -ForegroundColor Green
Write-Host "  [N] No exportar" -ForegroundColor Yellow
Write-Host "========================================`n" -ForegroundColor Cyan
Write-Host "Seleccione opcion: " -NoNewline -ForegroundColor Yellow
$exportOption = Read-Host

$mdPath = ".\$baseFileName.md"
$exportedFiles = @()

switch ($exportOption) {
    {$_ -in '1','2','3','4'} {
        # Exportar markdown
        $markdown | Out-File -FilePath $mdPath -Encoding UTF8
        Write-Host "`n✓ Markdown exportado: $mdPath" -ForegroundColor Green
        $exportedFiles += $mdPath

        # Funciones de exportacion PDF
        function Export-PDF {
            param(
                [string]$MarkdownPath,
                [string]$Theme,
                [string]$MetadataFile,
                [string]$HighlightTheme,
                [string]$Suffix
            )

            $pdfPath = $MarkdownPath -replace '\.md$', "-$Suffix.pdf"
            $startTime = Get-Date

            Write-Host "`nGenerando PDF ($Theme)..." -ForegroundColor Cyan

            $pandocArgs = @(
                $MarkdownPath,
                '-o', $pdfPath,
                '--from=markdown+gfm_auto_identifiers+pipe_tables+grid_tables+multiline_tables+simple_tables+raw_html+raw_tex+strikeout+superscript+subscript+fenced_divs+bracketed_spans+definition_lists+latex_macros+tex_math_dollars+implicit_figures+footnotes+inline_notes+citations+fenced_code_attributes+backtick_code_blocks+line_blocks+fancy_lists+startnum+task_lists+escaped_line_breaks+smart+yaml_metadata_block',
                '--pdf-engine=xelatex',
                "--lua-filter=.pandoc\linebreak-filter.lua",
                "--metadata-file=.pandoc\$MetadataFile",
                '--standalone',
                '--dpi=300',
                '--wrap=auto',
                '--toc-depth=3',
                '--top-level-division=section',
                '--pdf-engine-opt=-no-shell-escape',
                "--highlight-style=.pandoc\$HighlightTheme",
                '--listings',
                '--pdf-engine-opt=-interaction=nonstopmode',
                '--pdf-engine-opt=-file-line-error',
                '--pdf-engine-opt=-synctex=1',
                '--pdf-engine-opt=-output-driver=xdvipdfmx -z 9'
            )

            $pandocOutput = & pandoc $pandocArgs 2>&1

            $endTime = Get-Date
            $duration = ($endTime - $startTime).TotalSeconds

            if ($LASTEXITCODE -eq 0 -and (Test-Path $pdfPath)) {
                Write-Host "✓ PDF $Theme generado en $([math]::Round($duration, 2)) segundos!" -ForegroundColor Magenta
                Write-Host "  Archivo: $pdfPath" -ForegroundColor White
                return $pdfPath
            }
            else {
                Write-Host "✗ Error al generar PDF $Theme" -ForegroundColor Red
                if ($pandocOutput) {
                    Write-Host "Detalles del error:" -ForegroundColor Yellow
                    $pandocOutput | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
                }
                return $null
            }
        }

        # Exportar PDFs segun opcion
        if ($exportOption -eq '2' -or $exportOption -eq '4') {
            $pdfLight = Export-PDF -MarkdownPath $mdPath -Theme "LIGHT" -MetadataFile "metadata-premium-SUPREME.yaml" -HighlightTheme "intellij-idea.theme" -Suffix "LIGHT"
            if ($pdfLight) { $exportedFiles += $pdfLight }
        }

        if ($exportOption -eq '3' -or $exportOption -eq '4') {
            $pdfDark = Export-PDF -MarkdownPath $mdPath -Theme "DARK" -MetadataFile "metadata-gruvbox-dark.yaml" -HighlightTheme "gruvbox-dark-custom.theme" -Suffix "DARK"
            if ($pdfDark) { $exportedFiles += $pdfDark }
        }

        # Resumen final
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "ARCHIVOS EXPORTADOS" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        foreach ($file in $exportedFiles) {
            $fileSize = [math]::Round((Get-Item $file).Length / 1KB, 2)
            Write-Host "  $file ($fileSize KB)" -ForegroundColor Green
        }
        Write-Host "========================================`n" -ForegroundColor Cyan
    }
    default {
        Write-Host "`nExportacion cancelada" -ForegroundColor Yellow
    }
}