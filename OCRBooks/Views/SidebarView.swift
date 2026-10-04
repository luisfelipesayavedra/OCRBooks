import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        List(selection: $state.selection) {
            ForEach(state.pages) { page in
                PageRow(page: page)
                    .tag(page.id)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if state.pages.isEmpty {
                Text("Sin documento")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PageRow: View {
    let page: PageItem

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail = page.thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                }
            }
            .frame(width: 44, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("Página \(page.id + 1)")
                    .font(.body)
                Text(page.statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            statusIcon
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch page.status {
        case .pending:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.tertiary)
        case .processing:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
