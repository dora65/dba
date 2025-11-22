# ========================================================================
# build.ps1 - Script para compilar Markdown a PDF con Pandoc + XeTeX
# Windows 11 + PowerShell 5.1+ | MiKTeX 25.4 + Pandoc 3.6.4 + XeTeX 4.15
# ========================================================================
# DESCRIPCION:
# Este script compila archivos Markdown a PDF usando Pandoc y XeTeX,
# con soporte para metadatos, filtros Lua, y opciones avanzadas de TeX.
#
# USO:
#   .\build.ps1 -InputFile documento.md
#   .\build.ps1 -InputFile documento.md -OutputFile documento.pdf
#   .\build.ps1 -InputFile documento.md -Dark
#   .\build.ps1 -InputFile documento.md -Premium (metadata de excelencia)
#   .\build.ps1 -InputFile documento.md -Metadata .pandoc\metadata-premium.yaml
# ========================================================================

param(
    [string]$InputFile = "",
    [string]$OutputFile = "",
    [string]$Metadata = ".pandoc\metadata-gruvbox-medium.yaml",
    [switch]$Dark,
    [switch]$Premium,
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Colores para salida
$colors = @{
    'Success' = 'Green'
    'Error'   = 'Red'
    'Warning' = 'Yellow'
    'Info'    = 'Cyan'
    'Step'    = 'Magenta'
}

# ========================================================================
# FUNCIONES AUXILIARES
# ========================================================================

function Write-Log {
    param([string]$Message, [string]$Type = "Info")
    
    $color = if ($colors.ContainsKey($Type)) { $colors[$Type] } else { 'White' }
    $timestamp = Get-Date -Format "HH:mm:ss"
    $icon = switch ($Type) {
        'Success' { '[+]' }
        'Error'   { '[-]' }
        'Warning' { '[!]' }
        'Step'    { '[>]' }
        default   { '[*]' }
    }
    
    Write-Host "[$timestamp] $icon " -NoNewline -ForegroundColor $color
    Write-Host $Message -ForegroundColor $color
}

function Test-Prerequisites {
    Write-Log "Verificando requisitos..." "Step"
    
    $tools = @('pandoc', 'xelatex', 'miktex')
    $missing = @()
    
    foreach ($tool in $tools) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            $missing += $tool
            Write-Log "$tool NO ENCONTRADO" "Error"
        } else {
            Write-Log "$tool encontrado" "Success"
        }
    }
    
    if ($missing.Count -gt 0) {
        Write-Log "Faltan herramientas: $($missing -join ', ')" "Error"
        exit 1
    }
    
    Write-Log "Todos los requisitos instalados" "Success"
    Write-Host ""
}

function Resolve-Paths {
    if (-not $InputFile) {
        Write-Log "ERROR: Se requiere -InputFile" "Error"
        Write-Host "Uso: .\build.ps1 -InputFile documento.md [-OutputFile salida.pdf] [-Dark] [-Premium]" -ForegroundColor Yellow
        exit 1
    }
    
    if (-not (Test-Path $InputFile)) {
        Write-Log "ERROR: Archivo NO existe: $InputFile" "Error"
        exit 1
    }
    
    if (-not $OutputFile) {
        $OutputFile = [System.IO.Path]::ChangeExtension($InputFile, ".pdf")
    }
    
    if ($Premium) {
        $Metadata = ".pandoc\metadata-premium.yaml"
        Write-Log "Usando metadata PREMIUM (excelencia)" "Info"
    } elseif ($Dark) {
        $Metadata = ".pandoc\metadata-gruvbox-medium.yaml"
    }
    
    return @{
        InputFile = (Resolve-Path $InputFile).Path
        OutputFile = $OutputFile
        Metadata = $Metadata
    }
}

function Test-MetadataFile {
    param([string]$MetadataPath)
    
    if (-not (Test-Path $MetadataPath)) {
        Write-Log "ADVERTENCIA: Metadatos NO existen: $MetadataPath" "Warning"
        Write-Log "Se usaran opciones basicas" "Info"
        return $false
    }
    return $true
}

function Invoke-PandocCompilation {
    param(
        [string]$InputPath,
        [string]$OutputPath,
        [string]$MetadataPath,
        [bool]$HasMetadata
    )
    
    Write-Log "Compilando: $InputPath -> $OutputPath" "Step"
    Write-Host ""
    
    $pandocArgs = @(
        $InputPath,
        '--pdf-engine=xelatex',
        '--pdf-engine-opt=-no-shell-escape',
        '--pdf-engine-opt=-interaction=nonstopmode',
        '--standalone',
        '--dpi=300',
        '--wrap=auto',
        '--from=markdown+pipe_tables+grid_tables+multiline_tables+raw_html+strikeout+superscript+subscript+fenced_divs+bracketed_spans+definition_lists+latex_macros+tex_math_dollars',
        '-o', $OutputPath
    )
    
    if ($HasMetadata) {
        $pandocArgs += @('--metadata-file=' + $MetadataPath)
    }
    
    if ($Verbose) {
        Write-Log "Argumentos: $($pandocArgs -join ' ')" "Info"
    }
    
    try {
        $output = & pandoc @pandocArgs 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            Write-Log "ERROR: codigo $LASTEXITCODE" "Error"
            Write-Host $output
            exit 1
        }
        
        Write-Host ""
        Write-Log "Compilacion EXITOSA" "Success"
        
    } catch {
        Write-Log "ERROR: $_" "Error"
        exit 1
    }
}

function Verify-PDFOutput {
    param([string]$PDFPath)
    
    if (Test-Path $PDFPath) {
        $fileSize = (Get-Item $PDFPath).Length
        $fileSizeMB = [math]::Round($fileSize / 1MB, 2)
        Write-Log "PDF generado: $PDFPath ($fileSizeMB MB)" "Success"
        return $true
    } else {
        Write-Log "ERROR: No se genero el PDF" "Error"
        return $false
    }
}

function Show-CompletionSummary {
    param(
        [string]$SourceFile,
        [string]$DestFile,
        [timespan]$ElapsedTime
    )
    
    Write-Host ""
    Write-Host "=====================================================" -ForegroundColor Cyan
    Write-Host "          COMPILACION EXITOSA" -ForegroundColor Cyan
    Write-Host "=====================================================" -ForegroundColor Cyan
    Write-Host "Entrada:  $SourceFile" -ForegroundColor Cyan
    Write-Host "Salida:   $DestFile" -ForegroundColor Cyan
    Write-Host "Tiempo:   $([int]$ElapsedTime.TotalSeconds)s" -ForegroundColor Cyan
    Write-Host "=====================================================" -ForegroundColor Cyan
    Write-Host ""
}

# ========================================================================
# FUNCION PRINCIPAL
# ========================================================================

function Main {
    $startTime = Get-Date
    
    Write-Host ""
    Write-Host "=====================================================" -ForegroundColor Cyan
    Write-Host "  COMPILADOR PANDOC + XeTeX (Windows 11)" -ForegroundColor Cyan
    Write-Host "=====================================================" -ForegroundColor Cyan
    Write-Host ""
    
    Test-Prerequisites
    
    $paths = Resolve-Paths
    $hasMetadata = Test-MetadataFile $paths.Metadata
    
    Invoke-PandocCompilation $paths.InputFile $paths.OutputFile $paths.Metadata $hasMetadata
    
    if (Verify-PDFOutput $paths.OutputFile) {
        $duration = (Get-Date) - $startTime
        Show-CompletionSummary $paths.InputFile $paths.OutputFile $duration
        Write-Log "Completado sin errores" "Success"
        return 0
    } else {
        return 1
    }
}

exit (Main)
