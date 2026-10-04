# OCRBooks

App nativa de macOS para **restaurar libros antiguos escaneados en PDF** y reconocer su texto (OCR), página por página y priorizando siempre la calidad de reconstrucción sobre el tamaño del archivo.

<p align="center"><em>Abrir PDF → restaurar página por página → exportar PDF con capa de texto buscable.</em></p>

## Qué hace

Para cada página del PDF (modo **Profundo**/**Máximo**, el predeterminado):

1. **Reconstrucción a alta resolución** — la página se vuelve a renderizar desde el PDF original a 300/400/600/800 ppp. Nunca se re-escala una imagen ya degradada, por eso se recupera resolución y definición reales.
2. **Enderezado (deskew)** — detecta la inclinación del escaneo por perfil de proyección (±3°, pasos de 0,25°) y la corrige, alineando las líneas de texto.
3. **Aplanado de iluminación en CPU** — estima el fondo (papel) por bloques y normaliza cada píxel contra él: desaparecen sombras de encuadernación, manchas de luz y amarilleo irregular. El papel queda blanco puro.
4. **Binarización adaptativa de Sauvola** — el umbral tinta/papel se calcula localmente alrededor de cada píxel (el equivalente a decidir palabra por palabra qué trazos son reales), lo que rescata tinta desvaída que un umbral global perdería.
5. **Eliminación de manchas y motas** — análisis de componentes conexas: cada mota, punto o mancha del escaneo se identifica como grupo de píxeles y se elimina según su tamaño; una pasada previa de OCR delimita las zonas de texto y **todo lo que queda fuera de ellas se borra** (con protección opcional para ilustraciones, grabados y capitulares).
6. **Composición y nitidez** — papel 100 % blanco; la tinta conserva el detalle del trazo original con densidad ajustable, más máscara de enfoque final. Tres modos: color restaurado, escala de grises o blanco y negro puro.
7. **OCR con Vision de Apple** — segunda pasada de reconocimiento en modo preciso sobre la página ya restaurada (español, inglés, francés, italiano, portugués, alemán).
8. **Recomposición vectorial de la tinta** — los contornos reales de cada letra se trazan como curvas Bézier (marching squares → Douglas-Peucker → suavizado con detección de esquinas, estilo *potrace*) y se incrustan en el PDF: el texto queda **perfectamente nítido a cualquier zoom e impresión**, conservando la tipografía original del libro. Las ilustraciones y grabados permanecen en ráster, donde conservan su tramado.
9. **Borrador manual** — para lo que el algoritmo no pueda decidir: pinta de blanco cualquier marca restante directamente sobre la página, con tamaño de pincel ajustable y deshacer. Los trazos se aplican también al PDF exportado.
10. **Exportación** — PDF final con la imagen restaurada de cada página, la capa vectorial de tinta encima y una **capa de texto invisible perfectamente alineada**: el libro conserva su estética original pero se puede buscar, seleccionar y copiar.

El modo **Suave** conserva la cadena ligera de realce (Core Image) para quien solo quiera mejorar contraste y nitidez sin reconstruir la página.

Las imágenes a resolución completa se guardan en una caché en disco, de modo que libros de cientos de páginas no agotan la memoria: el procesamiento es estrictamente página por página.

## Interfaz

- **Barra lateral** con miniaturas y estado de cada página (pendiente / procesando / restaurada).
- **Editor con zoom real**: la página restaurada se muestra a resolución completa con zoom del 2 % al 6400 % — pellizco del trackpad, ⌘+rueda centrado en el cursor, botones ±/1:1/encajar, doble clic para alternar encaje/100 % y arrastre para desplazarse — hasta inspeccionar píxel a píxel los detalles más mínimos.
- **Vista previa vectorial** en el editor: *Vectorial* muestra la página exactamente como quedará en el PDF (relleno con el color real de la tinta); *Contornos* resalta en rojo lo que se vectorizó, para auditar la cobertura antes de exportar.
- **Borrador** integrado en el editor: pincel de 6–300 px, deshacer (⌘Z) y limpiar trazos.
- **Comparador antes/después**: un divisor arrastrable muestra el original y la versión restaurada sobre la misma página.
- **Pestaña de texto OCR** con número de líneas, confianza media y copia al portapapeles.
- **Panel de ajustes**: intensidad (suave/profunda/máxima), resolución, enderezado, eliminación de motas y manchas, protección de ilustraciones, densidad de tinta, nitidez, modo de salida e idioma. Reprocesar una página aplica los nuevos ajustes al instante.

## Requisitos

- macOS 13 Ventura o posterior (Apple Silicon o Intel).
- Xcode 15+ para compilar.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) para generar el proyecto.

## Compilar y ejecutar

```bash
brew install xcodegen
cd OCRBooks
xcodegen generate
open OCRBooks.xcodeproj
```

En Xcode: selecciona el esquema **OCRBooks** y pulsa ⌘R. La app está preparada para sandbox con acceso de lectura/escritura a los archivos que el usuario elija.

## Arquitectura

```
OCRBooks/
├── App/
│   └── OCRBooksApp.swift        # Punto de entrada SwiftUI
├── Models/
│   ├── AppState.swift           # Estado central y orquestación del flujo
│   ├── PageItem.swift           # Página: estado, previews, líneas OCR
│   └── RestorationSettings.swift# Parámetros de restauración
├── Services/
│   ├── PDFRenderer.swift        # Render a DPI alto desde PDFKit
│   ├── SkewDetector.swift       # Detección de inclinación (proyección)
│   ├── RestorationEngine.swift  # Orquestación suave (CI) / profunda (CPU)
│   ├── DeepRestorer.swift       # Aplanado, Sauvola, despeckle, composición
│   ├── VectorTracer.swift       # Vectorización de la tinta (potrace-lite)
│   ├── OCRService.swift         # Vision (VNRecognizeTextRequest, .accurate)
│   ├── PDFExporter.swift        # PDF con texto invisible + trazos de borrador
│   └── ImageUtil.swift          # Escalado y PNG sin pérdida
└── Views/
    ├── ContentView.swift        # Ventana, toolbar y flujo general
    ├── SidebarView.swift        # Lista de páginas con miniaturas
    ├── PageDetailView.swift     # Editor + comparador + texto
    ├── ZoomableCanvas.swift     # Canvas AppKit: zoom 2–6400 % y borrador
    ├── SettingsPanel.swift      # Ajustes de restauración
    └── TextPanel.swift          # Texto reconocido
```

Todo usa frameworks del sistema (PDFKit, Core Image, Vision, Core Text): sin dependencias externas y el OCR se ejecuta **100 % en el Mac**, sin enviar nada a internet.
