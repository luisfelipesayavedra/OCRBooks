import SwiftUI
import AppKit

/// Texto reconocido de la página, con confianza media y copia rápida.
struct TextPanel: View {
    let page: PageItem

    private var averageConfidence: Float {
        guard !page.lines.isEmpty else { return 0 }
        return page.lines.map(\.confidence).reduce(0, +) / Float(page.lines.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if page.lines.isEmpty {
                    Text("Aún no hay texto reconocido. Restaura la página primero.")
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        "\(page.lines.count) líneas · confianza media \(Int(averageConfidence * 100)) %",
                        systemImage: "text.viewfinder"
                    )
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(page.text, forType: .string)
                } label: {
                    Label("Copiar texto", systemImage: "doc.on.doc")
                }
                .disabled(page.lines.isEmpty)
            }
            .font(.caption)
            .padding(10)

            Divider()

            ScrollView {
                Text(page.text.isEmpty ? " " : page.text)
                    .font(.system(.body, design: .serif))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
    }
}
