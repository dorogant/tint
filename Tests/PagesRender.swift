import AppKit
import SwiftUI

/// Offscreen renders of the Mix, Friends and Stats pages, in English and
/// Ukrainian at a narrow and a wide width, each in the states a person meets:
/// the questionnaire, a mix that's playing, a mix that couldn't start; friends
/// listening, idle, new and missing, and nobody yet; stats with a month of
/// history, with one day and with none. Everything the pages talk to is a
/// stand-in: no ReccoBeats, ListenBrainz, Spotify, player or real settings.
@main
@MainActor
struct PagesRender {
    static let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FLOE_PAGES_DIR"] ?? "/tmp/tint-pages")
    static var only: Set<String>?

    static func main() async {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        only = ProcessInfo.processInfo.environment["FLOE_PAGES_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        FixtureProtocol.install()
        let api = WebAPI(user: UserTokenProvider(), tokens: FixtureTokens(), http: FixtureProtocol.session)
        let library = LibraryModel(api: api)
        await library.refresh()
        let player = PlayerModel()

        for (language, width) in [("en", 1100.0), ("uk", 700.0)] {
            // FloeSnapshotDir puts flat tints where Liquid Glass would be, which an offscreen render can't draw.
            UserDefaults.standard.setVolatileDomain(["appLanguage": language, "FloeSnapshotDir": directory.path], forName: UserDefaults.argumentDomain)
            func shoot(_ name: String, _ page: some View, _ models: Models) async {
                if let only, !only.contains(name.split(separator: "-").first.map(String.init) ?? name) { return }
                let view = page
                    .padding(28)
                    .frame(width: width, alignment: .topLeading)
                    .environment(player)
                    .environment(library)
                    .environment(Navigator())
                    .environment(SearchModel())
                    .environment(models.listening)
                    .environment(models.stats)
                    .environment(models.friends)
                    .environment(models.mix)
                    .environment(AppSettings(defaults: TestDefaults.make()))
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.isOnstage, true)
                    .environment(\.windowVisible, true)
                    .environment(\.interfaceScale, InterfaceSize.standard.scale)
                    .environment(\.coverPalette, CoverPalette.fixed("blue"))
                    .preferredColorScheme(.dark)
                    .background(Color(white: 0.09))
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: .darkAqua)
                let window = NSWindow(contentRect: CGRect(x: -30_000, y: -30_000, width: width, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua)
                // Closed by hand below; released by ARC, not a second time by the close.
                window.isReleasedWhenClosed = false
                window.contentView = host
                // Twice: the pages load in tasks that start once they're in a window.
                for _ in 0..<2 {
                    host.frame = CGRect(origin: .zero, size: CGSize(width: width, height: max(200, host.fittingSize.height)))
                    window.setContentSize(host.frame.size)
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    for _ in 0..<8 {
                        host.layoutSubtreeIfNeeded()
                        try? await Task.sleep(for: .milliseconds(80))
                    }
                }
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: rep)
                let url = directory.appendingPathComponent("\(name)-\(language)-\(Int(width)).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print(url.path, host.frame.size)
                window.close()
            }

            // Mix
            await shoot("mix-questions", MixView(), Models())
            let running = Models()
            await running.startMix(mood: .bright)
            await shoot("mix-running", MixView(), running)
            let failed = Models(history: false)
            failed.mix.create()
            await failed.mix.settled()
            await shoot("mix-nothing", MixView(), failed)

            // Friends
            let friends = Models(friendNames: ["mira", "oleh", "anna", "newbie", "ghost"])
            await friends.friends.refresh()
            await shoot("friends-some", FriendsView(), friends)
            await shoot("friends-none", FriendsView(), Models())
            let offline = Models(friendNames: ["mira", "oleh"], offline: true)
            await offline.friends.refresh()
            await shoot("friends-offline", FriendsView(), offline)

            // Stats
            let month = Models()
            await month.listen(days: 30)
            await shoot("stats-month", StatsView(), month)
            let day = Models()
            await day.listen(days: 1)
            await shoot("stats-day", StatsView(), day)
            await shoot("stats-none", StatsView(), Models(history: false))
        }
    }

    /// One scenario's models, each with its own stand-ins and settings.
    @MainActor final class Models {
        let listening: ListeningRecorder
        let history = ListeningHistory(file: nil)
        let stats = StatsModel(defaults: TestDefaults.make())
        let friends: FriendsModel
        let mix: MixModel
        let catalog = StubCatalog()
        let songs = StubLibrary()
        let fake = FakePlayer()

        init(history: Bool = true, friendNames: [String] = [], offline: Bool = false) {
            listening = ListeningRecorder(history: self.history)
            let defaults = TestDefaults.make()
            defaults.set(friendNames, forKey: "friendsListenBrainzNames")
            friends = FriendsModel(defaults: defaults, client: ListenBrainzClient(transport: PageListenBrainz(offline: offline), clock: InstantClock()))
            if history { songs.plays = (0..<8).map { (id: tid("seed", $0), secondsAgo: 1800 * Double($0 + 1)) } }
            // Real titles from a captured answer, so the rows read like a mix.
            catalog.respond = { _, fetch in fetch % 2 == 0 ? MixFixtures.pop : MixFixtures.calm }
            let songs = songs
            mix = MixModel(catalog: catalog, library: songs, defaults: TestDefaults.make(), now: { songs.now })
            mix.attach(fake)
        }

        func startMix(mood: MixRecipe.Mood) async {
            mix.draft.mood = mood
            mix.create()
            await mix.settled()
            mix.playerChanged(fake.begin())
            await mix.settled()
        }

        /// A listener's month: a few artists, some loved more than others, more on some days.
        func listen(days: Int) async {
            let artists = ["Tame Impala", "Röyksopp", "Океан Ельзи", "Radiohead", "Khruangbin", "ДахаБраха", "Air"]
            let calendar = Calendar.current
            let now = Date()
            var number = 0
            for day in 0..<days {
                let plays = days == 1 ? 6 : 3 + (day * 7) % 11
                for index in 0..<plays {
                    number += 1
                    let artist = artists[(number * number + day) % artists.count % (3 + number % 5)]
                    let song = (number * 5 + day) % 9
                    let at = calendar.date(byAdding: .minute, value: -(day * 24 * 60 + index * 47 + 30), to: now) ?? now
                    await history.record(Play(uri: "spotify:track:\(tid("p\(artists.firstIndex(of: artist) ?? 0)s", song))", name: "Song \(song + 1)", artists: [artist],
                                              artistURIs: ["spotify:artist:\(tid("a", artists.firstIndex(of: artist) ?? 0))"], album: "Album", cover: nil,
                                              durationMs: 215_000, playedAt: at, listenedSeconds: 60 + (number * 37) % 160))
                }
            }
        }
    }
}

/// A small ListenBrainz answering from the captured fixtures: one friend
/// listening now, one who last listened a while ago, one whose songs have no
/// Spotify link, one who hasn't listened yet and one who doesn't exist.
struct PageListenBrainz: ListenBrainzTransport {
    let offline: Bool

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if offline { throw URLError(.notConnectedToInternet) }
        let path = request.url?.path ?? ""
        let name = path.split(separator: "/").drop { $0 != "user" }.dropFirst().first.map(String.init) ?? ""
        var status = 200
        var body = ""
        if name == "ghost" {
            (status, body) = (404, FriendsFixtures.noSuchUser)
        } else if path.hasSuffix("/playing-now") {
            body = name == "mira" ? FriendsFixtures.playingNow : FriendsFixtures.nothingPlaying
        } else if path.hasSuffix("/listens") {
            switch name {
            case "mira": body = FriendsFixtures.listensFromSpotify
            case "oleh": body = FriendsFixtures.listensMapped
            case "anna": body = FriendsFixtures.listensUnmapped
            default: body = #"{"payload":{"count":0,"listens":[],"user_id":"newbie"}}"#
            }
        } else if path.contains("/stats/") {
            if name == "mira" { body = FriendsFixtures.topArtistsThisWeek } else if name == "oleh" { body = FriendsFixtures.topArtistsLastWeek } else { status = 204 }
        } else if path.hasSuffix("/listen-count") {
            body = FriendsFixtures.listenCount
        } else if path.hasSuffix("/following") {
            body = FriendsFixtures.following
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/2", headerFields: FriendsFixtures.headers)!)
    }
}

/// Pacing that doesn't wait, so a page of friends loads at once.
final class InstantClock: PacingClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    var now: TimeInterval { lock.withLock { time } }
    func sleep(for seconds: TimeInterval) async throws { lock.withLock { time += seconds } }
}
