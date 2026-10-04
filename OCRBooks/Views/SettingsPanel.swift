import SwiftUI

/// Panel de ajustes de restauración. Los cambios se aplican a las páginas que
/// se procesen a partir de ese momento; re-procesar una página la actualiza.
struct SettingsPanel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section("Intensidad") {
                Picker("Restauración", selection: $state.settings.strength) {
                    ForEach(RestorationStrength.allCases) { strength in
                        Text(strength.label).tag(strength)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Reconstrucción IA (Real-ESRGAN)") {
                Picker("Modelo", selection: $state.settings.aiVariant) {
                    ForEach(SRVariant.allCases) { variant in
                        Text(variant.label).tag(variant)
                    }
                }
                .disabled(state.srState == .downloading || state.srState == .compiling)
                .onChange(of: state.settings.aiVariant) { _ in
                    state.aiVariantChanged()
                }

                switch state.srState {
                case .notDownloaded:
                    Button {
                        state.prepareAIModel()
                    } label: {
                        Label("Descargar modelo (~30 MB, una sola vez)", systemImage: "arrow.down.circle")
                    }
                case .downloading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Descargando modelo…").foregroundStyle(.secondary)
                    }
                case .compiling:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Compilando para tu Mac…").foregroundStyle(.secondary)
                    }
                case .ready:
                    Toggle("Reparar trazos con IA (lento)", isOn: $state.settings.aiReconstruction)
                        .help("Real-ESRGAN ×4 por Core ML, 100 % local: reconstruye trazos dañados o borrosos y dobla la resolución efectiva antes de la binarización. Minutos por página según el Mac.")
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Error: \(message)")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button("Reintentar descarga") {
                            state.prepareAIModel()
                        }
                    }
                }
            }

            Section("Reconstrucción") {
                Picker("Resolución", selection: $state.settings.dpi) {
                    Text("300 ppp").tag(300.0)
                    Text("400 ppp").tag(400.0)
                    Text("600 ppp").tag(600.0)
                    Text("800 ppp (lento)").tag(800.0)
                }
                Toggle("Enderezar página (deskew)", isOn: $state.settings.deskew)
                if let page = state.selectedPage, page.status == .done, state.settings.deskew {
                    LabeledContent("Inclinación detectada") {
                        Text(String(format: "%.2f°", page.skewAngle))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Manchas y ruido") {
                LabeledContent("Reducción de ruido") {
                    Slider(value: $state.settings.noiseReduction, in: 0...0.1)
                }
                if state.settings.strength == .light {
                    Toggle("Blanquear papel y quitar sombras", isOn: $state.settings.flattenBackground)
                } else {
                    LabeledContent("Eliminar motas") {
                        Slider(value: $state.settings.despeckleLevel, in: 0...3)
                    }
                    Toggle("Borrar manchas fuera del texto", isOn: $state.settings.removeStainsOutsideText)
                    Toggle("Proteger ilustraciones y grabados", isOn: $state.settings.protectIllustrations)
                        .disabled(!state.settings.removeStainsOutsideText)
                }
            }

            Section("Letras") {
                LabeledContent("Densidad de tinta") {
                    Slider(value: $state.settings.contrast, in: 1.0...1.8)
                }
                LabeledContent("Nitidez") {
                    Slider(value: $state.settings.sharpness, in: 0...3)
                }
                Picker("Modo", selection: $state.settings.mode) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                if state.settings.strength != .light {
                    Toggle("Recomposición vectorial de la tinta", isOn: $state.settings.vectorizeText)
                        .help("Traza el contorno real de cada letra como curvas Bézier y las incrusta en el PDF: texto perfectamente nítido a cualquier zoom, conservando la tipografía original. Las ilustraciones permanecen en ráster.")
                }
            }

            Section("OCR") {
                Picker("Idioma del libro", selection: $state.settings.language) {
                    ForEach(OCRLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }
            }

            Section {
                Button {
                    state.processSelectedPage()
                } label: {
                    Label("Aplicar a esta página", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!state.hasDocument || state.isWorking)

                Button {
                    state.processAllPages()
                } label: {
                    Label("Restaurar todo el libro", systemImage: "wand.and.stars.inverse")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!state.hasDocument || state.isWorking)
            } footer: {
                Text("En modo profundo/máximo la página se reconstruye píxel a píxel: papel blanco puro, umbral adaptativo palabra por palabra y limpieza de manchas guiada por el texto detectado. Consume más memoria y CPU a cambio de máxima calidad.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
