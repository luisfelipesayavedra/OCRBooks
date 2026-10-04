# OCRBooks

App nativa de macOS para **restaurar libros antiguos escaneados en PDF** y reconocer su texto (OCR), página por página y priorizando siempre la calidad de reconstrucción sobre el tamaño del archivo.

<p align="center"><em>Abrir PDF → restaurar página por página → exportar PDF con capa de texto buscable.</em></p>

## Qué hace

Para cada página del PDF:

1. **Reconstrucción a alta resolución** — la página se vuelve a renderizar desde el PDF original a 300/400/600 ppp. Nunca se re-escala una imagen ya degradada, por eso se recupera resolución y definición reales.
2. **Enderezado (deskew)** — detecta la inclinación del escaneo por perfil de proyección (±3°, pasos de 0,25°) y la corrige, alineando las líneas de texto.
3. **Blanqueo del papel** — aplana la iluminación dividiendo la página entre una versión muy desenfocada de sí misma: desaparecen las sombras de encuadernación, manchas de luz y el amarilleo irregular, sin tocar la tinta.
4. **Reducción de ruido** — elimina el grano del escaneo.
5. **Contraste y nitidez** — realza el contraste y aplica máscara de enfoque calibrada a la resolución para recuperar el perfil de las letras. Tres modos de salida: color restaurado, escala de grises o blanco y negro puro (binarización Otsu).
6. **OCR con Vision de Apple** — reconocimiento en modo preciso con corrección de idioma (español, inglés, francés, italiano, portugués, alemán).
7. **Exportación** — PDF final con la imagen restaurada de cada página más una **capa de texto invisible perfectamente alineada**: el libro conserva su estética original pero se puede buscar, seleccionar y copiar.

Las imágenes a resolución completa se guardan en una caché en disco, de modo que libros de cientos de páginas no agotan la memoria: el procesamiento es estrictamente página por página.

## Interfaz

- **Barra lateral** con miniaturas y estado de cada página (pendiente / procesando / restaurada).
- **Visor con comparador antes/después**: un divisor arrastrable muestra el original y la versión restaurada sobre la misma página.
- **Pestaña de texto OCR** con número de líneas, confianza media y copia al portapapeles.
- **Panel de ajustes**: resolución, enderezado, blanqueo, ruido, contraste, nitidez, modo de salida e idioma. Reprocesar una página aplica los nuevos ajustes al instante.

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
│   ├── RestorationEngine.swift  # Cadena Core Image de restauración
│   ├── OCRService.swift         # Vision (VNRecognizeTextRequest, .accurate)
│   ├── PDFExporter.swift        # PDF con capa de texto invisible (Core Text)
│   └── ImageUtil.swift          # Escalado y PNG sin pérdida
└── Views/
    ├── ContentView.swift        # Ventana, toolbar y flujo general
    ├── SidebarView.swift        # Lista de páginas con miniaturas
    ├── PageDetailView.swift     # Visor + comparador antes/después
    ├── SettingsPanel.swift      # Ajustes de restauración
    └── TextPanel.swift          # Texto reconocido
```

Todo usa frameworks del sistema (PDFKit, Core Image, Vision, Core Text): sin dependencias externas y el OCR se ejecuta **100 % en el Mac**, sin enviar nada a internet.
