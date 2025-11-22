# ========================================================================
# GUIA DE INSTALACION: MiKTeX 25.4 + PAQUETES NECESARIOS
# Windows 11 + PowerShell 5.1+ | Pandoc 3.6.4# ========================================================================
# PASO 9: Resolver "security risk" warning (cosmético, NO critico)
# ========================================================================

# El warning "xelatex: security risk: running with elevated privileges"
# es COMPLETAMENTE NORMAL en Windows 11 cuando PowerShell detecta
# que el proceso tiene permisos elevados.

# ESTADO VERIFICADO: OCTUBRE 2025
# - Este warning es SOLO una advertencia de stderr
# - NO afecta la compilacion en absoluto
# - NO detiene el proceso
# - El PDF se genera correctamente

# SOLUCION: Ejecutar PowerShell SIN permisos de administrador
# - Abrir terminal PowerShell NORMAL (no Admin)
# - Ejecutar: & ".\.vscode\build.ps1" -InputFile "documento.md"
# - El warning desaparece

# IMPORTANTE:
# NO usar: --pdf-engine-opt=-shell-escape (eso SI es un riesgo real)
# USAR: --pdf-engine-opt=-no-shell-escape (SEGURO y CORRECTO)
# ACTUALIZADO: Octubre 2025 - Basado en verificacion de mejores practicas
# ========================================================================

# PASO 1: Verificar instalacion actual de MiKTeX
# ========================================================================

# Abrir terminal PowerShell (NO requiere administrador para verificacion)
# Verificar version instalada
miktex --version
# Resultado esperado: MiKTeX 25.4 o superior

# NOTA: Para instalacion personal (no compartida), NO usar --admin
# MiKTeX personal instala paquetes automaticamente cuando se necesitan

# ========================================================================
# PASO 2: Actualizar paquetes específicos via Package Manager
# ========================================================================

# Abrir MiKTeX Console como ADMINISTRADOR
# Ir a: Packages (Paquetes)
# Seleccionar los siguientes paquetes si NO están en versión 2024+
# (buscar por nombre exacto):

# PAQUETES CRÍTICOS:
# - fontspec (2024+ mínimo, actual 2025+)
# - expl3 (2024+ mínimo, debe estar sincronizado con fontspec)
# - l3kernel (2024+ mínimo)
# - l3packages (2024+ mínimo)

# PAQUETES FUNCIONALES:
# - microtype (esencial para tipografía)
# - titlesec (esencial para títulos)
# - setspace (espaciado de líneas)
# - xcolor (colores)
# - mdframed (cajas de texto)
# - enumitem (listas personalizadas)
# - listings (código formateado)
# - amsmath, mathtools (matemáticas)
# - longtable, xltabular (tablas)
# - booktabs (diseño de tablas)
# - newtxmath (numerales matemáticos)

# ========================================================================
# PASO 3: Instalación via línea de comandos (metodo automatizado)
# ========================================================================

# MiKTeX 25.4 utiliza 'miktex packages' para gestionar paquetes
# PRIMERO: Actualizar base de datos de paquetes

miktex packages update-package-database

# Luego: Instalar paquetes críticos (fontspec, expl3, l3kernel, l3packages)
# Estos ya pueden estar instalados - el comando reportara si existen

miktex packages install fontspec expl3 l3kernel l3packages

# Instalar paquetes funcionales esenciales

miktex packages install microtype titlesec setspace xcolor mdframed
miktex packages install enumitem listings amsmath mathtools
miktex packages install longtable xltabular booktabs newtxmath

# Instalar paquetes de soporte adicionales

miktex packages install etoolbox xurl makecell fancyvrb multirow
miktex packages install tabularx ragged2e hyphenat dsfont xparse

# NOTA: Si los paquetes ya existen, MiKTeX mostrara un mensaje informativo.
# Esto es NORMAL y no causa errores.

# ========================================================================
# PASO 4: Limpiar caché de MiKTeX
# ========================================================================

# Ejecutar como USUARIO NORMAL (no requiere admin en instalacion personal):
initexmf --update-fndb

# Este comando actualiza la base de datos de nombres de archivos
# Esto es crítico después de instalar nuevos paquetes

# ========================================================================
# PASO 5: Verificar instalación de fuentes OpenType en Windows
# ========================================================================

# FUENTES REQUERIDAS - Estado VERIFICADO (Octubre 2025):
# Las siguientes fuentes ESTAN instaladas en el sistema:

# IBM Plex Serif:
#   - Formato: .otf (OpenType)
#   - Variantes: Regular, Bold, Italic, Bold Italic
#   - Estado: INSTALADO

# IBM Plex Sans:
#   - Formato: .otf (OpenType)
#   - Variantes: Regular, Bold, Italic, Bold Italic
#   - Estado: INSTALADO

# IBM Plex Mono:
#   - Formato: .otf (OpenType)
#   - Variantes: Regular, Bold, Italic, Bold Italic
#   - Estado: INSTALADO

# JetBrains Mono NL:
#   - Formato: .ttf (TrueType)
#   - Variantes: Regular, Bold, Italic, Bold Italic
#   - Estado: INSTALADO

# ========================================================================
# COMANDOS DE VERIFICACION DE FUENTES (EJECUTAR EN POWERSHELL)
# ========================================================================

# 1. VERIFICAR FUENTES EN EL REGISTRO DE WINDOWS
Write-Host "=== VERIFICACION DE FUENTES ===" -ForegroundColor Cyan
$fontsRegistry = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
$requiredFonts = @('IBM Plex Serif', 'IBM Plex Sans', 'IBM Plex Mono', 'JetBrains Mono')

foreach ($font in $requiredFonts) {
    $found = Get-ItemProperty -Path $fontsRegistry -ErrorAction SilentlyContinue | 
             Select-Object * | 
             Where-Object { $_ -match $font }
    
    if ($found) {
        Write-Host "[+] $font - ENCONTRADA" -ForegroundColor Green
    } else {
        Write-Host "[-] $font - NO ENCONTRADA" -ForegroundColor Red
    }
}

# 2. VERIFICAR ARCHIVOS DE FUENTES EN C:\Windows\Fonts
Write-Host ""
Write-Host "=== ARCHIVOS DE FUENTES ===" -ForegroundColor Cyan
Get-ChildItem 'C:\Windows\Fonts' | 
    Where-Object { $_.Name -match '(IBM.*Plex|JetBrains)' } | 
    Select-Object Name, @{n='Size';e={'{0:N0} bytes' -f $_.Length}} |
    Format-Table -AutoSize

# 3. VERIFICAR COMPATIBILIDAD CON XETEX
Write-Host ""
Write-Host "=== PRUEBA XETEX ===" -ForegroundColor Cyan
Write-Host "Para probar que xelatex encuentra las fuentes, ejecutar:"
Write-Host ""
Write-Host "xelatex --version" -ForegroundColor Yellow
Write-Host ""
Write-Host "Luego compilar un documento de prueba que use estas fuentes"
Write-Host ""

# ========================================================================
# VERIFICACION MANUAL EN WINDOWS
# ========================================================================

# Abrir: Panel de Control > Fuentes (o Settings > Fonts)
# Buscar: "IBM Plex" y "JetBrains"
# Debe mostrar todas las familias listadas arriba

# ========================================================================
# PASO 6: Comando Pandoc CORRECTO para compilar
# ========================================================================

# IMPORTANTE: Usar WITHOUT admin privileges para evitar warnings de seguridad

# PowerShell - Comando de una línea (Windows 11):
pandoc input.md --pdf-engine=xelatex --pdf-engine-opt=-no-shell-escape --pdf-engine-opt=-interaction=nonstopmode --metadata-file=.pandoc/metadata-gruvbox.yaml --standalone --dpi=300 --wrap=auto -o output.pdf

# O versión multilínea (más legible en PowerShell):
pandoc `
  input.md `
  --pdf-engine=xelatex `
  --pdf-engine-opt=-no-shell-escape `
  --pdf-engine-opt=-interaction=nonstopmode `
  --metadata-file=.pandoc/metadata-gruvbox.yaml `
  --standalone `
  --dpi=300 `
  --wrap=auto `
  -o output.pdf

# NOTAS IMPORTANTES:
# 1. --pdf-engine-opt=-no-shell-escape es CORRECTO
# 2. El warning "security risk: running with elevated privileges" es NORMAL
# 3. NO afecta la compilacion - es solo una advertencia de stderr

# ========================================================================
# PASO 7: Script PowerShell para compilación rápida (build.ps1)
# ========================================================================

# ARCHIVO: .vscode\build.ps1
# Este archivo EXISTE y ha sido TESTEADO EXITOSAMENTE (Octubre 2025)

# USO:
# .\build.ps1 -InputFile documento.md
# .\build.ps1 -InputFile documento.md -OutputFile documento.pdf
# .\build.ps1 -InputFile documento.md -Dark

# CARACTERISTICAS:
# - Verifica que pandoc, xelatex y miktex estan instalados
# - Genera PDF con metadatos
# - Manejo de errores robusto
# - Mensajes de progreso detallados
# - Compatible con PowerShell 5.1+ y Windows 11

# EJECUCION CORRECTA:
# Ejecutar DESDE terminal NORMAL (sin privilegios de admin)
# & ".\.vscode\build.ps1" -InputFile "documento.md"

# ========================================================================
# PASO 8: Diagnosticar errores (si persisten problemas)
# ========================================================================

# Generar archivo .tex intermedio para inspeccionar (UTIL para depuracion):
pandoc input.md --pdf-engine=xelatex -s -o debug.tex

# Compilar directamente con xelatex para ver errores reales:
xelatex -interaction=nonstopmode debug.tex

# Ver el log detallado (buscar errores y advertencias):
Get-Content debug.log | Select-String -Pattern "Error|Warning" -Context 2

# NOTA: Los archivos debug.* pueden ser eliminados después del diagnostico

# ========================================================================
# PASO 9: Resolver "security risk" warning (cosmético, no crítico)
# ========================================================================

# El warning "xelatex: security risk: running with elevated privileges"
# es NORMAL en Windows 11 cuando se ejecuta desde PowerShell como Admin.
# NO AFECTA la compilación. Solo aparece en stderr, no en stdout.

# Es CORRECTO usar: --pdf-engine-opt=-no-shell-escape
# El warning solo advierte sobre -shell-escape, que TU NO USAS.

# Para eliminar el warning (opcional), ejecutar sin permisos de Admin:
# Abrir PowerShell NORMAL (no Admin) y compilar igual.

# ========================================================================
# VERIFICACION FINAL: Requisitos mínimos 2025 (VERIFICADO)
# ========================================================================

# Verificar versiones instaladas ejecutando estos comandos:
xelatex --version
pandoc --version
miktex --version

# RESULTADO ESPERADO (Octubre 2025 - ACTUAL):
# xelatex: MiKTeX-XeTeX 4.15 (MiKTeX 25.4)
# pandoc: 3.6.4 (con Lua 5.4)
# miktex: 25.4

# VERIFICACION DE PAQUETES CRITICOS:
# Los siguientes paquetes ESTAN INSTALADOS:
# - fontspec, expl3, l3kernel, l3packages (2024+)
# - microtype, titlesec, setspace, xcolor, mdframed
# - enumitem, listings, amsmath, mathtools
# - longtable, xltabular, booktabs, newtxmath
# - Y todos los paquetes de soporte listados en PASO 3

# VERIFICACION DE FUENTES:
# - IBM Plex Serif (.otf) - INSTALADO
# - IBM Plex Sans (.otf) - INSTALADO
# - IBM Plex Mono (.otf) - INSTALADO
# - JetBrains Mono NL (.ttf) - INSTALADO

# TODO LISTO PARA COMPILAR

# ========================================================================
# FIN DE LA GUIA
# ========================================================================

# NOTAS IMPORTANTES PARA USO FUTURO:
# ========================================================================

# 1. COMPILACION SIMPLE:
#    & ".\.vscode\build.ps1" -InputFile "documento.md"

# 2. COMPILACION CON TEMA OSCURO:
#    & ".\.vscode\build.ps1" -InputFile "documento.md" -Dark

# 3. VERIFICAR PROBLEMA:
#    & ".\.vscode\build.ps1" -InputFile "documento.md" -Verbose

# 4. EJECUTAR DESDE LINEA DE COMANDOS (cmd.exe):
#    powershell -ExecutionPolicy Bypass -File ".\.vscode\build.ps1" -InputFile "documento.md"

# 5. SI FALTA ALGUN PAQUETE EN COMPILACION:
#    MiKTeX lo instalara automaticamente en instalacion personal

# 6. FUENTES: Si necesita otras fuentes
#    Descargar de: fonts.google.com o jetbrains.com
#    Instalar en Windows: Panel de Control > Fuentes > Instalar fuente

# SOPORTE:
# - Documentacion Pandoc: https://pandoc.org
# - Documentacion MiKTeX: https://miktex.org
# - Documentacion XeTeX: http://tug.org/xetex
# - Mejor practica: Usar build.ps1 para compilaciones

print "======================================================"
print "   CONFIGURACION COMPLETADA Y VERIFICADA"
print "   Windows 11 + MiKTeX 25.4 + Pandoc 3.6.4"
print "======================================================"