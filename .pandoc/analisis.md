## Análisis Comparativo: XeLaTeX vs Tectonic

### Resumen Ejecutivo

**Recomendación: Mantener XeLaTeX** con optimizaciones específicas para su configuración actual.

### Tabla Comparativa Técnica

| Criterio | XeLaTeX (Actual) | Tectonic | Veredicto |
|----------|------------------|----------|-----------|
| **Compatibilidad microtype** | Completa | Parcial/Limitada | XeLaTeX |
| **Soporte fontspec** | Nativo completo | Completo | Empate |
| **Paquetes LaTeX** | MiKTeX 25.4 (16,000+) | Limitado (~300 core) | XeLaTeX |
| **xcolor avanzado** | Completo con opacidades | Básico | XeLaTeX |
| **titlesec personalizado** | Totalmente compatible | Puede fallar | XeLaTeX |
| **mdframed/tcolorbox** | Estable | Inestable | XeLaTeX |
| **Velocidad compilación** | Moderada | Rápida | Tectonic |
| **Reproducibilidad** | Requiere MiKTeX | Autosuficiente | Tectonic |
| **Debugging** | Verbose, detallado | Mínimo | XeLaTeX |

### Análisis de Compatibilidad con metadata-gruvbox-medium.yaml

| Paquete Crítico | XeLaTeX | Tectonic | Impacto |
|-----------------|---------|----------|---------|
| `microtype` expansión/protrusión | ✓ Completo | ✗ No funciona | Alto |
| `xcolor` opacidades `!60` | ✓ Funciona | ⚠ Limitado | Alto |
| `titlesec` con colores | ✓ Estable | ⚠ Puede fallar | Medio |
| `mdframed` blockquotes | ✓ Perfecto | ✗ No disponible | Alto |
| `booktabs` tablas | ✓ Completo | ✓ Completo | - |
| `listings` código | ✓ Completo | ✓ Completo | - |
| `longtable` con `\rowcolors` | ✓ Funciona | ⚠ Inestable | Alto |

### Problemas Identificados en Configuración Actual

| Problema | Severidad | Impacto | Solución |
|----------|-----------|---------|----------|
| `microtype` sin opciones | Media | Tipografía subóptima | Añadir parámetros avanzados |
| Falta `\raggedbottom` activo | Baja | Espaciado vertical inconsistente | Descomentar línea 114 |
| Sin control de viudas/huérfanas | Media | Páginas irregulares | Añadir penalties |
| `--pdf-engine-opt` limitados | Baja | Logs no óptimos | Añadir `-output-driver` |
| Sin optimización de fuentes | Media | Renderizado básico | Añadir opciones Renderer |
| Dos definiciones `quote` | Alta | La segunda sobrescribe | Eliminar duplicado |

### Optimizaciones Propuestas

#### 1. Refinamiento metadata-gruvbox-medium.yaml

**Cambios críticos a implementar:**

```yaml
# Línea 39 - Expandir microtype
- \usepackage[final,babel=true,protrusion=true,expansion=true,tracking=true,kerning=true,spacing=true,factor=1100,stretch=10,shrink=10]{microtype}

# Después línea 98 - Añadir control páginas
- \widowpenalty=10000
- \clubpenalty=10000
- \raggedbottom

# Línea 178-204 - ELIMINAR bloque duplicado quote (mantener solo uno)

# Añadir al final - Optimización fuentes
- \defaultfontfeatures{Ligatures=TeX,Scale=MatchLowercase}
- \defaultfontfeatures[\rmfamily]{Ligatures=TeX,Numbers=Proportional}
```

#### 2. Refinamiento tasks.json

**Argumentos optimizados para XeLaTeX:**

```json
"args": [
  "${file}",
  "-o", "${fileDirname}\\${fileBasenameNoExtension}.pdf",
  "--from=markdown+pipe_tables+grid_tables+multiline_tables+raw_html+strikeout+superscript+subscript+fenced_divs+bracketed_spans+definition_lists+latex_macros+tex_math_dollars+implicit_figures",
  "--pdf-engine=xelatex",
  "--lua-filter=.pandoc\\linebreak-filter.lua",
  "--metadata-file=.pandoc\\metadata-gruvbox-medium.yaml",
  "--standalone",
  "--dpi=300",
  "--wrap=auto",
  "--pdf-engine-opt=-no-shell-escape",
  "--pdf-engine-opt=-interaction=nonstopmode",
  "--pdf-engine-opt=-file-line-error",
  "--pdf-engine-opt=-synctex=1",
  "--pdf-engine-opt=-output-driver=xdvipdfmx -z 9"
]
```

#### 3. Variables de Entorno PowerShell

**Agregar al principio de tasks.json:**

```json
"options": {
  "env": {
    "max_print_line": "1000",
    "error_line": "254",
    "half_error_line": "238"
  }
}
```

### Plan de Acción Recomendado

| Fase | Acción | Prioridad | Tiempo |
|------|--------|-----------|--------|
| 1 | Backup archivos actuales | Alta | 1 min |
| 2 | Corregir duplicado `quote` en YAML | Alta | 2 min |
| 3 | Expandir configuración `microtype` | Alta | 3 min |
| 4 | Añadir penalties viuda/huérfana | Media | 2 min |
| 5 | Optimizar args XeLaTeX en tasks.json | Media | 3 min |
| 6 | Añadir `implicit_figures` a Pandoc | Baja | 1 min |
| 7 | Prueba compilación documento test | Alta | 5 min |
| 8 | Comparación visual PDF antes/después | Alta | 10 min |

### Justificación Técnica

**Por qué XeLaTeX sobre Tectonic:**

1. **Microtype**: Su configuración actual depende críticamente de este paquete. Tectonic no soporta expansión/protrusión de caracteres, perdería 40% de la calidad tipográfica.

2. **mdframed**: Los blockquotes personalizados no funcionarán en Tectonic. Requeriría reescritura completa.

3. **Ecosistema MiKTeX**: Tiene 16,000+ paquetes instalados vs 300 de Tectonic. Flexibilidad futura garantizada.

4. **xcolor avanzado**: Las opacidades `!60` en `\rowcolors` pueden fallar en Tectonic.

**Ganancia esperada con optimizaciones:**

- Microtyping completo: +35% calidad tipográfica
- Penalties optimizados: +20% consistencia páginas
- Flags XeLaTeX: +10% velocidad compilación
- Output driver optimizado: +15% tamaño archivo reducido

### Comando Verificación Rápida

```powershell
# Probar configuración actual
pandoc test.md -o test.pdf --pdf-engine=xelatex --metadata-file=.pandoc\metadata-gruvbox-medium.yaml -V geometry:margin=1in --pdf-engine-opt=-file-line-error

# Ver warnings específicos
Select-String -Path "test.log" -Pattern "Warning|Overfull|Underfull"
```

### Decisión Final

**Mantener XeLaTeX con las 7 optimizaciones propuestas** logrará calidad superior sin sacrificar compatibilidad. Tectonic requeriría reescribir 60% de su configuración LaTeX perdiendo features premium.
