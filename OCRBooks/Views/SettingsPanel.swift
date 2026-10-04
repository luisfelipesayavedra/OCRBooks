import SwiftUI

/// Panel de ajustes de restauración. Los cambios se aplican a las páginas que
/// se procesen a partir de ese momento; re-procesar una página la actualiza.
struct SettingsPanel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section("Reconstrucción") {
                Picker("Resolución", selection: $state.settings.dpi) {
                    Text("300 ppp").tag(300.0)
                    Text("400 ppp").tag(400.0)
                    Text("600 ppp").tag(600.0)
                }
                Toggle("Enderezar página (deskew)", isOn: $state.settings.deskew)
                if let page = state.selectedPage, page.status == .done, state.settings.deskew {
                    LabeledContent("Inclinación detectada") {
                        Text(String(format: "%.2f°", page.skewAngle))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Limpieza") {
                Toggle("Blanquear papel y quitar sombras", isOn: $state.settings.flattenBackground)
                LabeledContent("Reducción de ruido") {
                    Slider(value: $state.settings.noiseReduction, in: 0...0.1)
                }
            }

            Section("Letras") {
                LabeledContent("Contraste") {
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
                Text("El libro se procesa página por página a resolución completa; la calidad no depende del tamaño del archivo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
