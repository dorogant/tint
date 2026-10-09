import SwiftUI

/// Header block shared by playlist, album, artist and Liked Songs pages: cover,
/// kind badge, a large title, an optional byline (e.g. the album's artists),
/// a description and a quieter detail line, then the actions.
struct PageHeader<Cover: View, Byline: View, Actions: View>: View {
    let badge: LocalizedStringKey
    let title: String
    let subtitle: String
    let detail: String
    let cover: Cover
    let byline: Byline
    let actions: Actions

    init(badge: LocalizedStringKey, title: String, subtitle: String = "", detail: String = "",
         @ViewBuilder cover: () -> Cover, @ViewBuilder byline: () -> Byline,
         @ViewBuilder actions: () -> Actions) {
        self.badge = badge
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.cover = cover()
        self.byline = byline()
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            cover
            VStack(alignment: .leading, spacing: 0) {
                Badge(text: badge)
                Text(title)
                    .font(.system(size: 40, weight: .heavy))
                    .tracking(-0.8)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .accessibilityAddTraits(.isHeader)
                if Byline.self != EmptyView.self {
                    byline
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.top, 6)
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .padding(.top, 8)
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .padding(.top, subtitle.isEmpty ? 8 : 4)
                }
                HStack(spacing: 10) { actions }
                    .padding(.top, 18)
            }
            Spacer(minLength: 0)
        }
    }
}

extension PageHeader where Byline == EmptyView {
    init(badge: LocalizedStringKey, title: String, subtitle: String = "", detail: String = "",
         @ViewBuilder cover: () -> Cover, @ViewBuilder actions: () -> Actions) {
        self.init(badge: badge, title: title, subtitle: subtitle, detail: detail,
                  cover: cover, byline: { EmptyView() }, actions: actions)
    }
}

extension View {
    /// Page covers sit on a soft shadow tinted from the artwork itself, so each
    /// page carries its own colour. Greyscale art keeps a neutral shadow.
    func coverGlow(_ images: [SpotifyImage]?) -> some View {
        modifier(CoverGlow(url: images?.best(forPixels: 48), fixed: nil))
    }

    /// The same glow in a known colour, for generated covers.
    func coverGlow(color: Color) -> some View {
        modifier(CoverGlow(url: nil, fixed: color))
    }
}

private struct CoverGlow: ViewModifier {
    let url: URL?
    let fixed: Color?
    @ViewState private var extracted: Color?

    func body(content: Content) -> some View {
        let tint = fixed ?? extracted
        content
            .shadow(color: (tint ?? .clear).opacity(0.38), radius: 34, y: 14)
            .shadow(color: .black.opacity(0.42), radius: 12, y: 8)
            .floeState(value: tint, duration: 0.45)
            .task(id: url) {
                guard let url, let image = await ArtworkCache.shared.image(for: url, pixels: 48) else { return }
                extracted = CoverColorExtractor.extract(of: image).map { Color(red: $0.r, green: $0.g, blue: $0.b) }
            }
    }
}

/// Page-shaped stand-in while a playlist, album or artist loads: quiet blocks
/// where the cover, title and actions will land, so the header arrives in place.
struct PagePlaceholder: View {
    var circle = false
    @ViewState private var visible = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            Group {
                if circle { Circle().fill(Theme.well) } else { RoundedRectangle(cornerRadius: 12).fill(Theme.well) }
            }
            .frame(width: 200, height: 200)
            .overlay { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 0) {
                Capsule().fill(Theme.well).frame(width: 64, height: 17)
                RoundedRectangle(cornerRadius: 7).fill(Theme.well).frame(width: 300, height: 36).padding(.top, 12)
                RoundedRectangle(cornerRadius: 4).fill(Theme.well).frame(width: 190, height: 12).padding(.top, 12)
                Capsule().fill(Theme.well).frame(width: 92, height: 36).padding(.top, 20)
            }
            Spacer(minLength: 0)
        }
        .opacity(visible ? 1 : 0)
        .task {
            guard (try? await Task.sleep(for: .milliseconds(120))) != nil else { return }
            withAnimation(FloeMotion.fade) { visible = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}
