import SwiftUI
import UIKit

/// The eight app icons: four abstract marks, each on a black and a white tile.
/// Asset names must match `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` in project.yml
/// and ios/icon-src/render.js.
struct AppIconChoice: Identifiable, Hashable {
    enum Tile: String { case black = "Black", white = "White" }

    let mark: String
    let tile: Tile
    /// nil = the primary icon (Caught thought on black).
    let alternateName: String?
    let preview: String

    var id: String { preview }
    var label: String { "\(mark), \(tile.rawValue.lowercased())" }

    static let marks = ["Caught thought", "Two minds", "Loop", "Orbit"]

    static let all: [AppIconChoice] = [
        .init(mark: "Caught thought", tile: .black, alternateName: nil, preview: "IconPreview-Caught"),
        .init(mark: "Caught thought", tile: .white, alternateName: "AppIcon-CaughtLight", preview: "IconPreview-CaughtLight"),
        .init(mark: "Two minds", tile: .black, alternateName: "AppIcon-Minds", preview: "IconPreview-Minds"),
        .init(mark: "Two minds", tile: .white, alternateName: "AppIcon-MindsLight", preview: "IconPreview-MindsLight"),
        .init(mark: "Loop", tile: .black, alternateName: "AppIcon-Loop", preview: "IconPreview-Loop"),
        .init(mark: "Loop", tile: .white, alternateName: "AppIcon-LoopLight", preview: "IconPreview-LoopLight"),
        .init(mark: "Orbit", tile: .black, alternateName: "AppIcon-Orbit", preview: "IconPreview-Orbit"),
        .init(mark: "Orbit", tile: .white, alternateName: "AppIcon-OrbitLight", preview: "IconPreview-OrbitLight"),
    ]

    static func choice(mark: String, tile: Tile) -> AppIconChoice? {
        all.first { $0.mark == mark && $0.tile == tile }
    }
}

/// Pick the app icon: a grid with one column per mark and a row per tile (black, white).
/// Lives inside a List section in More.
struct AppIconPicker: View {
    @State private var current = UIApplication.shared.alternateIconName

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: AppIconChoice.marks.count)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach([AppIconChoice.Tile.black, .white], id: \.self) { tile in
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(AppIconChoice.marks, id: \.self) { mark in
                        if let c = AppIconChoice.choice(mark: mark, tile: tile) {
                            option(c)
                        }
                    }
                }
            }
            if let c = AppIconChoice.all.first(where: { $0.alternateName == current }) {
                Text(c.mark)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 8)
    }

    private func option(_ c: AppIconChoice) -> some View {
        let selected = current == c.alternateName
        return Button {
            Task { @MainActor in
                guard UIApplication.shared.supportsAlternateIcons, current != c.alternateName else { return }
                do {
                    try await UIApplication.shared.setAlternateIconName(c.alternateName)
                    current = c.alternateName
                } catch {}
            }
        } label: {
            Image(c.preview)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 64)
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2.5))
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.accentColor)
                            .offset(x: 4, y: 4)
                    }
                }
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(c.label) icon")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
