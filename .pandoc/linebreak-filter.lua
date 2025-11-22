-- Convierte <br> a salto de línea LaTeX
-- Limpia espacios/basura alrededor pero SOLO acepta <br> (minúsculas)
-- Agrega \mbox{} antes para evitar error cuando <br> está al inicio de celda
function RawInline(el)
  if el.format == 'html' then
    -- Eliminar espacios antes y después, luego verificar si es exactamente <br>
    local limpio = el.text:match('^%s*(.-)%s*$')
    if limpio == '<br>' then
      -- \mbox{} crea un espacio invisible que permite \newline
      return pandoc.RawInline('latex', '\\mbox{}\\newline ')
    end
  end
  return el
end
