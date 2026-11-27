import SwiftUI

/// A mix made to order. Before one exists the page is a questionnaire: where
/// to start from, whether liked and already-heard songs may appear, the mood,
/// the energy and the length. While one plays, the page shows what's next and
/// the controls that change it. `MixModel` does the choosing and belongs to
/// the app, so the mix goes on with this page closed.
struct MixView: View {
    @Environment(MixModel.self) private var mix
    @Environment(\.interfaceScale) private var scale
    /// Room for a question and its answers on one line.
    @ViewState private var wide = true

    var body: some View {
        let factor = scale.factor
        VStack(alignment: .leading, spacing: scale.sectionGap) {
            Text("Mix")
                .floeFont(size: 32, weight: .heavy)
                .tracking(-0.6)
                .accessibilityAddTraits(.isHeader)
                .reveal("title")
            Group {
                if mix.isActive {
                    RunningMix(wide: wide)
                } else {
                    MixQuestions(wide: wide)
                }
            }
            .reveal("body", order: 1)
        }
        .revealScope()
        .onGeometryChange(for: Bool.self) { $0.size.width / factor >= 760 } action: { wide = $0 }
    }
}

// MARK: - The questionnaire

private struct MixQuestions: View {
    let wide: Bool
    @Environment(MixModel.self) private var mix
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        @Bindable var mix = mix
        VStack(alignment: .leading, spacing: scale(20)) {
            if let ending = mix.ending {
                MixNotice(systemImage: "checkmark.circle", tint: Theme.secondary,
                          text: ending == .complete ? "The last mix played to its end." : "The last mix stopped when something else started playing.")
            }
            if let problem = mix.problem {
                MixNotice(systemImage: "exclamationmark.triangle", tint: .orange, text: LocalizedStringKey(MixText.problem(problem)))
            }
            VStack(alignment: .leading, spacing: 0) {
                Question(title: "Start from", detail: "The songs the mix looks for neighbours of.", wide: wide) {
                    Picker("Start from", selection: $mix.draft.source) {
                        Text("Today's listening").tag(MixRecipe.Source.today)
                        Text("This week's").tag(MixRecipe.Source.week)
                        Text("Liked songs").tag(MixRecipe.Source.liked)
                    }
                }
                Question(title: "Liked songs", detail: "Whether songs you've already saved may appear.", wide: wide) {
                    Picker("Liked songs", selection: $mix.draft.liked) {
                        Text("Leave out").tag(MixRecipe.Liked.leaveOut)
                        Text("Allow").tag(MixRecipe.Liked.allow)
                        Text("Only liked").tag(MixRecipe.Liked.only)
                    }
                }
                Question(title: "Songs I've heard", detail: "Anything already played in Tint on this Mac.", wide: wide) {
                    Picker("Songs I've heard", selection: $mix.draft.skipHeard) {
                        Text("Leave out").tag(true)
                        Text("Allow").tag(false)
                    }
                }
                Question(title: "Mood", detail: "From sad to happy.", wide: wide) {
                    Picker("Mood", selection: $mix.draft.mood) {
                        ForEach(MixRecipe.Mood.allCases, id: \.self) { Text(LocalizedStringKey(MixText.mood($0))).tag($0) }
                    }
                }
                Question(title: "Energy", detail: "From calm to driving.", wide: wide) {
                    Picker("Energy", selection: $mix.draft.energy) {
                        ForEach(MixRecipe.Energy.allCases, id: \.self) { Text(LocalizedStringKey(MixText.energy($0))).tag($0) }
                    }
                }
                Question(title: "Length", detail: "How long the mix runs.", wide: wide, last: true) {
                    Picker("Length", selection: $mix.draft.length) {
                        Text("30 min").tag(MixRecipe.Length.halfHour)
                        Text("1 hour").tag(MixRecipe.Length.hour)
                        Text("2 hours").tag(MixRecipe.Length.twoHours)
                        Text("Keep going").tag(MixRecipe.Length.endless)
                    }
                }
            }
            .mixPanel()

            HStack(spacing: scale(14)) {
                if mix.phase == .preparing {
                    ProgressView().controlSize(.small)
                    Text("Choosing songs…").floeFont(size: 13).foregroundStyle(Theme.secondary)
                } else {
                    PlayPill(title: "Create mix") { mix.create() }
                }
            }
            .frame(minHeight: scale(38))

            Text("Suggestions come from ReccoBeats, an independent service. The songs the mix starts from are sent there; nothing about your account is.")
                .floeFont(size: 12)
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(mix.phase == .preparing)
    }
}

/// One question: its name and a word on it, then its answers, beside it where
/// there's room and under it where there isn't.
private struct Question<Answers: View>: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let wide: Bool
    var last = false
    @ViewBuilder var answers: Answers
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        let label = VStack(alignment: .leading, spacing: scale(2)) {
            Text(title).floeFont(size: 13, weight: .semibold)
            Text(detail).floeFont(size: 12).foregroundStyle(Theme.secondary)
        }
        let picker = answers.pickerStyle(.segmented).labelsHidden().fixedSize()
        VStack(spacing: 0) {
            Group {
                if wide {
                    HStack(spacing: scale(16)) {
                        label
                        Spacer(minLength: scale(12))
                        picker
                    }
                } else {
                    VStack(alignment: .leading, spacing: scale(8)) {
                        label
                        picker
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, scale(14))
            .padding(.vertical, scale(11))
            if !last { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
        }
    }
}

// MARK: - A mix that's playing

private struct RunningMix: View {
    let wide: Bool
    @Environment(MixModel.self) private var mix
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: scale(20)) {
            // Said only when the mix couldn't start from what was asked.
            if let origin = mix.origin, origin != MixText.asked(mix.recipe.source) {
                MixNotice(systemImage: "info.circle", tint: Theme.secondary, text: LocalizedStringKey(MixText.origin(origin)))
            }
            if mix.likedUnchecked {
                MixNotice(systemImage: "exclamationmark.triangle", tint: .orange,
                          text: "Spotify couldn't say which of these songs you've liked, so some liked songs may appear.")
            }
            if let problem = mix.problem {
                HStack(spacing: scale(12)) {
                    MixNotice(systemImage: "exclamationmark.triangle", tint: .orange, text: LocalizedStringKey(MixText.problem(problem)))
                    MixButton(title: "Try again") { mix.retry() }
                }
            }
            controls
            VStack(alignment: .leading, spacing: scale.headerGap) {
                SectionHeader(title: "Now") { progress }
                if let current = mix.current {
                    MixSongRow(song: current, state: .playing)
                } else {
                    Text("Starting the first song…").floeFont(size: 13).foregroundStyle(Theme.secondary)
                }
            }
            VStack(alignment: .leading, spacing: scale.headerGap) {
                SectionHeader(title: "Next") {
                    if mix.isChoosing {
                        HStack(spacing: scale(8)) {
                            ProgressView().controlSize(.small)
                            Text("Finding more songs…").floeFont(size: 12).foregroundStyle(Theme.secondary)
                        }
                    }
                }
                if mix.queued.isEmpty && mix.upcoming.isEmpty {
                    Text(mix.isChoosing ? "Looking for songs that fit." : (mix.lengthReached ? "That's the whole mix." : "Nothing more fits these answers yet."))
                        .floeFont(size: 13)
                        .foregroundStyle(Theme.secondary)
                } else {
                    VStack(spacing: 2 * scale.plate) {
                        ForEach(mix.queued) { MixSongRow(song: $0, state: .queued) }
                        ForEach(mix.upcoming.prefix(MixView.shown)) { MixSongRow(song: $0, state: .upcoming) }
                    }
                }
            }
        }
    }

    /// The live controls: each press chooses again everything Spotify doesn't hold yet.
    private var controls: some View {
        let recipe = mix.recipe
        return VStack(alignment: .leading, spacing: scale(12)) {
            let steps = Group {
                Stepper2(title: "Mood", value: LocalizedStringKey(MixText.mood(recipe.mood)),
                         down: "Sadder", up: "Happier",
                         canDown: recipe.mood != .sad, canUp: recipe.mood != .happy,
                         onDown: { mix.steer { $0.mood = $0.mood.sadder } }, onUp: { mix.steer { $0.mood = $0.mood.happier } })
                Stepper2(title: "Energy", value: LocalizedStringKey(MixText.energy(recipe.energy)),
                         down: "Calmer", up: "More energy",
                         canDown: recipe.energy != .calm, canUp: recipe.energy != .energetic,
                         onDown: { mix.steer { $0.energy = $0.energy.calmer } }, onUp: { mix.steer { $0.energy = $0.energy.livelier } })
            }
            if wide {
                HStack(alignment: .top, spacing: scale(28)) { steps }
            } else {
                VStack(alignment: .leading, spacing: scale(12)) { steps }
            }
            HStack(spacing: scale(10)) {
                if recipe.liked != .only {
                    MixSwitch(title: "No liked songs", isOn: recipe.liked == .leaveOut) { on in
                        mix.steer { $0.liked = on ? .leaveOut : .allow }
                    }
                } else {
                    Badge(text: "Only liked songs")
                }
                MixSwitch(title: "Nothing I've heard", isOn: recipe.skipHeard) { on in mix.steer { $0.skipHeard = on } }
                Spacer(minLength: 0)
                MixButton(title: "Stop mix", systemImage: "stop.fill") { mix.stop() }
            }
            Text("A change is heard after the songs Spotify already holds: two at most.")
                .floeFont(size: 12)
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(scale(14))
        .mixPanel()
    }

    @ViewBuilder private var progress: some View {
        if let length = mix.lengthMs {
            Text(verbatim: "\(Format.duration(ms: Double(mix.playedMs))) / \(Format.duration(ms: Double(length)))")
                .monospacedDigit().floeFont(size: 12).foregroundStyle(Theme.secondary)
        } else {
            Text("Keeps going").floeFont(size: 12).foregroundStyle(Theme.secondary)
        }
    }
}

extension MixView {
    /// Rows of what's next: enough to see where the mix is heading.
    static let shown = 12
}

/// A label with a step down and a step up beside it: "Sadder · Mellow · Happier".
private struct Stepper2: View {
    let title: LocalizedStringKey
    let value: LocalizedStringKey
    let down: LocalizedStringKey
    let up: LocalizedStringKey
    let canDown: Bool
    let canUp: Bool
    let onDown: () -> Void
    let onUp: () -> Void
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HStack(spacing: scale(10)) {
            Text(title).floeFont(size: 13, weight: .semibold).frame(minWidth: scale(52), alignment: .leading)
            MixButton(title: down, systemImage: "minus", action: onDown).disabled(!canDown).opacity(canDown ? 1 : 0.4)
            Text(value)
                .floeFont(size: 13, weight: .medium)
                .frame(minWidth: scale(74))
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(value))
            MixButton(title: up, systemImage: "plus", action: onUp).disabled(!canUp).opacity(canUp ? 1 : 0.4)
        }
    }
}

private struct MixButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    let action: () -> Void
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        Button(action: action) {
            HStack(spacing: scale(5)) {
                if let systemImage { Image(systemName: systemImage).floeFont(size: 10, weight: .bold) }
                Text(title)
            }
            .floeFont(size: 12.5, weight: .semibold)
            .padding(.horizontal, scale(14))
            .padding(.vertical, scale(6))
            .glassControl(in: .capsule)
        }
        .buttonStyle(.floe)
    }
}

/// A switch drawn as a capsule that fills when on, in the row with the buttons.
private struct MixSwitch: View {
    let title: LocalizedStringKey
    let isOn: Bool
    let set: (Bool) -> Void
    @Environment(\.coverPalette) private var palette
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        Button { set(!isOn) } label: {
            HStack(spacing: scale(6)) {
                Image(systemName: isOn ? "checkmark" : "circle").floeFont(size: 10, weight: .bold)
                Text(title)
            }
            .floeFont(size: 12.5, weight: .semibold)
            .foregroundStyle(isOn ? palette.onAccent : .white)
            .padding(.horizontal, scale(14))
            .padding(.vertical, scale(6))
            .glassControl(tint: isOn ? palette.accent : nil, in: .capsule)
        }
        .buttonStyle(.floe)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct MixNotice: View {
    let systemImage: String
    let tint: Color
    let text: LocalizedStringKey
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HStack(spacing: scale(10)) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .floeFont(size: 12)
        .padding(.horizontal, scale(12))
        .padding(.vertical, scale(9))
        .mixPanel(radius: 10)
    }
}

private extension View {
    func mixPanel(radius: CGFloat = 12) -> some View {
        modifier(MixPanel(radius: radius))
    }
}

private struct MixPanel: ViewModifier {
    let radius: CGFloat
    @Environment(\.interfaceScale) private var scale

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: scale(radius), style: .continuous)
        content
            .background(.white.opacity(0.05), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.05)))
    }
}

/// A song of the mix. ReccoBeats gives its title, artists and length; the
/// cover, and what liking and linking need, are looked up on Spotify when the
/// row comes on screen.
private struct MixSongRow: View {
    enum State { case playing, queued, upcoming }
    let song: MixSong
    let state: State
    @Environment(MixModel.self) private var mix
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryModel.self) private var library
    @Environment(Navigator.self) private var navigator
    @Environment(\.coverPalette) private var palette
    @Environment(\.interfaceScale) private var scale
    @ViewState private var hovering = false

    var body: some View {
        let details = mix.details[song.id]
        let radius = scale(6)
        HStack(spacing: scale(12)) {
            ArtworkView(images: details?.album?.images, size: scale(40), cornerRadius: radius)
            VStack(alignment: .leading, spacing: scale(2)) {
                Text(verbatim: song.title)
                    .floeFont(size: 13, weight: .medium)
                    .foregroundStyle(state == .playing ? palette.highlight : .white)
                Text(verbatim: song.artistLine).floeFont(size: 12).secondaryText(lit: hovering)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if state == .queued {
                Text("In the queue")
                    .floeFont(size: 11, weight: .medium)
                    .foregroundStyle(Theme.tertiary)
                    .help("Spotify already holds this song, so a change of mind comes after it.")
            }
            LikeButton(uri: song.uri, revealed: hovering || state == .playing)
            Text(verbatim: Format.duration(ms: Double(song.durationMs)))
                .monospacedDigit().floeFont(size: 12)
                .secondaryText(lit: hovering)
                .frame(minWidth: scale(36), alignment: .trailing)
            if state == .upcoming {
                Button { mix.remove(song) } label: {
                    Image(systemName: "xmark")
                        .floeFont(size: 10, weight: .bold)
                        .foregroundStyle(.white)
                        .opacity(hovering ? 0.8 : 0.25)
                        .frame(width: scale(22), height: scale(22))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.floe)
                .help("Take this song out of the mix")
                .accessibilityLabel(Text("Take this song out of the mix"))
            } else {
                Color.clear.frame(width: scale(22), height: scale(22))
            }
        }
        .padding(.horizontal, scale(8))
        .frame(height: scale(48))
        .hoverPlate(hovering, radius: scale(8))
        .onHover { hovering = $0 }
        .floeHover(hovering)
        .contextMenu {
            let title: LocalizedStringKey = library.isLiked(song.uri) == true ? "Remove from Liked Songs" : "Save to Liked Songs"
            Button(title) { Task { await library.toggleLike(song.uri) } }
            if let album = details?.album { Button("Go to Album") { navigator.push(.album(album.id)) } }
            if let artist = details?.artists.first, let id = artist.id { Button("Go to Artist") { navigator.push(.artist(id)) } }
            if state == .upcoming {
                Divider()
                Button("Take this song out of the mix") { mix.remove(song) }
            }
            Divider()
            CopySongLinkButton(id: song.id)
        }
        .onAppear {
            mix.wantDetails(for: song)
            library.requestLikedState(song.uri)
        }
    }
}

/// The page's words for the model's values.
enum MixText {
    static func mood(_ mood: MixRecipe.Mood) -> String {
        switch mood {
        case .sad: "Sad"
        case .mellow: "Mellow"
        case .any: "Any"
        case .bright: "Bright"
        case .happy: "Happy"
        }
    }

    static func energy(_ energy: MixRecipe.Energy) -> String {
        switch energy {
        case .calm: "Calm"
        case .any: "Any"
        case .energetic: "Energetic"
        }
    }

    static func asked(_ source: MixRecipe.Source) -> MixModel.Origin {
        switch source {
        case .today: .today
        case .week: .week
        case .liked: .liked
        }
    }

    /// Said when the mix couldn't start from what was asked.
    static func origin(_ origin: MixModel.Origin) -> String {
        switch origin {
        case .today: "This mix started from today's listening."
        case .week: "There wasn't enough listening today, so this mix started from this week's."
        case .recentlyPlayed: "Tint's own history is still thin, so this mix started from what Spotify says you played recently."
        case .liked: "There was no recent listening to start from, so this mix started from your liked songs."
        }
    }

    static func problem(_ problem: MixModel.Problem) -> String {
        switch problem {
        case .nothingToStartFrom: "There's nothing to start from yet: no listening history, nothing recently played and no liked songs."
        case .noLikedSongs: "There are no liked songs to make a mix of."
        case .unknownSongs: "ReccoBeats doesn't know any of the songs this mix would start from. Try another place to start."
        case .nothingFits: "Songs came back, but none fit these answers. Loosen the mood or allow more songs."
        case .cannotPlay: "The first song couldn't be played. Check that Tint is connected to Spotify."
        case .unreachable: "ReccoBeats couldn't be reached. Check the connection and try again."
        case .busy: "ReccoBeats is busy right now. Try again in a moment."
        case .service: "ReccoBeats answered with an error. Try again in a moment."
        case .spotify: "Spotify didn't answer. Try again in a moment."
        }
    }
}
