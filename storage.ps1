function Get-AzureSQLBackupInventory {
    [CmdletBinding()]
    param()
    
    function Show-Progress {
        param([string]$Message)
        Write-Host "$Message..." -ForegroundColor Cyan
    }
    
    $reportData = @()
    $startTime = Get-Date
    
    Write-Host "INVENTARIO BACKUPS AZURE SQL DATABASE" -ForegroundColor Cyan
    
    Show-Progress "Verificando autenticación Azure"
    try {
        $azContext = az account show --output json 2>$null | ConvertFrom-Json
        if (-not $azContext) { 
            Write-Host "Error: No autenticado. Ejecutar: az login" -ForegroundColor Red
            return
        }
        Write-Host "Usuario: $($azContext.user.name) | Suscripción: $($azContext.name)" -ForegroundColor Green
    }
    catch {
        Write-Host "Error: Az CLI no disponible" -ForegroundColor Red
        return
    }
    
    Show-Progress "Obteniendo servidores SQL"
    try {
        $allServers = az sql server list --subscription $azContext.id --output json 2>$null | ConvertFrom-Json
        
        if (-not $allServers -or $allServers.Count -eq 0) {
            Write-Host "No se encontraron servidores SQL" -ForegroundColor Red
            return
        }
        
        Write-Host "`nSERVIDORES SQL DISPONIBLES ($($allServers.Count)):" -ForegroundColor DarkCyan
        for ($i = 0; $i -lt $allServers.Count; $i++) {
            Write-Host "$($i + 1). $($allServers[$i].name) | $($allServers[$i].location) | RG: $($allServers[$i].resourceGroup)" -ForegroundColor White
        }
        
        Write-Host "`nIngrese números separados por comas o 't' para todos: " -NoNewline -ForegroundColor Yellow
        $selection = Read-Host
        
        $selectedServers = @()
        if ($selection.ToLower() -eq 't') {
            $selectedServers = $allServers
        }
        else {
            $indices = $selection.Split(',') | ForEach-Object { $_.Trim() }
            foreach ($index in $indices) {
                if ([int]::TryParse($index, [ref]$null) -and [int]$index -ge 1 -and [int]$index -le $allServers.Count) {
                    $selectedServers += $allServers[[int]$index - 1]
                }
            }
        }
        
        if ($selectedServers.Count -eq 0) {
            Write-Host "No se seleccionaron servidores válidos" -ForegroundColor Red
            return
        }
    }
    catch {
        Write-Host "Error al obtener servidores: $_" -ForegroundColor Red
        return
    }
    
    foreach ($server in $selectedServers) {
        Write-Host "`nAnalizando: $($server.name)..." -ForegroundColor Yellow
        
        try {
            # $serverInfo = az sql server show --name $server.name --resource-group $server.resourceGroup --output json 2>$null | ConvertFrom-Json
            $databases = az sql db list --server $server.name --resource-group $server.resourceGroup --output json 2>$null | ConvertFrom-Json
            $userDbs = $databases | Where-Object { $_.name -notin @("master") }
            
            if (-not $userDbs) {
                Write-Host "  Sin bases de datos de usuario" -ForegroundColor Yellow
                continue
            }
            
            Write-Host "  Bases disponibles:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $userDbs.Count; $i++) {
                $sizeGB = [math]::Round($userDbs[$i].maxSizeBytes / 1GB, 2)
                Write-Host "    $($i + 1). $($userDbs[$i].name) | $($userDbs[$i].edition)-$($userDbs[$i].currentServiceObjectiveName) | ${sizeGB}GB" -ForegroundColor White
            }
            
            Write-Host "  Seleccione (números/comas o 't'): " -NoNewline -ForegroundColor Yellow
            $dbSelection = Read-Host
            
            $selectedDbs = @()
            if ($dbSelection.ToLower() -eq 't') {
                $selectedDbs = $userDbs
            }
            else {
                $dbIndices = $dbSelection.Split(',') | ForEach-Object { $_.Trim() }
                foreach ($dbIndex in $dbIndices) {
                    if ([int]::TryParse($dbIndex, [ref]$null) -and [int]$dbIndex -ge 1 -and [int]$dbIndex -le $userDbs.Count) {
                        $selectedDbs += $userDbs[[int]$dbIndex - 1]
                    }
                }
            }
            
            foreach ($db in $selectedDbs) {
                Write-Host "    Procesando $($db.name)..." -ForegroundColor Cyan
                
                try {
                    $strPolicy = az sql db str-policy show --resource-group $server.resourceGroup --server $server.name --database $db.name --output json 2>$null | ConvertFrom-Json
                    $ltrPolicy = az sql db ltr-policy show --resource-group $server.resourceGroup --server $server.name --database $db.name --output json 2>$null | ConvertFrom-Json
                    $dbDetails = az sql db show --name $db.name --server $server.name --resource-group $server.resourceGroup --output json 2>$null | ConvertFrom-Json
                    
                    $maxSizeGB = [math]::Round($db.maxSizeBytes / 1GB, 2)
                    $pitrRetention = if ($strPolicy -and $strPolicy.retentionDays) { $strPolicy.retentionDays } else { 7 }
                    
                    $lastRestorePoint = "N/A"
                    if ($dbDetails -and $dbDetails.earliestRestoreDate) {
                        try {
                            $restoreDate = [DateTime]::Parse($dbDetails.earliestRestoreDate)
                            $lastRestorePoint = $restoreDate.ToString("yyyy-MM-dd HH:mm UTC")
                        }
                        catch {
                            $lastRestorePoint = $dbDetails.earliestRestoreDate
                        }
                    }
                    
                    $ltrWeekly = if ($ltrPolicy -and $ltrPolicy.weeklyRetention -and $ltrPolicy.weeklyRetention -ne "PT0S") { $ltrPolicy.weeklyRetention } else { "Deshabilitado" }
                    $ltrMonthly = if ($ltrPolicy -and $ltrPolicy.monthlyRetention -and $ltrPolicy.monthlyRetention -ne "PT0S") { $ltrPolicy.monthlyRetention } else { "Deshabilitado" }
                    $ltrYearly = if ($ltrPolicy -and $ltrPolicy.yearlyRetention -and $ltrPolicy.yearlyRetention -ne "PT0S") { $ltrPolicy.yearlyRetention } else { "Deshabilitado" }
                    
                    $backupRedundancy = if ($dbDetails.currentBackupStorageRedundancy) { $dbDetails.currentBackupStorageRedundancy } elseif ($dbDetails.requestedBackupStorageRedundancy) { $dbDetails.requestedBackupStorageRedundancy } else { "Local" }
                    $redundancyText = switch ($backupRedundancy) {
                        "Local" { "Local" }
                        "Zone" { "Zonal" }
                        "Geo" { "Geografica" }
                        "GeoZone" { "Geo-Zonal" }
                        default { "Local" }
                    }
                    
                    $geoRestoreText = if ($backupRedundancy -like "*Geo*") { "Disponible" } else { "No disponible" }
                    $deletionProtection = if ($dbDetails.deletionProtection -eq $true) { "Activada" } else { "Desactivada" }
                    $hasLTRBackups = $ltrWeekly -ne "Deshabilitado" -or $ltrMonthly -ne "Deshabilitado" -or $ltrYearly -ne "Deshabilitado"
                    
                    $protectionLevel = "Basico"
                    if ($pitrRetention -gt 7 -or $hasLTRBackups) { $protectionLevel = "Intermedio" }
                    if ($pitrRetention -gt 14 -and $hasLTRBackups -and ($ltrWeekly -ne "Deshabilitado" -and $ltrMonthly -ne "Deshabilitado")) { $protectionLevel = "Avanzado" }
                    if ($pitrRetention -gt 14 -and $hasLTRBackups -and ($ltrWeekly -ne "Deshabilitado" -and $ltrMonthly -ne "Deshabilitado" -and $ltrYearly -ne "Deshabilitado") -and $dbDetails.deletionProtection) { $protectionLevel = "Premium" }
                    
                    $reportData += [PSCustomObject]@{
                        'Servidor' = $server.name
                        'Ubicacion' = $server.location
                        'BaseDatos' = $db.name
                        'Tier' = "$($db.edition)-$($db.currentServiceObjectiveName)"
                        'MaxGB' = $maxSizeGB
                        'PITRDias' = $pitrRetention
                        'PuntoRestore' = $lastRestorePoint
                        'LTRSemanal' = $ltrWeekly
                        'LTRMensual' = $ltrMonthly
                        'LTRAnual' = $ltrYearly
                        'Redundancia' = $redundancyText
                        'GeoRestore' = $geoRestoreText
                        'ProteccionElim' = $deletionProtection
                        'NivelProteccion' = $protectionLevel
                        'Estado' = $db.status
                        'FechaCreacion' = (Get-Date $db.creationDate -Format 'yyyy-MM-dd')
                    }
                }
                catch {
                    Write-Host "      Error: $_" -ForegroundColor Red
                }
            }
        }
        catch {
            Write-Host "    Error servidor: $_" -ForegroundColor Red
        }
    }
    
    if ($reportData.Count -gt 0) {
        Write-Host "`nRESULTADOS:" -ForegroundColor Cyan
        
        $tableView = $reportData | Select-Object Servidor, BaseDatos, Tier, MaxGB, PITRDias, NivelProteccion, GeoRestore, ProteccionElim, Estado
        $tableView | Format-Table -AutoSize
        
        $endTime = Get-Date
        $duration = $endTime - $startTime
        
        $totalProcessed = $reportData.Count
        $protectionStats = $reportData | Group-Object NivelProteccion | ForEach-Object { "$($_.Name): $($_.Count)" }
        $geoEnabled = ($reportData | Where-Object { $_.GeoRestore -eq 'Disponible' }).Count
        
        Write-Host "`nESTADISTICAS:" -ForegroundColor Cyan
        Write-Host "Total procesadas: $totalProcessed BD" -ForegroundColor White
        Write-Host "Protección: $($protectionStats -join ', ')" -ForegroundColor White
        Write-Host "Geo-Restore: $geoEnabled BD" -ForegroundColor White
        Write-Host "Tiempo procesamiento: $([math]::Round($duration.TotalSeconds,1))s" -ForegroundColor White
        
        Write-Host "`n¿Exportar informes? (s/n): " -NoNewline -ForegroundColor Yellow
        $export = Read-Host
        
        if ($export.ToLower() -eq 's') {
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $reportFolder = Join-Path (Get-Location) "AzureSQL_Reports"
            
            if (-not (Test-Path $reportFolder)) {
                New-Item -ItemType Directory -Path $reportFolder -Force | Out-Null
            }
            
            $csvPath = Join-Path $reportFolder "AzureSQL_BackupReport_$timestamp.csv"
            $htmlPath = Join-Path $reportFolder "AzureSQL_BackupReport_$timestamp.html"
            
            # Exportar CSV
            $reportData | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
            
            # Generar HTML
            $htmlContent = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure SQL Database - Inventario de Backups</title>
    <style>
        body { font-family: 'Segoe UI', Arial, sans-serif; margin: 0; padding: 20px; background: #f5f5f5; }
        .container { max-width: 1400px; margin: 0 auto; background: white; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); padding: 30px; }
        h1 { color: #2c3e50; text-align: center; margin-bottom: 30px; font-size: 28px; }
        .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 20px; margin-bottom: 30px; }
        .stat-card { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 20px; border-radius: 8px; text-align: center; }
        .stat-number { font-size: 32px; font-weight: bold; margin-bottom: 5px; }
        .stat-label { font-size: 12px; text-transform: uppercase; opacity: 0.9; }
        .table-container { overflow-x: auto; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
        table { width: 100%; border-collapse: collapse; background: white; }
        th, td { padding: 12px 8px; text-align: left; border-bottom: 1px solid #e0e0e0; font-size: 13px; }
        th { background: #34495e; color: white; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; }
        .row-number { background: #ecf0f1 !important; font-weight: bold; text-align: center; width: 40px; }
        .highlight { background: #3498db; color: white; padding: 2px 6px; border-radius: 3px; font-size: 11px; }
        .protection-premium { background: #e74c3c; color: white; padding: 2px 6px; border-radius: 3px; font-weight: bold; }
        .protection-avanzado { background: #f39c12; color: white; padding: 2px 6px; border-radius: 3px; font-weight: bold; }
        .protection-intermedio { background: #f1c40f; color: #2c3e50; padding: 2px 6px; border-radius: 3px; font-weight: bold; }
        .protection-basico { background: #95a5a6; color: white; padding: 2px 6px; border-radius: 3px; }
        .geo-si { color: #27ae60; font-weight: bold; }
        .geo-no { color: #e74c3c; }
        tr:hover { background: #f8f9fa; }
        .footer { margin-top: 40px; padding-top: 20px; border-top: 2px solid #ecf0f1; }
        .footer-content { display: grid; grid-template-columns: 2fr 1fr; gap: 30px; }
        .footer ul { list-style-type: none; padding-left: 0; }
        .footer li { margin: 5px 0; }
        .copyright { text-align: right; color: #7f8c8d; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔄 AZURE SQL DATABASE - INVENTARIO DE BACKUPS</h1>
        
        <div class="stats">
            <div class="stat-card">
                <div class="stat-number">$totalProcessed</div>
                <div class="stat-label">BASES DE DATOS</div>
            </div>
            <div class="stat-card">
                <div class="stat-number">$geoEnabled</div>
                <div class="stat-label">GEO-RESTORE</div>
            </div>
            <div class="stat-card">
                <div class="stat-number">$(($reportData | Where-Object { $_.ProteccionElim -eq 'Activada' }).Count)</div>
                <div class="stat-label">PROTECCIÓN ELIMINACIÓN</div>
            </div>
            <div class="stat-card">
                <div class="stat-number">$(($reportData | Where-Object { $_.NivelProteccion -in @('Avanzado','Premium') }).Count)</div>
                <div class="stat-label">PROTECCIÓN AVANZADA+</div>
            </div>
            <div class="stat-card">
                <div class="stat-number">$(($reportData | Where-Object { $_.NivelProteccion -eq 'Premium' }).Count)</div>
                <div class="stat-label">NIVEL PREMIUM</div>
            </div>
        </div>
        
        <div class="table-container">
        <table>
            <thead>
                <tr>
                    <th class="row-number">Nº</th>
                    <th>Servidor</th>
                    <th>Base de Datos</th>
                    <th>Tier</th>
                    <th>Max GB</th>
                    <th>PITR Días</th>
                    <th>LTR S/M/A</th>
                    <th>Redundancia</th>
                    <th>Geo-Restore</th>
                    <th>Protec. Elim.</th>
                    <th>Nivel Protección</th>
                    <th>Estado</th>
                </tr>
            </thead>
            <tbody>
"@
            
            $rowNumber = 1
            foreach ($row in $reportData) {
                $protectionClass = switch ($row.NivelProteccion) {
                    'Premium' { 'protection-premium' }
                    'Avanzado' { 'protection-avanzado' }
                    'Intermedio' { 'protection-intermedio' }
                    default { 'protection-basico' }
                }
                
                $geoClass = if ($row.GeoRestore -eq 'Disponible') { 'geo-si' } else { 'geo-no' }
                
                $ltrDisplay = "$($row.LTRSemanal)/$($row.LTRMensual)/$($row.LTRAnual)" -replace 'Deshabilitado','No'
                
                $htmlContent += @"
                <tr>
                    <td class="row-number">$rowNumber</td>
                    <td>$($row.Servidor)</td>
                    <td><strong>$($row.BaseDatos)</strong></td>
                    <td><span class="highlight">$($row.Tier)</span></td>
                    <td>$($row.MaxGB)</td>
                    <td>$($row.PITRDias)</td>
                    <td>$ltrDisplay</td>
                    <td>$($row.Redundancia)</td>
                    <td class="$geoClass">$($row.GeoRestore)</td>
                    <td>$($row.ProteccionElim)</td>
                    <td class="$protectionClass">$($row.NivelProteccion)</td>
                    <td>$($row.Estado)</td>
                </tr>
"@
                $rowNumber++
            }
            
            $currentYear = (Get-Date).Year
            $htmlContent += @"
            </tbody>
        </table>
        </div>
        
        <div class="footer">
            <div class="footer-content">
                <div>
                    <h3>Interpretación del informe</h3>
                    <p><strong>Niveles de protección:</strong></p>
                    <ul>
                        <li><strong class="protection-basico">Básico:</strong> PITR ≥7 días (configuración mínima)</li>
                        <li><strong class="protection-intermedio">Intermedio:</strong> PITR extendido (>7 días) o LTR habilitado</li>
                        <li><strong class="protection-avanzado">Avanzado:</strong> PITR >14 días + LTR semanal y mensual</li>
                        <li><strong class="protection-premium">Premium:</strong> Configuración completa + protección eliminación</li>
                    </ul>
                    <p><strong>PITR:</strong> Point-in-Time Recovery permite restaurar a cualquier momento.</p>
                    <p><strong>LTR:</strong> Long Term Retention mantiene copias por períodos extendidos.</p>
                    <p><strong>Geo-Restore:</strong> Restauración desde región secundaria cuando hay redundancia geográfica.</p>
                </div>
                <div class="copyright">
                    <p>Generado con PowerShell + Azure CLI</p>
                    <p>Análisis automatizado de configuraciones</p>
                    <p>Datos obtenidos en tiempo real</p>
                    <br>
                    <p><strong>© $currentYear Tasa Perú</strong></p>
                    <p>Todos los derechos reservados</p>
                </div>
            </div>
        </div>
    </div>
</body>
</html>
"@
            
            $htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8
            
            Write-Host "`nArchivos generados en: $reportFolder" -ForegroundColor Green
            Write-Host "CSV: $(Split-Path $csvPath -Leaf)" -ForegroundColor White
            Write-Host "HTML: $(Split-Path $htmlPath -Leaf)" -ForegroundColor White
            
            # Abrir HTML automáticamente
            try {
                Start-Process $htmlPath
                Write-Host "`nInforme HTML abierto en el navegador" -ForegroundColor Cyan
            }
            catch {
                Write-Host "`nNo se pudo abrir automáticamente. Abrir manualmente: $htmlPath" -ForegroundColor Yellow
            }
        }
    }
    else {
        Write-Host "`nNo se procesaron bases de datos" -ForegroundColor Yellow
    }
}

Get-AzureSQLBackupInventory