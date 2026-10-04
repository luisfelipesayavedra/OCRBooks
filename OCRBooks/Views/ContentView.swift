import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            if state.hasDocument {
                HSplitView {
                    PageDetailView()
                        .frame(minWidth: 500)
                    SettingsPanel()
                        .frame(width: 300)
                }
            } else {
                EmptyDocumentView()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if state.isWorking {
                    HStack(spacing: 8) {
                        ProgressView(value: state.progress)
                            .frame(width: 140)
                        Text(state.progressLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Cancelar") { state.cancelBatch() }
                    }
                }

                Button {
                    state.presentOpenPanel()
                } label: {
                    Label("Abrir PDF", systemImage: "folder")
                }
                .help("Abrir un libro escaneado (⌘O)")

                Button {
                    state.processSelectedPage()
                } label: {
                    Label("Restaurar página", systemImage: "wand.and.stars")
                }
                .disabled(!state.hasDocument || state.isWorking)
                .help("Restaurar y reconocer la página seleccionada")

                Button {
                    state.processAllPages()
                } label: {
                    Label("Restaurar todo", systemImage: "wand.and.stars.inverse")
                }
                .disabled(!state.hasDocument || state.isWorking)
                .help("Restaurar todas las páginas, una por una")

                Button {
                    state.presentExportPanel()
                } label: {
                    Label("Exportar PDF", systemImage: "square.and.arrow.up")
                }
                .disabled(!state.hasDocument || state.isWorking)
                .help("Exportar el libro restaurado con capa de texto OCR")
            }
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { state.errorMessage != nil },
                set: { if !$0 { state.errorMessage = nil } }
            )
        ) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(state.errorMessage ?? "")
        }
        .navigationTitle(state.documentURL?.lastPathComponent ?? "OCRBooks")
    }
}

/// Pantalla inicial cuando aún no hay documento.
struct EmptyDocumentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Restaura libros antiguos escaneados")
                .font(.title2)
            Text("Abre un PDF escaneado para corregir la alineación, limpiar el papel,\nrecuperar la nitidez de las letras y reconocer el texto página por página.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                state.presentOpenPanel()
            } label: {
                Label("Abrir PDF…", systemImage: "folder")
            }
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
