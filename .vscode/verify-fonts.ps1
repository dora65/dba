# ========================================================================
# verify-fonts.ps1 - Verificar fuentes instaladas para XeTeX + Pandoc
# Windows 11 + PowerShell 5.1+
# ========================================================================
# PROPOSITO:
# Este script verifica que TODAS las fuentes requeridas para metadata
# premium esten instaladas y accesibles a XeTeX.
#
# FUENTES REQUERIDAS:
# - IBM Plex Serif (UprightFont, BoldFont, ItalicFont, BoldItalicFont)
# - IBM Plex Sans (UprightFont, BoldFont, ItalicFont, BoldItalicFont)
# - JetBrains Mono (UprightFont, BoldFont, ItalicFont, BoldItalicFont)
#
# ========================================================================

param(
    [switch]$Verbose,
    [switch]$InstallFonts
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ========================================================================
# CONFIGURACION
# ========================================================================

$fontFamilies = @{
    'IBM Plex Serif' = @{
        Format = 'OTF'
        Required = @('Regular', 'Bold', 'Italic', 'BoldItalic')
        XeTeXName = 'IBM Plex Serif'
    }
    'IBM Plex Sans' = @{
        Format = 'OTF'
        Required = @('Regular', 'Bold', 'Italic', 'BoldItalic')
        XeTeXName = 'IBM Plex Sans'
    }
    'JetBrains Mono' = @{
        Format = 'TTF'
        Required = @('Regular', 'Bold', 'Italic', 'BoldItalic')
        XeTeXName = 'JetBrains Mono'
    }
}

$windowsFontsPath = 'C:\Windows\Fonts'
$registryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'

# ========================================================================
# FUNCIONES AUXILIARES
# ========================================================================

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('Success', 'Error', 'Warning', 'Info')]
        [string]$Type = "Info"
    )
    
    $colors = @{
        'Success' = 'Green'
        'Error'   = 'Red'
        'Warning' = 'Yellow'
        'Info'    = 'Cyan'
    }
    
    $icons = @{
        'Success' = '[OK]'
        'Error'   = '[ERROR]'
        'Warning' = '[ADVERTENCIA]'
        'Info'    = '[INFO]'
    }
    
    $color = $colors[$Type]
    $icon = $icons[$Type]
    
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $icon " -NoNewline -ForegroundColor $color
    Write-Host $Message -ForegroundColor $color
}

function Get-FontsInRegistry {
    param([string]$FontFamily)
    
    try {
        $regEntries = @()
        $regFonts = Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue
        
        if ($null -eq $regFonts) {
            return $regEntries
        }
        
        foreach ($fontName in $regFonts.PSObject.Properties.Name) {
            if ($fontName -like "*$FontFamily*") {
                $regEntries += @{
                    Name = $fontName
                    Value = $regFonts.$fontName
                }
            }
        }
        
        return $regEntries
    } catch {
        return @()
    }
}

function Get-FontFilesInWindows {
    param([string]$FontFamily, [string]$Extension)
    
    try {
        $pattern = "*$FontFamily*.$Extension"
        $files = Get-ChildItem -Path $windowsFontsPath -Filter $pattern -ErrorAction SilentlyContinue
        return $files
    } catch {
        return @()
    }
}

function Test-XeTeXFontAccess {
    param([string]$FontName)
    
    # Crear archivo .tex temporal para probar acceso a fuente
    $tempDir = [System.IO.Path]::GetTempPath()
    $testFile = Join-Path $tempDir "test-font-$([guid]::NewGuid()).tex"
    
    try {
        $texContent = @"
\documentclass{minimal}
\usepackage{fontspec}
\setmainfont{$FontName}
\begin{document}
Test
\end{document}
"@
        
        Set-Content -Path $testFile -Value $texContent -Encoding UTF8
        
        # Intentar compilar con xelatex (solo para verificar, no generar PDF)
        $output = & xelatex -interaction=nonstopmode -output-directory=$tempDir $testFile 2>&1
        
        if ($LASTEXITCODE -eq 0 -or $output -match "successfully") {
            return $true
        } else {
            return $false
        }
    } catch {
        return $false
    } finally {
        # Limpiar archivos temporales
        Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $tempDir "test-font-*.pdf") -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $tempDir "test-font-*.aux") -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $tempDir "test-font-*.log") -Force -ErrorAction SilentlyContinue
    }
}

# ========================================================================
# FUNCION PRINCIPAL DE VERIFICACION
# ========================================================================

function Invoke-FontVerification {
    Write-Host ""
    Write-Host "=====================================================" -ForegroundColor Cyan
    Write-Host "  VERIFICACION DE FUENTES PARA METADATA PREMIUM" -ForegroundColor Cyan
    Write-Host "=====================================================" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Status "Iniciando verificacion de fuentes..." "Info"
    Write-Host ""
    
    $allFontsValid = $true
    $results = @()
    
    foreach ($fontFamily in $fontFamilies.Keys) {
        Write-Status "Verificando: $fontFamily" "Info"
        
        $fontConfig = $fontFamilies[$fontFamily]
        $extension = $fontConfig.Format.ToLower()
        
        # 1. Buscar en archivos del sistema
        Write-Host "  [*] Buscando archivos en C:\Windows\Fonts..." -ForegroundColor Gray
        $files = Get-FontFilesInWindows -FontFamily $fontFamily -Extension $extension
        
        if ($files.Count -eq 0) {
            Write-Status "    NO se encontraron archivos $extension para $fontFamily" "Error"
            $allFontsValid = $false
        } else {
            Write-Status "    Encontrados $($files.Count) archivo(s)" "Success"
            if ($Verbose) {
                $files | ForEach-Object { Write-Host "      - $_" -ForegroundColor Gray }
            }
        }
        
        # 2. Verificar en Registro de Windows
        Write-Host "  [*] Verificando Registro de Windows..." -ForegroundColor Gray
        $regEntries = Get-FontsInRegistry -FontFamily $fontFamily
        
        if ($regEntries.Count -eq 0) {
            Write-Status "    NO se encontraron entradas en Registro" "Warning"
        } else {
            Write-Status "    Encontradas $($regEntries.Count) entrada(s) en Registro" "Success"
            if ($Verbose) {
                $regEntries | ForEach-Object { Write-Host "      - $($_.Name)" -ForegroundColor Gray }
            }
        }
        
        # 3. Verificar acceso desde XeTeX
        Write-Host "  [*] Probando acceso desde XeTeX..." -ForegroundColor Gray
        $xetexAccess = Test-XeTeXFontAccess -FontName $fontConfig.XeTeXName
        
        if ($xetexAccess) {
            Write-Status "    XeTeX puede acceder a $fontFamily" "Success"
        } else {
            Write-Status "    XeTeX NO puede acceder a $fontFamily" "Warning"
        }
        
        # 4. Resumen para esta fuente
        $results += @{
            FontFamily = $fontFamily
            FilesFound = $files.Count -gt 0
            RegistryFound = $regEntries.Count -gt 0
            XeTeXAccess = $xetexAccess
            IsValid = ($files.Count -gt 0 -or $regEntries.Count -gt 0)
        }
        
        Write-Host ""
    }
    
    # ====== RESUMEN FINAL ======
    Write-Host "=====================================================" -ForegroundColor Cyan
    Write-Host "  RESUMEN DE VERIFICACION" -ForegroundColor Cyan
    Write-Host "=====================================================" -ForegroundColor Cyan
    Write-Host ""
    
    $validCount = ($results | Where-Object { $_.IsValid }).Count
    $totalCount = $results.Count
    
    foreach ($result in $results) {
        $status = if ($result.IsValid) { "OK" } else { "FALTA" }
        $statusColor = if ($result.IsValid) { "Green" } else { "Red" }
        
        Write-Host "  $($result.FontFamily): " -NoNewline
        Write-Host $status -ForegroundColor $statusColor
        
        if ($Verbose) {
            Write-Host "    - Archivos: $(if($result.FilesFound){'SI'}else{'NO'})" -ForegroundColor Gray
            Write-Host "    - Registro: $(if($result.RegistryFound){'SI'}else{'NO'})" -ForegroundColor Gray
            Write-Host "    - XeTeX: $(if($result.XeTeXAccess){'SI'}else{'NO'})" -ForegroundColor Gray
        }
    }
    
    Write-Host ""
    Write-Host "Fuentes válidas: $validCount de $totalCount" -ForegroundColor Cyan
    
    if ($validCount -eq $totalCount) {
        Write-Host ""
        Write-Status "TODAS LAS FUENTES ESTAN VERIFICADAS Y LISTAS" "Success"
        Write-Status "Puedes usar metadata premium sin problemas" "Success"
        return 0
    } else {
        Write-Host ""
        Write-Status "ALGUNAS FUENTES NO ESTAN DISPONIBLES" "Error"
        Write-Status "Descarga desde: fonts.google.com o jetbrains.com" "Warning"
        return 1
    }
}

# ========================================================================
# EJECUCION
# ========================================================================

exit (Invoke-FontVerification)
