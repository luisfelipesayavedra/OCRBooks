import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable {
    case image = "Página"
    case text = "Texto OCR"
    var id: String { rawValue }
}

enum ImageMode: String, CaseIterable, Identifiable {
    case comparison = "Comparar"
    case enhanced = "Restaurada"
    case original = "Original"
    var id: String { rawValue }
}

struct PageDetailView: View {
    @EnvironmentObject private var state: AppState
    @State private var tab: DetailTab = .image
    @State private var mode: ImageMode = .comparison

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(DetailTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                Spacer()

                if tab == .image, state.selectedPage?.enhancedPreview != nil {
                    Picker("", selection: $mode) {
                        ForEach(ImageMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }
            }
            .padding(10)

            Divider()

            if let page = state.selectedPage {
                switch tab {
                case .image:
                    PageImageView(page: page, mode: mode)
                case .text:
                    TextPanel(page: page)
                }
            } else {
                Text("Selecciona una página")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct PageImageView: View {
    @EnvironmentObject private var state: AppState
    let page: PageItem
    let mode: ImageMode

    var body: some View {
        Group {
            if let enhanced = page.enhancedPreview {
                switch mode {
                case .comparison:
                    if let original = page.originalPreview {
                        ComparisonView(original: original, enhanced: enhanced)
                    } else {
                        SingleImageView(image: enhanced)
                    }
                case .enhanced:
                    SingleImageView(image: enhanced)
                case .original:
                    if let original = page.originalPreview {
                        SingleImageView(image: original)
                    } else {
                        SingleImageView(image: enhanced)
                    }
                }
            } else if case .processing(let step) = page.status {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(step).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 14) {
                    if let thumbnail = page.thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 420)
                            .shadow(radius: 4)
                    }
                    Text("Página sin restaurar")
                        .foregroundStyle(.secondary)
                    Button {
                        state.processSelectedPage()
                    } label: {
                        Label("Restaurar esta página", systemImage: "wand.and.stars")
                    }
                    .disabled(state.isWorking)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct SingleImageView: View {
    let image: CGImage

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        maxWidth: max(geo.size.width, 1),
                        maxHeight: max(geo.size.height, 1)
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .padding(8)
    }
}

/// Comparación antes/después con un divisor arrastrable.
struct ComparisonView: View {
    let original: CGImage
    let enhanced: CGImage
    @State private var fraction: CGFloat = 0.5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                imageView(enhanced, in: geo.size)

                imageView(original, in: geo.size)
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle()
                                .frame(width: geo.size.width * fraction)
                            Spacer(minLength: 0)
                        }
                    )

                // Divisor.
                ZStack {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2)
                    VStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Text("Original")
                            Image(systemName: "arrow.left.and.right")
                            Text("Restaurada")
                        }
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 12)
                    }
                }
                .frame(maxHeight: .infinity)
                .offset(x: geo.size.width * fraction - 1)
                .contentShape(Rectangle().inset(by: -8))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        fraction = min(0.98, max(0.02, value.location.x / geo.size.width))
                    }
            )
        }
        .padding(8)
    }

    private func imageView(_ image: CGImage, in size: CGSize) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size.width, height: size.height)
    }
}
