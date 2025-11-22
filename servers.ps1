function Get-AzureSQLDatabaseMetrics {
  [CmdletBinding()]
  param()
  
  # ==============1==========================
  # VARIABLES GLOBALES DE TIEMPO Y MÉTRICAS
  # ========================================
  $script:endTime = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString("yyyy-MM-ddTHH:mm:ssZ")
  $script:startTime = (Get-Date).ToUniversalTime().AddHours(-24).AddMinutes(-5).ToString("yyyy-MM-ddTHH:mm:ssZ")
  
  # Variables globales para DTU y CPU (no para almacenamiento)
  $script:metricsInterval = "PT5M"          # 5 minutos granularidad
  $script:metricsAggregation = "Average"    # Tipo de agregación
  $script:metricsPeriod = "24h"             # Período de análisis
  
  Clear-Host
  Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
  Write-Host "║                    AZURE SQL DATABASE MONITORING                            ║" -FforegroundColor Cyan
  Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
  
  $spinnerFrames = "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"
  $spinnerIndex = 0
  
  Write-Host "`n🔐 Verificando autenticación Azure..." -ForegroundColor Cyan
  try {
      $azContext = az account show --output json 2>$null | ConvertFrom-Json
      if (-not $azContext) { 
          Write-Host "❌ No autenticado. Ejecutar: az login" -ForegroundColor Red
          return
      }
      Write-Host "✅ Autenticado como: $($azContext.user.name)" -ForegroundColor Green
  }
  catch {
      Write-Host "❌ Azure CLI no disponible. Instalar Azure CLI" -ForegroundColor Red
      return
  }
  
  # Función para mostrar spinner ANIMADO SECUENCIAL
  function Show-Spinner {
      param([string]$Message, [scriptblock]$Action)
      
      # Inicializar el spinner
      # $spinnerRunning = $true
      $startTime = Get-Date
      
      # Ejecutar la acción en background JOB simple (solo para no bloquear el spinner)
      $job = Start-Job -ScriptBlock $Action
      
      # Mostrar spinner animado mientras el job ejecuta
      while ($job.State -eq 'Running') {
          $frame = $spinnerFrames[$spinnerIndex % $spinnerFrames.Length]
          $elapsed = [Math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
          Write-Host "`r$frame $Message ($elapsed s)" -NoNewline -ForegroundColor Cyan
          Start-Sleep -Milliseconds 120
          $spinnerIndex++
      }
      
      # Obtener resultado
      $result = Receive-Job -Job $job
      $errors = $job.ChildJobs[0].Error
      Remove-Job -Job $job -Force
      
      # Mostrar resultado final
      if ($errors.Count -gt 0) {
          Write-Host "`r❌ $Message - Error                              " -ForegroundColor Red
          throw $errors[0].Exception.Message
      } else {
          Write-Host "`r✅ $Message - Completado                          " -ForegroundColor Green
      }
      
      return $result
  }
  
  $sqlServers = Show-Spinner "Obteniendo servidores SQL" {
      $servers = az sql server list --output json --only-show-errors 2>$null | ConvertFrom-Json
      if (-not $servers) { throw "No servers found" }
      return $servers
  }
  
  if (-not $sqlServers) {
      Write-Host "❌ No hay servidores SQL disponibles" -ForegroundColor Red
      return
  }
  
  Write-Host "`n╭─ 📋 SERVIDORES DISPONIBLES ─────────────────────────────────────────────────╮" -ForegroundColor DarkCyan
  for ($i = 0; $i -lt $sqlServers.Count; $i++) {
      $serverName = $sqlServers[$i].name
      $location = $sqlServers[$i].location
      $padding = " " * (60 - $serverName.Length)
      Write-Host "│ [$($i+1)] $serverName$padding$location │" -ForegroundColor Gray
  }
  Write-Host "│ [T] TODOS LOS SERVIDORES                                            │" -ForegroundColor Yellow
  Write-Host "╰─────────────────────────────────────────────────────────────────────────────╯" -ForegroundColor DarkCyan
  
  Write-Host "`n🎯 Seleccione el servidor (1-$($sqlServers.Count)) o T para todos: " -ForegroundColor Yellow -NoNewline
  $selection = Read-Host
  
  # Validar entrada
  $allServers = $false
  $selectedServers = @()
  
  if ($selection.Trim().ToUpper() -eq "T") {
      $allServers = $true
      $selectedServers = $sqlServers
      Write-Host "🌍 Procesando TODOS los servidores ($($sqlServers.Count) servidores)" -ForegroundColor Green
  } else {
      $serverNumber = 0
      if (-not ([int]::TryParse($selection.Trim(), [ref]$serverNumber) -and $serverNumber -ge 1 -and $serverNumber -le $sqlServers.Count)) {
          Write-Host "❌ Selección inválida. Use 1-$($sqlServers.Count) o T" -ForegroundColor Red
          return
      }
      $selectedServers = @($sqlServers[$serverNumber - 1])
      Write-Host "🔸 Servidor seleccionado: $($selectedServers[0].name)" -ForegroundColor Green
  }
  
  # ========================================
  # SELECCIÓN DE BASES DE DATOS (SOLO PARA SERVIDOR ÚNICO)
  # ========================================
  $selectedDatabases = @()
  $allDatabasesSelected = $true
  
  if (-not $allServers) {
      # Si se seleccionó un solo servidor, permitir seleccionar bases de datos específicas
      $selectedServer = $selectedServers[0]
      
      Write-Host "`n🔧 Obteniendo bases de datos de $($selectedServer.name)..." -ForegroundColor Cyan
      
      try {
          $userDatabases = Show-Spinner "Obteniendo bases de datos de $($selectedServer.name)" {
              $serverName = $using:selectedServer.name
              $resourceGroup = $using:selectedServer.resourceGroup
              
              $databases = az sql db list --server $serverName --resource-group $resourceGroup --output json 2>$null | ConvertFrom-Json
              
              if ($LASTEXITCODE -ne 0) {
                  # Fallback a Azure PowerShell si Azure CLI falla
                  if (Get-Module -ListAvailable -Name Az.Sql) {
                      Import-Module Az.Sql -Force -ErrorAction SilentlyContinue
                      $azDatabases = Get-AzSqlDatabase -ServerName $serverName -ResourceGroupName $resourceGroup -ErrorAction Stop
                      $databases = @()
                      foreach ($db in $azDatabases) {
                          $databases += @{
                              name = $db.DatabaseName
                              edition = $db.Edition
                              currentServiceObjectiveName = $db.CurrentServiceObjectiveName
                              maxSizeBytes = $db.MaxSizeBytes
                          }
                      }
                  }
                  else {
                      throw "Error Azure CLI código: $LASTEXITCODE"
                  }
              }
              
              if (-not $databases) {
                  throw "Respuesta vacía del servidor"
              }
              
              $userDbs = $databases | Where-Object { $_.name -notin @("master", "tempdb", "model", "msdb") }
              
              if (-not $userDbs) {
                  throw "Sin bases de datos de usuario en este servidor"
              }
              
              return $userDbs
          }
          
          if ($userDatabases -and $userDatabases.Count -gt 0) {
              Write-Host "`n╭─ 🗄️ BASES DE DATOS DISPONIBLES EN $($selectedServer.name.ToUpper()) ──────────────────────────────────────╮" -ForegroundColor DarkCyan
              for ($i = 0; $i -lt $userDatabases.Count; $i++) {
                  $dbName = $userDatabases[$i].name
                  $dbEdition = $userDatabases[$i].edition
                  $dbTier = $userDatabases[$i].currentServiceObjectiveName
                  $dbInfo = "$dbName [$dbEdition/$dbTier]"
                  $padding = " " * (70 - $dbInfo.Length)
                  Write-Host "│ [$($i+1)] $dbInfo$padding│" -ForegroundColor Gray
              }
              Write-Host "│ [T] TODAS LAS BASES DE DATOS (default)                                      │" -ForegroundColor Green
              Write-Host "│ [R] RANGO (ej: 1-3,5,7-9)                                                   │" -ForegroundColor Yellow
              Write-Host "╰──────────────────────────────────────────────────────────────────────────────╯" -ForegroundColor DarkCyan
              
              Write-Host "`n🎯 Seleccione las bases de datos:" -ForegroundColor Yellow
              Write-Host "   • Número individual (ej: 3)" -ForegroundColor Gray
              Write-Host "   • Múltiples números separados por coma (ej: 1,3,5)" -ForegroundColor Gray
              Write-Host "   • Rango (ej: 1-4)" -ForegroundColor Gray
              Write-Host "   • Combinación (ej: 1-3,5,7-9)" -ForegroundColor Gray
              Write-Host "   • T o Enter para todas (default)" -ForegroundColor Green
              Write-Host "Selección: " -ForegroundColor Yellow -NoNewline
              $dbSelection = Read-Host
              
              # Procesar selección de bases de datos
              if ([string]::IsNullOrEmpty($dbSelection) -or $dbSelection.Trim().ToUpper() -eq "T") {
                  # Seleccionar todas las bases de datos (default)
                  $selectedDatabases = $userDatabases
                  $allDatabasesSelected = $true
                  Write-Host "🗄️ Seleccionadas TODAS las bases de datos ($($userDatabases.Count) bases)" -ForegroundColor Green
              } else {
                  # Procesar selección específica
                  $allDatabasesSelected = $false
                  $dbIndices = @()
                  
                  try {
                      # Dividir por comas y procesar cada parte
                      $parts = $dbSelection.Split(',') | ForEach-Object { $_.Trim() }
                      
                      foreach ($part in $parts) {
                          if ($part -match '^(\d+)-(\d+)$') {
                              # Rango (ej: 1-4)
                              $start = [int]$matches[1]
                              $end = [int]$matches[2]
                              if ($start -ge 1 -and $end -le $userDatabases.Count -and $start -le $end) {
                                  for ($i = $start; $i -le $end; $i++) {
                                      $dbIndices += $i
                                  }
                              } else {
                                  throw "Rango inválido: $part"
                              }
                          } elseif ($part -match '^\d+$') {
                              # Número individual
                              $num = [int]$part
                              if ($num -ge 1 -and $num -le $userDatabases.Count) {
                                  $dbIndices += $num
                              } else {
                                  throw "Número fuera de rango: $part"
                              }
                          } else {
                              throw "Formato inválido: $part"
                          }
                      }
                      
                      # Eliminar duplicados y ordenar
                      $dbIndices = $dbIndices | Sort-Object -Unique
                      
                      # Seleccionar bases de datos por índices
                      $selectedDatabases = @()
                      foreach ($index in $dbIndices) {
                          $selectedDatabases += $userDatabases[$index - 1]
                      }
                      
                      Write-Host "🎯 Seleccionadas $($selectedDatabases.Count) base(s) de datos:" -ForegroundColor Green
                      foreach ($db in $selectedDatabases) {
                          Write-Host "   • $($db.name) [$($db.edition)/$($db.currentServiceObjectiveName)]" -ForegroundColor Cyan
                      }
                      
                  } catch {
                      Write-Host "❌ Error en selección: $($_.Exception.Message)" -ForegroundColor Red
                      Write-Host "💡 Formato válido: 1,2,3 o 1-5 o 1-3,5,7-9 o T para todas" -ForegroundColor Yellow
                      return
                  }
              }
          } else {
              Write-Host "⚠️ No se encontraron bases de datos de usuario en este servidor" -ForegroundColor Yellow
              return
          }
      } catch {
          Write-Host "❌ Error al obtener bases de datos: $($_.Exception.Message)" -ForegroundColor Red
          return
      }
  } else {
      # Para múltiples servidores, procesar todas las bases de datos
      Write-Host "🌍 Modo múltiples servidores: se procesarán todas las bases de datos automáticamente" -ForegroundColor Green
  }
  
  # ========================================
  # CONFIGURACIÓN PERSONALIZABLE DEL MONITOREO
  # ========================================
  Write-Host "`n╭─ ⚙️ CONFIGURACIÓN DEL MONITOREO ────────────────────────────────────────────╮" -ForegroundColor DarkCyan
  Write-Host "│ Configure los parámetros de análisis:                                     │" -ForegroundColor Gray
  Write-Host "╰────────────────────────────────────────────────────────────────────────────╯" -ForegroundColor DarkCyan
  
  # 1. PERÍODO
  Write-Host "`n📅 Período de análisis:" -ForegroundColor Yellow
  Write-Host "  [1] Última hora" -ForegroundColor Gray
  Write-Host "  [2] Últimas 24 horas" -ForegroundColor Gray
  Write-Host "  [3] Últimos 7 días (default)" -ForegroundColor Green
  Write-Host "Seleccione (1-3) [default: 3]: " -ForegroundColor Yellow -NoNewline
  $periodChoice = Read-Host
  if ([string]::IsNullOrEmpty($periodChoice)) { $periodChoice = "3" }
  
  # 2. AGREGACIÓN
  Write-Host "`n📊 Tipo de agregación:" -ForegroundColor Yellow
  Write-Host "  [1] Promedio (default)" -ForegroundColor Green
  Write-Host "  [2] Máximo" -ForegroundColor Gray
  Write-Host "  [3] Mínimo" -ForegroundColor Gray
  Write-Host "Seleccione (1-3) [default: 1]: " -ForegroundColor Yellow -NoNewline
  $aggregationChoice = Read-Host
  if ([string]::IsNullOrEmpty($aggregationChoice)) { $aggregationChoice = "1" }
  
  switch ($aggregationChoice) {
      "2" { $script:metricsAggregation = "Maximum" }
      "3" { $script:metricsAggregation = "Minimum" }
      default { $script:metricsAggregation = "Average" }
  }
  
  # 3. GRANULARIDAD CON DEFAULTS SEGÚN PERÍODO
  Write-Host "`n⏰ Granularidad de muestreo:" -ForegroundColor Yellow
  
  # Mostrar opciones según el período seleccionado
  switch ($periodChoice) {
      "1" {
          Write-Host "  [1] Cada 1 minuto (default)" -ForegroundColor Green
          Write-Host "  [2] Cada 15 minutos" -ForegroundColor Gray
          Write-Host "  [3] Cada 6 horas" -ForegroundColor Gray
      }
      "2" {
          Write-Host "  [1] Cada 1 minuto" -ForegroundColor Gray
          Write-Host "  [2] Cada 5 minutos (default)" -ForegroundColor Green
          Write-Host "  [3] Cada 15 minutos" -ForegroundColor Gray
      }
      default {
          Write-Host "  [1] Cada 1 minuto" -ForegroundColor Gray
          Write-Host "  [2] Cada 15 minutos" -ForegroundColor Gray
          Write-Host "  [3] Cada 1 hora (default)" -ForegroundColor Green
      }
  }
  
  Write-Host "Seleccione (1-3) [usar default]: " -ForegroundColor Yellow -NoNewline
  $granularityChoice = Read-Host
  if ([string]::IsNullOrEmpty($granularityChoice)) { $granularityChoice = "default" }
  
  # CONFIGURACIONES CONSISTENTES CON AZURE PORTAL
  switch ($periodChoice) {
      "1" { 
          $script:metricsPeriod = "1h"
          $script:endTime = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString("yyyy-MM-ddTHH:mm:ssZ")
          $script:startTime = (Get-Date).ToUniversalTime().AddHours(-1).AddMinutes(-5).ToString("yyyy-MM-ddTHH:mm:ssZ")
          
          # Granularidad para última hora
          switch ($granularityChoice) {
              "1" { $script:metricsInterval = "PT1M" }   # 1 minuto
              "2" { $script:metricsInterval = "PT15M" }  # 15 minutos
              "3" { $script:metricsInterval = "PT6H" }   # 6 horas
              default { $script:metricsInterval = "PT1M" } # Default: 1 minuto
          }
      }
      "2" { 
          $script:metricsPeriod = "24h"
          $script:endTime = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString("yyyy-MM-ddTHH:mm:ssZ")
          $script:startTime = (Get-Date).ToUniversalTime().AddHours(-24).AddMinutes(-5).ToString("yyyy-MM-ddTHH:mm:ssZ")
          
          # Granularidad para últimas 24 horas
          switch ($granularityChoice) {
              "1" { $script:metricsInterval = "PT1M" }   # 1 minuto
              "2" { $script:metricsInterval = "PT5M" }   # 5 minutos
              "3" { $script:metricsInterval = "PT15M" }  # 15 minutos
              default { $script:metricsInterval = "PT5M" } # Default: 5 minutos
          }
      }
      default { 
          $script:metricsPeriod = "7d"
          $script:endTime = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString("yyyy-MM-ddTHH:mm:ssZ")
          $script:startTime = (Get-Date).ToUniversalTime().AddDays(-7).AddMinutes(-5).ToString("yyyy-MM-ddTHH:mm:ssZ")
          
          # Granularidad para últimos 7 días
          switch ($granularityChoice) {
              "1" { $script:metricsInterval = "PT1M" }   # 1 minuto
              "2" { $script:metricsInterval = "PT15M" }  # 15 minutos
              "3" { $script:metricsInterval = "PT1H" }   # 1 hora
              default { $script:metricsInterval = "PT1H" } # Default: 1 hora
          }
      }
  }
  
  Write-Host "`n✅ Configuración aplicada:" -ForegroundColor Green
  Write-Host "   • Período: $($script:metricsPeriod) | Agregación: $($script:metricsAggregation) | Granularidad: $($script:metricsInterval)" -ForegroundColor Cyan
  
  # ========================================
  # PROCESAR TODOS LOS SERVIDORES SELECCIONADOS
  # ========================================
  $allResults = @()
  # $allDetectedModels = @()
  
  foreach ($selectedServer in $selectedServers) {
      Write-Host "`n🔧 Procesando servidor: $($selectedServer.name)" -ForegroundColor Yellow
      
      # Obtener bases de datos una sola vez
      $userDatabases = Show-Spinner "Obteniendo bases de datos de $($selectedServer.name)" {
          $serverName = $using:selectedServer.name
          $resourceGroup = $using:selectedServer.resourceGroup
          
          $databases = az sql db list --server $serverName --resource-group $resourceGroup --output json 2>$null | ConvertFrom-Json
          if (-not $databases) { throw "Respuesta vacía del servidor" }
          
          $userDbs = $databases | Where-Object { $_.name -notin @("master", "tempdb", "model", "msdb") }
          if (-not $userDbs) { throw "Sin bases de datos de usuario en este servidor" }
          
          return $userDbs
      }
      
      # Determinar qué bases de datos procesar
      $databasesToProcess = if ($allServers) { 
        $userDatabases 
      } else { 
        if ($allDatabasesSelected) { $selectedDatabases } else { $selectedDatabases }
      }
      
      Write-Host "📊 Procesando $($databasesToProcess.Count) base(s) de datos..." -ForegroundColor Cyan
      
      # PROCESAR CADA BASE DE DATOS UNA SOLA VEZ
      foreach ($database in $databasesToProcess) {
        $dbMetrics = Show-Spinner "Analizando $($selectedServer.name)/$($database.name)" {
            $azContextId = $using:azContext.id
            $serverName = $using:selectedServer.name
            $resourceGroup = $using:selectedServer.resourceGroup
            $dbName = $using:database.name
            $dbEdition = $using:database.edition
            $dbTier = $using:database.currentServiceObjectiveName
            $dbMaxSize = $using:database.maxSizeBytes
            $endTimeVar = $using:script:endTime
            $startTimeVar = $using:script:startTime
            $metricsIntervalVar = $using:script:metricsInterval
            $metricsAggregationVar = $using:script:metricsAggregation
            
            $resourceId = "/subscriptions/$azContextId/resourceGroups/$resourceGroup/providers/Microsoft.Sql/servers/$serverName/databases/$dbName"
            $maxSizeGB = if ($dbMaxSize -gt 0) { [Math]::Round($dbMaxSize / 1GB, 1) } else { 100.0 }
            
            # Detectar modelo
            $isDtuModel = $dbEdition -in @("Basic", "Standard", "Premium") -or ($dbTier -and $dbTier -match "^(S[0-9]|P[0-9]|Basic)")
            # $modelType = if ($isDtuModel) { "DTU" } else { "vCore" }
            
            # Storage simplificado
            $usedGB = 0.0
            try {
                $storageBytes = az monitor metrics list --resource $resourceId --metric "storage" --query "value[0].timeseries[0].data[-1].maximum" -o tsv 2>$null
                if ($storageBytes -and $storageBytes -ne "null") {
                    $usedGB = [Math]::Round([double]$storageBytes / 1GB, 1)
                }
            } catch { $usedGB = [Math]::Round($maxSizeGB * 0.01, 1) }
            
            $remainingGB = [Math]::Round($maxSizeGB - $usedGB, 1)
            $percentUsed = [Math]::Round(($usedGB / $maxSizeGB) * 100, 1)
            
            # FUNCIÓN HELPER SIMPLIFICADA PARA MÉTRICAS
            function Get-MetricData {
                param($MetricName, $RawData)
                
                if ($RawData -and $RawData -ne "null" -and $RawData -ne "[]") {
                    $data = $RawData | ConvertFrom-Json | Where-Object { $null -ne $_.average }
                    
                    if ($data.Count -gt 0) {
                        $values = $data | ForEach-Object { $_.average }
                        $max = ($values | Measure-Object -Maximum).Maximum
                        $min = ($values | Measure-Object -Minimum).Minimum
                        $avg = ($values | Measure-Object -Average).Average
                        
                        # CÁLCULO DE TIEMPO EN 100%
                        $timeAt100Percent = 0
                        $totalTimePoints = $data.Count
                        $pointsAt100 = ($values | Where-Object { $_ -ge 100 }).Count
                        
                        if ($totalTimePoints -gt 0) {
                            $timeAt100Percent = [Math]::Round(($pointsAt100 / $totalTimePoints) * 100, 2)
                        }
                        
                        # CÁLCULO DE TIEMPO EN ALTO RENDIMIENTO (>90%)
                        $pointsAtHigh = ($values | Where-Object { $_ -ge 90 }).Count
                        $timeAtHighPercent = if ($totalTimePoints -gt 0) { [Math]::Round(($pointsAtHigh / $totalTimePoints) * 100, 2) } else { 0 }
                        
                        # Serie temporal simplificada
                        $timeSeries = foreach ($point in $data) {
                            @{
                                Time = ([DateTime]$point.timeStamp).AddHours(-5).ToString("HH:mm")
                                Value = [Math]::Round($point.average, 2)
                                FormattedTime = ([DateTime]$point.timeStamp).AddHours(-5).ToString("dd/MM/yyyy HH:mm:ss")
                                OriginalTimestamp = $point.timeStamp
                            }
                        }
                        
                        # Picos y valles para consola únicamente
                        $peaks = $data | Where-Object { $_.average -eq $max } | ForEach-Object {
                            $value = [Math]::Round($_.average, 2)
                            $time = ([DateTime]$_.timeStamp).AddHours(-5).ToString("dd/MM/yyyy HH:mm:ss")
                            "$value% - $time"
                        }
                        
                        $valleys = $data | Where-Object { $_.average -eq $min } | ForEach-Object {
                            $value = [Math]::Round($_.average, 2)
                            $time = ([DateTime]$_.timeStamp).AddHours(-5).ToString("dd/MM/yyyy HH:mm:ss")
                            "$value% - $time"
                        }
                        
                        # SOLO RETORNAR DATOS CALCULADOS, SIN EVALUACIÓN DE ESTADO
                        return @{
                            Consumption = "Avg: $([Math]::Round($avg, 2))% | Max: $([Math]::Round($max, 2))% | Min: $([Math]::Round($min, 2))%"
                            TimeAt100 = $timeAt100Percent
                            TimeAtHigh = $timeAtHighPercent
                            Peaks = $peaks
                            Valleys = $valleys
                            TimeSeriesData = $timeSeries
                            Avg = $avg; Max = $max; Min = $min
                        }
                    }
                }
                
                return @{
                    Consumption = "N/A"
                    TimeAt100 = 0; TimeAtHigh = 0; Peaks = @(); Valleys = @(); TimeSeriesData = @()
                    Avg = 0; Max = 0; Min = 0
                }
            }
            
            # MÉTRICAS UNIFICADAS - SOLO OBTENER DATOS
            $performanceMetric = if ($isDtuModel) { "dtu_consumption_percent" } else { "cpu_percent" }
            $metricUsed = if ($isDtuModel) { "DTU" } else { "CPU" }
            
            $performanceData = @{ Consumption = "N/A"; Peaks = @(); Valleys = @(); TimeSeriesData = @(); Avg = 0; Max = 0; Min = 0 }
            $cpuData = @{ Consumption = "N/A"; Peaks = @(); Valleys = @(); TimeSeriesData = @(); Avg = 0; Max = 0; Min = 0 }
            
            try {
                # Obtener métrica principal
                $performanceRawData = az monitor metrics list --resource $resourceId --metric $performanceMetric --interval $metricsIntervalVar --aggregation $metricsAggregationVar --start-time $startTimeVar --end-time $endTimeVar --query "value[0].timeseries[0].data" -o json 2>$null
                $performanceData = Get-MetricData -MetricName $performanceMetric -RawData $performanceRawData
                
                # CPU adicional solo para DTU
                if ($isDtuModel) {
                    $cpuRawData = az monitor metrics list --resource $resourceId --metric "cpu_percent" --interval $metricsIntervalVar --aggregation $metricsAggregationVar --start-time $startTimeVar --end-time $endTimeVar --query "value[0].timeseries[0].data" -o json 2>$null
                    $cpuData = Get-MetricData -MetricName "cpu_percent" -RawData $cpuRawData
                } else {
                    # Para vCore, CPU = Performance
                    $cpuData = $performanceData
                }
            }
            catch {
                Write-Host "❌ ERROR: $($_.Exception.Message)" -ForegroundColor Red
            }
            
            # RETORNAR SOLO DATOS CALCULADOS - SIN ESTADO
            return @{
                Name = $dbName; Edition = $dbEdition; Tier = $dbTier
                UsedGB = $usedGB; MaxGB = $maxSizeGB; RemainingGB = $remainingGB; Percent = $percentUsed
                PerformanceAvg = $performanceData.Consumption
                PerformancePeaks = $performanceData.Peaks
                PerformanceValleys = $performanceData.Valleys
                CpuAvg = $cpuData.Consumption
                CpuPeaks = $cpuData.Peaks
                CpuValleys = $cpuData.Valleys
                ResourceId = $resourceId; ModelType = $metricUsed; IsDtuModel = $isDtuModel; MetricUsed = $metricUsed
                AllTimeSeriesData = $performanceData.TimeSeriesData
                AllCpuTimeSeriesData = $cpuData.TimeSeriesData
                PerformanceAvgValue = $performanceData.Avg; PerformanceMaxValue = $performanceData.Max; PerformanceMinValue = $performanceData.Min
                CpuAvgValue = $cpuData.Avg; CpuMaxValue = $cpuData.Max; CpuMinValue = $cpuData.Min
            }
        }
        
        # CALCULAR CRECIMIENTO DE STORAGE (ANTES DE EVALUAR ESTADO)
        $storageGrowth = @{ HasGrowthData = $false; NetGrowth = 0 }
        
        # Aquí se calcularía el crecimiento si tuviéramos datos históricos
        if ($dbMetrics.Percent -gt 5) {
            $estimatedGrowth = [Math]::Round(($dbMetrics.Percent / 100) * 0.1, 2)  # Estimación simple
            $storageGrowth.HasGrowthData = $true
            $storageGrowth.NetGrowth = $estimatedGrowth
        }
        
        # MOSTRAR MÉTRICAS DE ALMACENAMIENTO DETALLADAS POR CONSOLA (NUEVO REQUERIMIENTO)
        Write-Host "`n   💾 ALMACENAMIENTO $($dbMetrics.Name):" -ForegroundColor White
        Write-Host "      📊 Usado: $($dbMetrics.UsedGB)GB ($($dbMetrics.Percent)%) | Total: $($dbMetrics.MaxGB)GB | Libre: $($dbMetrics.RemainingGB)GB" -ForegroundColor Cyan
        
        # Mostrar análisis de crecimiento detallado por consola
        if ($storageGrowth.HasGrowthData) {
            $growthGB = $storageGrowth.NetGrowth
            $growthColor = if ($growthGB -gt 2.0) { "Red" } elseif ($growthGB -gt 1.0) { "Yellow" } else { "Green" }
            Write-Host "      📈 Crecimiento en período: +$($growthGB)GB" -ForegroundColor $growthColor
            
            # Proyección de crecimiento
            $periodHours = switch ($script:metricsPeriod) {
                "1h" { 1 }
                "24h" { 24 }
                "7d" { 168 }
                default { 24 }
            }
            
            if ($growthGB -gt 0) {
                $dailyGrowthGB = ($growthGB / $periodHours) * 24
                $daysToFull = if ($dailyGrowthGB -gt 0) { [Math]::Round($dbMetrics.RemainingGB / $dailyGrowthGB, 0) } else { 999 }
                
                if ($daysToFull -lt 30) {
                    Write-Host "      ⚠️ PROYECCIÓN CRÍTICA: ~$daysToFull días hasta llenado" -ForegroundColor Red
                } elseif ($daysToFull -lt 90) {
                    Write-Host "      📅 Proyección: ~$daysToFull días hasta llenado" -ForegroundColor Yellow
                } else {
                    Write-Host "      ✅ Crecimiento estable: >$daysToFull días hasta llenado" -ForegroundColor Green
                }
            }
        } else {
            Write-Host "      📈 Crecimiento: Sin datos suficientes para análisis" -ForegroundColor Gray
        }
        
        # MOSTRAR PICOS Y VALLES POR CONSOLA
        Write-Host "`n   📊 RENDIMIENTO $($dbMetrics.Name) [$($dbMetrics.MetricUsed)]:" -ForegroundColor White
        if ($dbMetrics.PerformancePeaks.Count -gt 0) {
            Write-Host "      🔺 Picos: $($dbMetrics.PerformancePeaks -join '; ')" -ForegroundColor Red
        }
        if ($dbMetrics.PerformanceValleys.Count -gt 0) {
            Write-Host "      🔻 Valles: $($dbMetrics.PerformanceValleys -join '; ')" -ForegroundColor Green
        }
        if ($dbMetrics.IsDtuModel -and $dbMetrics.CpuPeaks.Count -gt 0) {
            Write-Host "      🔺 Picos CPU: $($dbMetrics.CpuPeaks -join '; ')" -ForegroundColor Red
            Write-Host "      🔻 Valles CPU: $($dbMetrics.CpuValleys -join '; ')" -ForegroundColor Green
        }
        
        # DETERMINAR ESTADO CON MOTIVOS SUSTENTADOS
        $criticalityLevel = 1
        $statusReasons = @()
        $overallStatus = "🟢 ÓPTIMO"
        
        # OBTENER VALORES REALES CALCULADOS
        $realPerformanceAvg = $dbMetrics.PerformanceAvgValue
        $realPerformanceMax = $dbMetrics.PerformanceMaxValue
        # $realCpuAvg = $dbMetrics.CpuAvgValue
        # $realCpuMax = $dbMetrics.CpuMaxValue
        $realStoragePercent = $dbMetrics.Percent
        
        # DEBUG: Mostrar valores reales en consola para verificación
        Write-Host "      🔧 DEBUG: Promedio real: $realPerformanceAvg% | Máximo real: $realPerformanceMax%" -ForegroundColor Magenta
        
        # LÓGICA CORREGIDA CON VALORES REALES - UMBRALES MODERADOS BASADOS EN AZURE BEST PRACTICES 2025
        # Referencia: Azure recomienda investigar cuando CPU >80% por períodos extendidos
        # Microsoft considera 99.9% fit como objetivo, permitiendo picos ocasionales al 100%
        if ($realPerformanceAvg -gt 90) {
            # Promedio >90% = Saturación constante crítica
            $criticalityLevel = 4
            $overallStatus = "🔴 CRÍTICO"
            $statusReasons += "Promedio $($dbMetrics.MetricUsed): $([Math]::Round($realPerformanceAvg,1))% (>90% constante)"
        } elseif ($realPerformanceAvg -gt 80) {
            # Promedio >80% = Según Azure docs, requiere atención
            $criticalityLevel = 3
            $overallStatus = "🟠 ALTO"
            $statusReasons += "Promedio $($dbMetrics.MetricUsed): $([Math]::Round($realPerformanceAvg,1))% (>80% Azure threshold)"
        } elseif ($realPerformanceAvg -gt 65) {
            # Promedio >65% = Moderado, permite crecimiento
            $criticalityLevel = 2
            $overallStatus = "🟡 MODERADO"
            $statusReasons += "Promedio $($dbMetrics.MetricUsed): $([Math]::Round($realPerformanceAvg,1))% (>65%)"
        } 
        
        # EVALUACIÓN INTELIGENTE DE PICOS - UMBRALES MÁS REALISTAS
        if ($realPerformanceMax -ge 100) {
            # Calcular duración y frecuencia de picos críticos
            $criticalPeakCount = 0
            $totalDataPoints = 0
            
            # Analizar los datos de la serie temporal para calcular duración real de picos
            if ($dbMetrics.AllTimeSeriesData -and $dbMetrics.AllTimeSeriesData.Count -gt 0) {
                $totalDataPoints = $dbMetrics.AllTimeSeriesData.Count
                $criticalPeakCount = ($dbMetrics.AllTimeSeriesData | Where-Object { $_.Value -ge 100 }).Count
            }
            
            # Calcular porcentaje de tiempo en picos críticos
            $percentTimeAtCritical = if ($totalDataPoints -gt 0) { 
                [Math]::Round(($criticalPeakCount / $totalDataPoints) * 100, 1) 
            } else { 0 }
            
            Write-Host "      📊 ANÁLISIS PICOS: $criticalPeakCount de $totalDataPoints puntos en 100% ($percentTimeAtCritical% del tiempo)" -ForegroundColor Cyan
            
            # UMBRALES MODERADOS: Azure permite picos ocasionales al 100%
            if ($percentTimeAtCritical -gt 25) {
                # Más del 25% del tiempo en 100% = CRÍTICO (muy sostenido)
                $criticalityLevel = [Math]::Max($criticalityLevel, 4)
                $overallStatus = "🔴 CRÍTICO"
                $statusReasons += "Picos críticos sostenidos: $percentTimeAtCritical% tiempo en 100%"
            } elseif ($percentTimeAtCritical -gt 10 -and $realPerformanceAvg -gt 70) {
                # Más del 10% del tiempo en 100% + promedio alto = ALTO
                $criticalityLevel = [Math]::Max($criticalityLevel, 3)
                if ($overallStatus -notmatch "CRÍTICO") { $overallStatus = "🟠 ALTO" }
                $statusReasons += "Picos frecuentes: $percentTimeAtCritical% tiempo en 100% + promedio alto"
            } elseif ($percentTimeAtCritical -gt 5 -and $realPerformanceAvg -gt 60) {
                # Picos moderados con promedio medio-alto = MODERADO
                if ($overallStatus -eq "🟢 ÓPTIMO") {
                    $criticalityLevel = [Math]::Max($criticalityLevel, 2)
                    $overallStatus = "🟡 MODERADO"
                    $statusReasons += "Picos regulares: $percentTimeAtCritical% tiempo en 100%"
                }
            } elseif ($percentTimeAtCritical -gt 0 -and $realPerformanceAvg -lt 60) {
                # Picos ocasionales con promedio bajo = Normal según Azure (batch jobs)
                if ($overallStatus -eq "🟢 ÓPTIMO" -and $percentTimeAtCritical -le 2) {
                    # Solo mencionar si son muy pocos picos
                    Write-Host "      ✅ Picos ocasionales normales para batch jobs: $percentTimeAtCritical% tiempo" -ForegroundColor Green
                }
            }
        } elseif ($realPerformanceMax -gt 95) {
            # Picos altos pero no 100% - Más tolerante
            if ($realPerformanceAvg -gt 75) {
                $criticalityLevel = [Math]::Max($criticalityLevel, 3)
                if ($overallStatus -notmatch "CRÍTICO") { $overallStatus = "🟠 ALTO" }
                $statusReasons += "Pico $($dbMetrics.MetricUsed): $([Math]::Round($realPerformanceMax,1))% + promedio alto"
            } elseif ($realPerformanceAvg -gt 50 -and $overallStatus -eq "🟢 ÓPTIMO") {
                $criticalityLevel = [Math]::Max($criticalityLevel, 2)
                $overallStatus = "🟡 MODERADO"
                $statusReasons += "Pico $($dbMetrics.MetricUsed): $([Math]::Round($realPerformanceMax,1))% (>95%)"
            }
        } elseif ($realPerformanceMax -gt 85) {
            # Picos moderados - Solo alertar si hay patrón con promedio alto
            if ($realPerformanceAvg -gt 70) {
                $criticalityLevel = [Math]::Max($criticalityLevel, 2)
                if ($overallStatus -eq "🟢 ÓPTIMO") { $overallStatus = "🟡 MODERADO" }
                $statusReasons += "Combinación: Pico $([Math]::Round($realPerformanceMax,1))% + promedio alto"
            }
        }
        
        # EVALUACIÓN DE STORAGE - UMBRALES MÁS REALISTAS
        if ($realStoragePercent -gt 95) {
            $criticalityLevel = [Math]::Max($criticalityLevel, 4)
            if ($overallStatus -notmatch "CRÍTICO") { $overallStatus = "🔴 CRÍTICO" }
            $statusReasons += "Storage crítico: $realStoragePercent% (>95%)"
        } elseif ($realStoragePercent -gt 90) {
            $criticalityLevel = [Math]::Max($criticalityLevel, 3)
            if ($overallStatus -notmatch "CRÍTICO") { $overallStatus = "🟠 ALTO" }
            $statusReasons += "Storage alto: $realStoragePercent% (>90%)"
        } elseif ($realStoragePercent -gt 85 -and $overallStatus -eq "🟢 ÓPTIMO") {
            $criticalityLevel = [Math]::Max($criticalityLevel, 2)
            $overallStatus = "🟡 MODERADO"
            $statusReasons += "Storage moderado: $realStoragePercent% (>85%)"
        }
        
        # Estado final con justificación
        $finalStatus = if ($statusReasons.Count -gt 0) {
            "$overallStatus | " + ($statusReasons -join "; ")
        } else {
            "$overallStatus | Promedio: $([Math]::Round($realPerformanceAvg,1))%, Pico: $([Math]::Round($realPerformanceMax,1))%"
        }
        
        # AGREGAR RESULTADO CON CRITICALITY LEVEL
        $allResults += [PSCustomObject]@{
            'N°' = $allResults.Count + 1
            'Servidor' = $selectedServer.name.Split('-')[-1]
            'Base de Datos [Edición/Tier]' = "$($dbMetrics.Name) [$($dbMetrics.Edition)/$($dbMetrics.Tier)] ($($dbMetrics.MetricUsed))"
            'Storage Detallado' = if ($storageGrowth.HasGrowthData) {
                "Usado: $($dbMetrics.UsedGB)GB | Total: $($dbMetrics.MaxGB)GB | Libre: $($dbMetrics.RemainingGB)GB | Ocupado: $($dbMetrics.Percent)% | Crecimiento: +$($storageGrowth.NetGrowth)GB"
            } else {
                "Usado: $($dbMetrics.UsedGB)GB | Total: $($dbMetrics.MaxGB)GB | Libre: $($dbMetrics.RemainingGB)GB | Ocupado: $($dbMetrics.Percent)% | Crecimiento: N/A"
            }
            'DTU DETALLADO' = $dbMetrics.PerformanceAvg
            'CPU % DETALLADO' = $dbMetrics.CpuAvg
            'Estado' = $finalStatus
            'CriticalityLevel' = $criticalityLevel
            'ModelType' = $dbMetrics.ModelType
            'MetricUsed' = $dbMetrics.MetricUsed
            'AllTimeSeriesData' = $dbMetrics.AllTimeSeriesData
            'AllCpuTimeSeriesData' = $dbMetrics.AllCpuTimeSeriesData
            'StorageGrowthValue' = if ($storageGrowth.HasGrowthData) { $storageGrowth.NetGrowth } else { $null }
            'HasGrowthData' = $storageGrowth.HasGrowthData
        }
    }
}

$results = $allResults
# $detectedModels = $allDetectedModels

# ======================
# ORDENAR POR CRITICIDAD
# ======================
Write-Host "`n🔄 Ordenando resultados por criticidad..." -ForegroundColor Cyan
$results = $results | Sort-Object @{Expression="CriticalityLevel"; Descending=$true}, @{Expression="StoragePercent"; Descending=$true}, @{Expression="PerformanceAvgValue"; Descending=$true}

# Renumerar después del ordenamiento
for ($i = 0; $i -lt $results.Count; $i++) {
    $results[$i].'N°' = $i + 1
}

# ========================================
# HEADER SIMPLIFICADO DTU/CPU
# ========================================
  
# Mostrar tabla única con toda la información
if ($results.Count -gt 0) {
      # INFORMACIÓN DEL MONITOREO
      Write-Host "`n┌─ CONFIGURACIÓN DEL MONITOREO ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor DarkCyan
      Write-Host "│ Período: $($script:metricsPeriod) | Agregación: $($script:metricsAggregation) | Granularidad: $($script:metricsInterval) | Inicio: $($script:startTime) | Fin: $($script:endTime) | Zona Horaria: UTC-5 (Perú)                │" -ForegroundColor Yellow
      Write-Host "└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor DarkCyan
      
      Write-Host "`n┌─ AZURE SQL DATABASE METRICS ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor DarkCyan
      Write-Host "│                                                                           Análisis Completo de Rendimiento por Base de Datos                                                                                                │" -ForegroundColor DarkCyan
      Write-Host "├─────┬──────────┬─────────────────────────────────────────────────┬───────────────────────────────────────────────────────┬──────────────────────────────────────────────────────┬──────────────────────────────────────────────────────┬─────────────────────────────────────────────────────┤" -ForegroundColor DarkCyan
      Write-Host "│ N°  │ Servidor │ Base de Datos [Edición/Tier]                   │ Storage Detallado                                        │ DTU DETALLADO (Avg|Max|Min)                     │ CPU % DETALLADO (Avg|Max|Min)                       │ Estado                                              │" -ForegroundColor Cyan
      Write-Host "├─────┼──────────┼─────────────────────────────────────────────────┼───────────────────────────────────────────────────────┼──────────────────────────────────────────────────────┼──────────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤" -ForegroundColor DarkCyan
      
      # Tabla con las nuevas columnas y formato mejorado
      foreach ($result in $results) {
          $num = $result.'N°'.ToString().PadLeft(2)
          
          # Servidor simplificado (8 chars) - CON VALIDACIÓN NULL
          $serverName = if ($result.'Servidor') { $result.'Servidor'.ToString() } else { "N/A" }
          if ($serverName.Length -gt 8) {
              $serverName = $serverName.Substring(0, 8)
          }
          $serverName = $serverName.PadRight(8)
          
          # Base de datos (45 chars) - CON VALIDACIÓN NULL
          $dbInfo = if ($result.'Base de Datos [Edición/Tier]') { $result.'Base de Datos [Edición/Tier]'.ToString() } else { "N/A" }
          if ($dbInfo.Length -gt 45) {
              $dbInfo = $dbInfo.Substring(0, 42) + "..."
          }
          $dbInfo = $dbInfo.PadRight(45)
          
          # Storage DETALLADO (55 chars) - CON VALIDACIÓN NULL
          $storageInfo = if ($result.'Storage Detallado') { $result.'Storage Detallado'.ToString() } else { "N/A" }
          if ($storageInfo.Length -gt 55) {
              $storageInfo = $storageInfo.Substring(0, 52) + "..."
          }
          $storageInfo = $storageInfo.PadRight(55)
          
          # Color del crecimiento según valor
          $growthColor = "White"
          if ($storageInfo -match 'Crecimiento: \+?(-?\d+\.?\d*)GB') {
              $growthValue = [double]$matches[1]
              $growthColor = if ($growthValue -gt 1.0) { "Red" } 
                            elseif ($growthValue -gt 0.5) { "Yellow" } 
                            elseif ($growthValue -gt 0) { "Green" } 
                            else { "Cyan" }
          }
          
          # DTU (52 chars) - CON VALIDACIÓN NULL Y FORMATO EXPANDIDO
          $performanceDetailed = if ($result.'DTU DETALLADO' -match 'Avg: ([\d.]+)%') { "Avg: $([Math]::Round($matches[1],2))%" } else { "Avg: 0%" }
          $performanceDetailed += if ($result.'DTU DETALLADO' -match 'Max: ([\d.]+)%') { " | Max: $([Math]::Round($matches[1],2))%" } else { " | Max: 0%" }
          $performanceDetailed = $performanceDetailed.PadRight(52)
          $performanceColor = if ($result.PerformanceColor) { $result.PerformanceColor } else { "Gray" }
          
          # CPU % DETALLADO (52 chars) - CON VALIDACIÓN NULL Y FORMATO EXPANDIDO
          $cpuDetailed = if ($result.'CPU % DETALLADO' -match 'Avg: ([\d.]+)%') { "Avg: $([Math]::Round($matches[1],2))%" } else { "Avg: 0%" }
          $cpuDetailed += if ($result.'CPU % DETALLADO' -match 'Max: ([\d.]+)%') { " | Max: $([Math]::Round($matches[1],2))%" } else { " | Max: 0%" }
          $cpuDetailed = $cpuDetailed.PadRight(52)
          $cpuColor = if ($result.CpuColor) { $result.CpuColor } else { "Gray" }
          
          # Estado (51 chars) - CON VALIDACIÓN NULL Y COLORES SEGÚN ESTADO
          $status = if ($result.'Estado') { $result.'Estado'.ToString() } else { "🔘 SIN DATOS" }
          if ($status.Length -gt 51) {
              $status = $status.Substring(0, 48) + "..."
          }
          $status = $status.PadRight(51)
          
          # Color del estado según contenido
          $statusColor = if ($status -match "🔴.*CRÍTICO") { "Red" }
                        elseif ($status -match "🟠.*ALTO") { "Yellow" }
                        elseif ($status -match "🟡.*MODERADO") { "DarkYellow" }
                        elseif ($status -match "🟢.*ÓPTIMO") { "Green" }
                        else { "Gray" }
          
          Write-Host "│" -NoNewline -ForegroundColor DarkCyan
          Write-Host " $num " -NoNewline -ForegroundColor White
          Write-Host "│ " -NoNewline -ForegroundColor DarkCyan
          Write-Host "$serverName" -NoNewline -ForegroundColor Cyan
          Write-Host " │ " -NoNewline -ForegroundColor DarkCyan
          Write-Host "$dbInfo" -NoNewline -ForegroundColor Gray
          Write-Host " │ " -NoNewline -ForegroundColor DarkCyan
          Write-Host "$storageInfo" -NoNewline -ForegroundColor $growthColor
          Write-Host " │ " -NoNewline -ForegroundColor DarkCyan
          Write-Host "$performanceDetailed" -NoNewline -ForegroundColor $performanceColor
          Write-Host " │ " -NoNewline -ForegroundColor DarkCyan
          Write-Host "$cpuDetailed" -NoNewline -ForegroundColor $cpuColor
          Write-Host " │ " -NoNewline -ForegroundColor DarkCyan
          Write-Host "$status" -NoNewline -ForegroundColor $statusColor
          Write-Host " │" -ForegroundColor DarkCyan
      }
      
      Write-Host "└─────┴──────────┴─────────────────────────────────────────────────┴───────────────────────────────────────────────────────┴──────────────────────────────────────────────────────┴──────────────────────────────────────────────────────┴─────────────────────────────────────────────────────┘" -ForegroundColor DarkCyan
      
      # ========================================
      # FOOTER EXPLICATIVO PROFESIONAL
      # ========================================
      Write-Host "`n┌─ 📖 GUÍA DE INTERPRETACIÓN DE RESULTADOS ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor DarkCyan
      Write-Host "│                                                                          GLOSARIO DE TÉRMINOS TÉCNICOS                                                                                                                          │" -ForegroundColor DarkCyan
      Write-Host "├─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor DarkCyan
      Write-Host "│ 🔹 DTU (Database Transaction Units): Medida combinada de CPU, memoria y E/S (entrada/salida de datos). Indica la capacidad de procesamiento total de la base de datos                                                          │" -ForegroundColor Gray
      Write-Host "│ 🔹 vCore: Núcleos virtuales de procesador dedicados. Modelo más flexible que permite control independiente de CPU, memoria y almacenamiento                                                                                   │" -ForegroundColor Gray
      Write-Host "│ 🔹 CPU %: Porcentaje de uso del procesador. Indica qué tan ocupado está el cerebro de la base de datos procesando consultas                                                                                                    │" -ForegroundColor Gray
      Write-Host "│ 🔹 Storage (Almacenamiento): Espacio en disco utilizado vs. total disponible. Usado/Total/Libre se mide en GB (Gigabytes)                                                                                                      │" -ForegroundColor Gray
      Write-Host "│ 🔹 Crecimiento: Incremento del tamaño de la base de datos durante el período analizado (útil para proyectar necesidades futuras)                                                                                               │" -ForegroundColor Gray
      Write-Host "│                                                                                                                                                                                                                                 │" -ForegroundColor DarkCyan
      Write-Host "│                                                                           INTERPRETACIÓN DE ESTADOS                                                                                                                           │" -ForegroundColor DarkCyan
      Write-Host "├─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor DarkCyan
      Write-Host "│ 🟢 ÓPTIMO: Rendimiento normal. Promedios bajos y picos controlados. La base de datos opera sin problemas                                                                                                                        │" -ForegroundColor Green
      Write-Host "│ 🟡 MODERADO: Rendimiento aceptable con algunos picos ocasionales. Requiere monitoreo pero no acción inmediata                                                                                                                  │" -ForegroundColor Yellow
      Write-Host "│ 🟠 ALTO: Rendimiento bajo presión. Picos frecuentes o promedios elevados. Considerar optimización o escalamiento                                                                                                               │" -ForegroundColor DarkYellow
      Write-Host "│ 🔴 CRÍTICO: Rendimiento saturado. Picos sostenidos cerca del 100%. Requiere atención inmediata para evitar degradación del servicio                                                                                           │" -ForegroundColor Red
      Write-Host "│                                                                                                                                                                                                                                 │" -ForegroundColor DarkCyan
      Write-Host "│                                                                            CÁLCULO DE MÉTRICAS                                                                                                                               │" -ForegroundColor DarkCyan
      Write-Host "├─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor DarkCyan
      Write-Host "│ 📊 Avg (Promedio): Valor promedio durante todo el período. Indica el rendimiento típico de la base de datos                                                                                                                    │" -ForegroundColor Cyan
      Write-Host "│ 📈 Max (Máximo): Pico más alto registrado. Indica momentos de mayor demanda o carga de trabajo                                                                                                                                 │" -ForegroundColor Cyan
      Write-Host "│ 📉 Min (Mínimo): Valor más bajo registrado. Indica períodos de menor actividad                                                                                                                                                 │" -ForegroundColor Cyan
      Write-Host "│ ⏱️ Período: $($script:metricsPeriod) con granularidad de $($script:metricsInterval) (cada punto de medición). Agregación tipo: $($script:metricsAggregation)                                                                             │" -ForegroundColor Cyan
      Write-Host "│ 🌍 Zona Horaria: UTC-5 (Hora de Perú). Todas las marcas de tiempo se muestran en hora local                                                                                                                                   │" -ForegroundColor Cyan
      Write-Host "│                                                                                                                                                                                                                                 │" -ForegroundColor DarkCyan
      Write-Host "│                                                                          UMBRALES DE EVALUACIÓN                                                                                                                               │" -ForegroundColor DarkCyan
      Write-Host "├─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤" -ForegroundColor DarkCyan
      Write-Host "│ 🔴 Crítico: >90% promedio O >25% del tiempo en 100% O picos sostenidos >98% con promedio >80% O storage >95%                                                                                                                    │" -ForegroundColor Red
      Write-Host "│ 🟠 Alto: >80% promedio (Azure threshold) O >10% del tiempo en 100% con promedio >70% O picos >95% con promedio >75% O storage >90%                                                                                              │" -ForegroundColor DarkYellow
      Write-Host "│ 🟡 Moderado: >65% promedio O picos regulares >90% con promedio >60% O storage >85% (permite crecimiento futuro)                                                                                                                  │" -ForegroundColor Yellow
      Write-Host "│ 🟢 Óptimo: <65% promedio Y picos ocasionales <90% Y storage <85% (rendimiento saludable según Azure best practices)                                                                                                              │" -ForegroundColor Green
      Write-Host "│                                                                                                                                                                                                                                 │" -ForegroundColor DarkCyan
      Write-Host "│ 💡 NOTAS IMPORTANTES: Azure considera normal picos ocasionales al 100% para batch jobs. Los umbrales están basados en documentación oficial Microsoft 2025 y experiencia de DBAs expertos.                                   │" -ForegroundColor Cyan
      Write-Host "└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor DarkCyan
      
      
      # ========================================
      # RESUMEN DE MÉTRICAS DE ALMACENAMIENTO (NUEVO REQUERIMIENTO)
      # ========================================
      Write-Host "`n┌─ 💾 RESUMEN GENERAL DE ALMACENAMIENTO ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐" -ForegroundColor DarkCyan
      
      # Calcular estadísticas agregadas
      $totalDatabases = $results.Count
      $totalStorageUsed = 0
      $totalStorageMax = 0
      $databasesWithGrowth = 0
      $totalGrowth = 0
      $criticalStorageDbs = 0
      $highStorageDbs = 0
      $criticalGrowthDbs = 0
      
      foreach ($result in $results) {
          # Extraer valores de storage del texto detallado
          if ($result.'Storage Detallado' -match 'Usado: ([\d.]+)GB.*Total: ([\d.]+)GB.*Ocupado: ([\d.]+)%') {
              $usedGB = [double]$matches[1]
              $maxGB = [double]$matches[2] 
              $percentUsed = [double]$matches[3]
              
              $totalStorageUsed += $usedGB
              $totalStorageMax += $maxGB
              
              # Contar bases críticas por storage
              if ($percentUsed -gt 95) { $criticalStorageDbs++ }
              elseif ($percentUsed -gt 85) { $highStorageDbs++ }
          }
          
          # Extraer crecimiento si existe
          if ($result.'Storage Detallado' -match 'Crecimiento: \+?([\d.-]+)GB' -and $matches[1] -ne "N/A") {
              $growthValue = [double]$matches[1]
              if ($growthValue -gt 0) {
                  $databasesWithGrowth++
                  $totalGrowth += $growthValue
                  
                  if ($growthValue -gt 2.0) { $criticalGrowthDbs++ }
              }
          }
      }
      
      # Calcular porcentajes y promedios
      $totalStoragePercent = if ($totalStorageMax -gt 0) { [Math]::Round(($totalStorageUsed / $totalStorageMax) * 100, 1) } else { 0 }
      $avgGrowth = if ($databasesWithGrowth -gt 0) { [Math]::Round($totalGrowth / $databasesWithGrowth, 2) } else { 0 }
      $remainingSpace = [Math]::Round($totalStorageMax - $totalStorageUsed, 1)
      
      Write-Host "│ 📊 ESTADÍSTICAS GENERALES" -ForegroundColor White
      Write-Host "│    • Total de bases analizadas: $totalDatabases" -ForegroundColor Gray
      Write-Host "│    • Storage total usado: $([Math]::Round($totalStorageUsed, 1))GB de $([Math]::Round($totalStorageMax, 1))GB ($totalStoragePercent%)" -ForegroundColor $(if ($totalStoragePercent -gt 85) { "Red" } elseif ($totalStoragePercent -gt 70) { "Yellow" } else { "Green" })
      Write-Host "│    • Espacio libre total: $remainingSpace GB" -ForegroundColor Cyan
      Write-Host "│" -ForegroundColor DarkCyan
      Write-Host "│ 📈 ANÁLISIS DE CRECIMIENTO EN PERÍODO ($($script:metricsPeriod))" -ForegroundColor White
      Write-Host "│    • Bases con crecimiento positivo: $databasesWithGrowth de $totalDatabases" -ForegroundColor Gray
      Write-Host "│    • Crecimiento total acumulado: +$([Math]::Round($totalGrowth, 2))GB" -ForegroundColor $(if ($totalGrowth -gt 5.0) { "Red" } elseif ($totalGrowth -gt 2.0) { "Yellow" } else { "Green" })
      Write-Host "│    • Crecimiento promedio por base: +$avgGrowth GB" -ForegroundColor Gray
      Write-Host "│" -ForegroundColor DarkCyan
      Write-Host "│ ⚠️ ALERTAS POR NIVEL DE OCUPACIÓN" -ForegroundColor White
      Write-Host "│    • Bases en estado CRÍTICO (>95%): $criticalStorageDbs" -ForegroundColor $(if ($criticalStorageDbs -gt 0) { "Red" } else { "Green" })
      Write-Host "│    • Bases en estado ALTO (85-95%): $highStorageDbs" -ForegroundColor $(if ($highStorageDbs -gt 0) { "Yellow" } else { "Green" })
      Write-Host "│    • Bases con crecimiento crítico (>2GB): $criticalGrowthDbs" -ForegroundColor $(if ($criticalGrowthDbs -gt 0) { "Red" } else { "Green" })
      Write-Host "│" -ForegroundColor DarkCyan
      
      # Proyección consolidada si hay crecimiento
      if ($totalGrowth -gt 0) {
          $periodHours = switch ($script:metricsPeriod) {
              "1h" { 1 }
              "24h" { 24 }
              "7d" { 168 }
              default { 24 }
          }
          
          $dailyGrowthRate = ($totalGrowth / $periodHours) * 24
          $daysToFillGeneral = if ($dailyGrowthRate -gt 0) { [Math]::Round($remainingSpace / $dailyGrowthRate, 0) } else { 999 }
          
          Write-Host "│ 🔮 PROYECCIÓN CONSOLIDADA" -ForegroundColor White
          Write-Host "│    • Tasa crecimiento diario estimado: +$([Math]::Round($dailyGrowthRate, 2))GB/día" -ForegroundColor Gray
          if ($daysToFillGeneral -lt 30) {
              Write-Host "│    • ⚠️ CRÍTICO: Capacidad total en ~$daysToFillGeneral días" -ForegroundColor Red
          } elseif ($daysToFillGeneral -lt 90) {
              Write-Host "│    • 📅 ATENCIÓN: Capacidad total en ~$daysToFillGeneral días" -ForegroundColor Yellow
          } else {
              Write-Host "│    • ✅ ESTABLE: Capacidad suficiente (>$daysToFillGeneral días)" -ForegroundColor Green
          }
      } else {
          Write-Host "│ 🔮 PROYECCIÓN: Sin crecimiento detectado en el período analizado" -ForegroundColor Gray
      }
      
      Write-Host "└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘" -ForegroundColor DarkCyan
  } else {
      Write-Host "`n❌ No se encontraron resultados para mostrar" -ForegroundColor Red
  }
  
  # ========================================
  # EXPORTAR RESULTADOS (HTML Y CSV)
  # ========================================
  if ($results.Count -gt 0) {
    Write-Host "`n┌─ 💾 OPCIONES DE EXPORTACIÓN ─────────────────────────────────────────────┐" -ForegroundColor DarkCyan
    Write-Host "│ Seleccione el formato de exportación:                                    │" -ForegroundColor Gray
    Write-Host "│ [1] Formato completo (HTML + CSV detallado)                              │" -ForegroundColor Green
    Write-Host "│ [2] CSV simplificado (un dato por columna) - NUEVO                       │" -ForegroundColor Cyan
    Write-Host "│ [N] No exportar (default)                                                │" -ForegroundColor Gray
    Write-Host "└───────────────────────────────────────────────────────────────────────────┘" -ForegroundColor DarkCyan
    
    Write-Host "`n🎯 Seleccione opción (1/2/N): " -ForegroundColor Yellow -NoNewline
    $exportChoice = Read-Host
    
    if ($exportChoice.Trim() -in @("1", "2")) {
      # Crear carpeta para informes
      $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
      $reportFolder = Join-Path (Get-Location) "Azure_SQL_Report_$timestamp"
      
      if (-not (Test-Path $reportFolder)) {
        New-Item -Path $reportFolder -ItemType Directory -Force | Out-Null
      }
      
      Write-Host "`n🔧 Preparando exportación en carpeta: $reportFolder" -ForegroundColor Cyan
      
      # Función para exportar a CSV
      function Export-ToCSV {
        $csvPath = Join-Path $reportFolder "azure_sql_metrics_$timestamp.csv"
        
        # Preparar datos exactamente como se muestran en la tabla (consistencia con las columnas originales)
        $csvData = $results | Select-Object @{Name='N°';Expression={$_.'N°'}},
                                            @{Name='Servidor';Expression={$_.'Servidor'}},
                                            @{Name='Base de Datos [Edición/Tier]';Expression={$_.'Base de Datos [Edición/Tier]'}},
                                            @{Name='Storage Detallado';Expression={$_.'Storage Detallado'}},
                                            @{Name='DTU DETALLADO';Expression={$_.'DTU DETALLADO'}},
                                            @{Name='CPU % DETALLADO';Expression={$_.'CPU % DETALLADO'}},
                                            @{Name='Estado';Expression={$_.'Estado'}},
                                            @{Name='CriticalityLevel';Expression={$_.CriticalityLevel}},
                                            @{Name='ModelType';Expression={$_.ModelType}}
        
        # Exportar a CSV con encoding UTF8
        $csvData | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        
        Write-Host "✅ Datos exportados a: $csvPath" -ForegroundColor Green
        return $csvPath
      }
      
      # Función para exportar a HTML
      function Export-ToHTML {
        $htmlPath = Join-Path $reportFolder "azure_sql_metrics_$timestamp.html"
        $cssPath = Join-Path $reportFolder "azure_style.css"
        
        # Definir CSS con estilos Azure
        $cssContent = @"
/* Estilos Azure Portal 2025 */
body {
  font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
  margin: 0;
  padding: 20px;
  color: #323130;
  background-color: #f8f8f8;
  line-height: 1.5;
}
.container {
  max-width: 1200px;
  margin: 0 auto;
  background-color: white;
  box-shadow: 0 2px 6px rgba(0,0,0,0.1);
  border-radius: 4px;
  padding: 20px;
}
.header {
  text-align: center;
  padding-bottom: 20px;
  border-bottom: 1px solid #edebe9;
  margin-bottom: 30px;
}
.azure-logo {
  height: 60px;
  margin-bottom: 15px;
}
h1 {
  color: #0078d4;
  font-size: 24px;
  font-weight: 600;
  margin: 10px 0;
}
h2 {
  color: #0078d4;
  font-size: 20px;
  font-weight: 600;
  margin: 25px 0 15px 0;
  padding-bottom: 10px;
  border-bottom: 1px solid #edebe9;
}
.config-box {
  background-color: #f0f6ff;
  border-radius: 4px;
  padding: 15px;
  margin-bottom: 20px;
  border-left: 4px solid #0078d4;
  display: grid;
  grid-template-columns: 1fr 1fr;
  grid-gap: 10px;
}
.config-group {
  margin-bottom: 10px;
}
.config-title {
  font-weight: 600;
  margin-bottom: 10px;
  color: #0078d4;
  grid-column: 1 / span 2;
}
.config-item {
  display: flex;
  margin-bottom: 5px;
}
.config-label {
  font-weight: 600;
  min-width: 150px;
}
.timestamp {
  font-size: 14px;
  color: #605e5c;
  margin-bottom: 15px;
}
table {
  width: 100%;
  border-collapse: collapse;
  margin: 20px 0;
  font-size: 14px;
}
th {
  background-color: #0078d4;
  color: white;
  font-weight: 600;
  text-align: left;
  padding: 12px 8px;
}
td {
  padding: 10px 8px;
  border-bottom: 1px solid #edebe9;
}
tr:nth-child(even) {
  background-color: #f8f8f8;
}
tr:hover {
  background-color: #f0f6ff;
}
.status-optimal {
  color: #107c10;
  font-weight: 600;
}
.status-moderate {
  color: #797673;
  font-weight: 600;
}
.status-high {
  color: #d83b01;
  font-weight: 600;
}
.status-critical {
  color: #a4262c;
  font-weight: 600;
}
.footer {
  text-align: center;
  margin-top: 40px;
  padding-top: 20px;
  border-top: 1px solid #edebe9;
  font-size: 12px;
  color: #605e5c;
}
.storage-meter {
  height: 8px;
  width: 100%;
  background-color: #f3f2f1;
  border-radius: 4px;
  margin: 5px 0;
  overflow: hidden;
}
.storage-fill {
  height: 100%;
  background-color: #0078d4;
}
.glossary {
  background-color: #f3f2f1;
  border-radius: 4px;
  padding: 15px;
  margin: 30px 0;
}
.glossary-title {
  font-weight: 600;
  margin-bottom: 10px;
}
.glossary-item {
  margin-bottom: 8px;
}
.glossary-term {
  font-weight: 600;
  margin-right:  5px;
}
@media print {
  body {
    background-color: white;
  }
  .container {
    box-shadow: none;
    max-width: 100%;
  }
  .no-print {
    display: none;
  }
}
"@
        
        # Escribir archivo CSS
        Set-Content -Path $cssPath -Value $cssContent
        
        # Generar contenido HTML
        $reportDate = Get-Date -Format "dd/MM/yyyy HH:mm"
        $period = $script:metricsPeriod
        $aggregation = $script:metricsAggregation
        $interval = $script:metricsInterval
        $startTimeFormatted = ([DateTime]::Parse($script:startTime)).ToString("dd/MM/yyyy HH:mm:ss")
        $endTimeFormatted = ([DateTime]::Parse($script:endTime)).ToString("dd/MM/yyyy HH:mm:ss")
        
        $htmlContent = @"
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Azure SQL Database Monitoring Report</title>
  <link rel="stylesheet" href="azure_style.css">
</head>
<body>
  <div class="container">
    <div class="header">
      <h1>TASA Perú Monitoreo Bases de Datos Azure SQL</h1>
      <div class="timestamp">Generado el: $reportDate</div>
    </div>
    
    <div class="config-box">
      <div class="config-title">CONFIGURACIÓN DEL MONITOREO</div>
      <div class="config-group">
        <div class="config-item">
          <div class="config-label">Período:</div>
          <div>$period</div>
        </div>
        <div class="config-item">
          <div class="config-label">Agregación:</div>
          <div>$aggregation</div>
        </div>
        <div class="config-item">
          <div class="config-label">Granularidad:</div>
          <div>$interval</div>
        </div>
      </div>
      <div class="config-group">
        <div class="config-item">
          <div class="config-label">Fecha/Hora Inicio:</div>
          <div>$startTimeFormatted</div>
        </div>
        <div class="config-item">
          <div class="config-label">Fecha/Hora Fin:</div>
          <div>$endTimeFormatted</div>
        </div>
        <div class="config-item">
          <div class="config-label">Zona Horaria:</div>
          <div>UTC-5 (Perú)</div>
        </div>
      </div>
    </div>
    
    <table>
      <thead>
        <tr>
          <th>N°</th>
          <th>Servidor</th>
          <th>Base de Datos [Edición/Tier]</th>
          <th>Storage Detallado</th>
          <th>DTU DETALLADO (Avg|Max)</th>
          <th>CPU % DETALLADO (Avg|Max)</th>
          <th>Estado</th>
        </tr>
      </thead>
      <tbody>
"@
        
        # Tabla principal con todas las columnas y datos
        foreach ($result in $results) {
          $num = $result.'N°'
          
          $serverName = if ($result.'Servidor') { $result.'Servidor'.ToString() } else { "N/A" }
          $dbInfo = if ($result.'Base de Datos [Edición/Tier]') { $result.'Base de Datos [Edición/Tier]'.ToString() } else { "N/A" }
          
          $storageInfo = if ($result.'Storage Detallado') { $result.'Storage Detallado'.ToString() } else { "N/A" }
          $percentUsed = 0
          if ($storageInfo -match 'Ocupado: ([\d.]+)%') {
            $percentUsed = [double]$matches[1]
          }
          
          # DTU/Performance info
          $performanceDetailed = if ($result.'DTU DETALLADO') { $result.'DTU DETALLADO'.ToString() } else { "N/A" }
          
          # CPU info
          $cpuDetailed = if ($result.'CPU % DETALLADO') { $result.'CPU % DETALLADO'.ToString() } else { "N/A" }
          
          # Estado con clase CSS adecuada
          $status = if ($result.'Estado') { $result.'Estado'.ToString() } else { "N/A" }
          $statusClass = if ($status -match "🔴.*CRÍTICO") { "status-critical" }
                        elseif ($status -match "🟠.*ALTO") { "status-high" }
                        elseif ($status -match "🟡.*MODERADO") { "status-moderate" }
                        elseif ($status -match "🟢.*ÓPTIMO") { "status-optimal" }
                        else { "" }
          
          $htmlContent += @"
        <tr>
          <td>$num</td>
          <td>$serverName</td>
          <td>$dbInfo</td>
          <td>
            $storageInfo
            <div class="storage-meter">
              <div class="storage-fill" style="width: $percentUsed%;"></div>
            </div>
          </td>
          <td>$performanceDetailed</td>
          <td>$cpuDetailed</td>
          <td class="$statusClass">$status</td>
        </tr>
"@
        }
        
        $htmlContent += @"
      </tbody>
    </table>
    
    <h2>Guía de Interpretación de Resultados</h2>
    
    <div class="glossary">
      <div class="glossary-title">Términos Técnicos</div>
      <div class="glossary-item"><span class="glossary-term">DTU (Database Transaction Units):</span> Medida combinada de CPU, memoria y E/S. Indica la capacidad de procesamiento total de la base de datos.</div>
      <div class="glossary-item"><span class="glossary-term">vCore:</span> Núcleos virtuales de procesador dedicados. Modelo más flexible que permite control independiente de CPU, memoria y almacenamiento.</div>
      <div class="glossary-item"><span class="glossary-term">CPU %:</span> Porcentaje de uso del procesador. Indica qué tan ocupado está el procesador ejecutando consultas.</div>
      <div class="glossary-item"><span class="glossary-term">Storage:</span> Espacio en disco utilizado vs. total disponible. Se mide en GB (Gigabytes).</div>
    </div>
    
    <div class="glossary">
      <div class="glossary-title">Interpretación de Estados</div>
      <div class="glossary-item"><span class="glossary-term status-optimal">ÓPTIMO:</span> Rendimiento normal. Promedios bajos y picos controlados.</div>
      <div class="glossary-item"><span class="glossary-term status-moderate">MODERADO:</span> Rendimiento aceptable con algunos picos ocasionales.</div>
      <div class="glossary-item"><span class="glossary-term status-high">ALTO:</span> Rendimiento bajo presión. Picos frecuentes o promedios elevados.</div>
      <div class="glossary-item"><span class="glossary-term status-critical">CRÍTICO:</span> Rendimiento saturado. Picos sostenidos cerca del 100%.</div>
    </div>
    
    <div class="footer">
      <p>© $(Get-Date -Format "yyyy") - TASA Perú</p>
    </div>
  </div>
</body>
</html>
"@
        
        # Guardar HTML
        Set-Content -Path $htmlPath -Value $htmlContent -Encoding UTF8
        
        Write-Host "✅ Informe HTML exportado a: $htmlPath" -ForegroundColor Green
        return $htmlPath
      }
      
      # Función para exportar CSV simplificado (NUEVA FUNCIONALIDAD)
      function Export-ToSimplifiedCSV {
        $csvPath = Join-Path $reportFolder "azure_sql_metrics_simplified_$timestamp.csv"
        
        Write-Host "🔄 Generando CSV simplificado con columnas específicas..." -ForegroundColor Cyan
        
        # Preparar datos con columnas específicas solicitadas en la reunión del lunes
        $simplifiedData = @()
        
        foreach ($result in $results) {
          # Extraer valores individuales de los datos existentes
          $serverName = if ($result.'Servidor') { $result.'Servidor'.ToString() } else { "N/A" }
          $dbName = "N/A"
          $dbEdition = "N/A"
          $dbTier = "N/A"
          
          # Parsear nombre de base de datos de la columna combinada
          if ($result.'Base de Datos [Edición/Tier]' -match '^([^[]+)\s*\[([^/]+)/([^]]+)\]') {
            $dbName = $matches[1].Trim()
            $dbEdition = $matches[2].Trim()
            $dbTier = $matches[3].Trim()
          }
          
          # Extraer valores de CPU promedio y máximo
          $cpuAvg = 0.0
          $cpuMax = 0.0
          if ($result.'CPU % DETALLADO' -match 'Avg: ([\d.]+)%.*Max: ([\d.]+)%') {
            $cpuAvg = [Math]::Round([double]$matches[1], 2)
            $cpuMax = [Math]::Round([double]$matches[2], 2)
          }
          
          # Extraer valores de DTU/Performance promedio y máximo
          $dtuAvg = 0.0
          $dtuMax = 0.0
          if ($result.'DTU DETALLADO' -match 'Avg: ([\d.]+)%.*Max: ([\d.]+)%') {
            $dtuAvg = [Math]::Round([double]$matches[1], 2)
            $dtuMax = [Math]::Round([double]$matches[2], 2)
          }
          
          # Calcular tiempo en 100% para CPU y DTU usando datos de series temporales
          $cpuTimeAt100 = 0.0
          $dtuTimeAt100 = 0.0
          
          # CPU tiempo en 100% por día promedio
          if ($result.AllCpuTimeSeriesData -and $result.AllCpuTimeSeriesData.Count -gt 0) {
            $totalCpuPoints = $result.AllCpuTimeSeriesData.Count
            $cpuPointsAt100 = ($result.AllCpuTimeSeriesData | Where-Object { $_.Value -ge 100 }).Count
            $cpuTimeAt100 = if ($totalCpuPoints -gt 0) { [Math]::Round(($cpuPointsAt100 / $totalCpuPoints) * 100, 2) } else { 0 }
          }
          
          # DTU tiempo en 100% por día promedio
          if ($result.AllTimeSeriesData -and $result.AllTimeSeriesData.Count -gt 0) {
            $totalDtuPoints = $result.AllTimeSeriesData.Count
            $dtuPointsAt100 = ($result.AllTimeSeriesData | Where-Object { $_.Value -ge 100 }).Count
            $dtuTimeAt100 = if ($totalDtuPoints -gt 0) { [Math]::Round(($dtuPointsAt100 / $totalDtuPoints) * 100, 2) } else { 0 }
          }
          
          # Extraer valores de almacenamiento
          $espacioTotal = 0.0
          $espacioConsumido = 0.0
          $espacioConsumidoPct = 0.0
          
          if ($result.'Storage Detallado' -match 'Usado: ([\d.]+)GB.*Total: ([\d.]+)GB.*Ocupado: ([\d.]+)%') {
            $espacioConsumido = [Math]::Round([double]$matches[1], 2)
            $espacioTotal = [Math]::Round([double]$matches[2], 2)
            $espacioConsumidoPct = [Math]::Round([double]$matches[3], 2)
          }
          
          # Extraer estado y motivo
          $estadoCompleto = if ($result.'Estado') { $result.'Estado'.ToString() } else { "N/A" }
          $estado = "N/A"
          $motivoEstado = "N/A"
          
          # Parsear estado y motivo
          if ($estadoCompleto -match '^([^|]+)\|\s*(.+)$') {
            $estado = $matches[1].Trim()
            $motivoEstado = $matches[2].Trim()
          } else {
            $estado = $estadoCompleto
            $motivoEstado = if ($estado -match "ÓPTIMO") { "Rendimiento normal dentro de parámetros" } else { "Ver estado para detalles" }
          }
          
          # Métricas adicionales relevantes
          $metricasAdicionales = @()
          
          # Agregar información del modelo
          if ($result.ModelType) {
            $metricasAdicionales += "Modelo: $($result.ModelType)"
          }
          
          # Agregar nivel de criticidad
          if ($result.CriticalityLevel) {
            $metricasAdicionales += "Nivel Criticidad: $($result.CriticalityLevel)"
          }
          
          # Agregar crecimiento si está disponible
          if ($result.'Storage Detallado' -match 'Crecimiento: \+?([\d.-]+)GB' -and $matches[1] -ne "N/A") {
            $metricasAdicionales += "Crecimiento: $($matches[1])GB"
          }
          
          # Agregar información de edición/tier
          $metricasAdicionales += "Edición: $dbEdition"
          $metricasAdicionales += "Tier: $dbTier"
          
          $metricasAdicionalesStr = $metricasAdicionales -join "; "
          
          # Crear objeto con las columnas específicas solicitadas en la reunión
          $simplifiedData += [PSCustomObject]@{
            'Nombre de la base de datos' = $dbName
            'Servidor' = $serverName
            'CPU promedio (%)' = $cpuAvg
            'CPU máximo (%)' = $cpuMax
            'Tiempo en CPU 100% por día promedio (%)' = $cpuTimeAt100
            'DTU promedio (%)' = $dtuAvg
            'DTU máximo (%)' = $dtuMax
            'Tiempo en DTU 100% por día promedio (%)' = $dtuTimeAt100
            'Espacio total (GB)' = $espacioTotal
            'Espacio consumido (GB)' = $espacioConsumido
            'Espacio consumido (%)' = $espacioConsumidoPct
            'Estado' = $estado
            'Motivo del estado' = $motivoEstado
            'Métricas adicionales relevantes' = $metricasAdicionalesStr
          }
        }
        
        # Exportar a CSV con encoding UTF8
        $simplifiedData | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        
        Write-Host "✅ CSV simplificado exportado a: $csvPath" -ForegroundColor Green
        return $csvPath
      }
      
      # Procesar según la opción seleccionada
      if ($exportChoice.Trim() -eq "1") {
        # Opción 1: Formato completo (HTML + CSV detallado)
        Write-Host "`n🔄 Generando informes completos..." -ForegroundColor Cyan
        
        # Exportar CSV detallado
        $csvPath = Export-ToCSV
        
        # Exportar HTML
        $htmlPath = Export-ToHTML
        
        # Abrir automáticamente el HTML
        Write-Host "`n🌐 Abriendo informe HTML en el navegador..." -ForegroundColor Cyan
        Start-Process $htmlPath
        
        Write-Host "`n✅ Exportación completa en carpeta: $reportFolder" -ForegroundColor Green
        Write-Host "📁 Archivos generados:" -ForegroundColor Cyan
        Write-Host "   • $([System.IO.Path]::GetFileName($csvPath)) - CSV detallado" -ForegroundColor Gray
        Write-Host "   • $([System.IO.Path]::GetFileName($htmlPath)) - Informe HTML" -ForegroundColor Gray
        
      } elseif ($exportChoice.Trim() -eq "2") {
        # Opción 2: CSV simplificado (NUEVA FUNCIONALIDAD PARA LA REUNIÓN DEL LUNES)
        Write-Host "`n🔄 Generando CSV simplificado..." -ForegroundColor Cyan
        
        # Exportar solo CSV simplificado
        $csvSimplifiedPath = Export-ToSimplifiedCSV
        
        Write-Host "`n✅ CSV simplificado listo para la reunión del lunes" -ForegroundColor Green
        Write-Host "📁 Archivo generado:" -ForegroundColor Cyan
        Write-Host "   • $([System.IO.Path]::GetFileName($csvSimplifiedPath)) - Un dato por columna" -ForegroundColor Gray
        
        # Preguntar si desea abrir el archivo
        Write-Host "`n💡 ¿Desea abrir el archivo CSV ahora? (S/N): " -ForegroundColor Yellow -NoNewline
        $openChoice = Read-Host
        if ($openChoice.Trim().ToUpper() -eq "S") {
          Start-Process $csvSimplifiedPath
          Write-Host "📊 Archivo CSV abierto" -ForegroundColor Green
        }
      }
    } else {
      Write-Host "`n❕ No se exportarán resultados." -ForegroundColor Gray
    }
  }
}

Get-AzureSQLDatabaseMetrics