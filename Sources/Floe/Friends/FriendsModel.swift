import Foundation
import Observation

/// Someone on the Friends page and what ListenBrainz last said of their listening.
struct Friend: Equatable, Sendable, Identifiable {
    enum Problem: Equatable, Sendable {
        /// ListenBrainz has no account by this name (any more).
        case noSuchUser
        /// The account doesn't show its listening.
        case hidden
        /// No answer at all: offline, or ListenBrainz can't be reached.
        case network
        /// ListenBrainz asked to slow down for longer than a pass can wait.
        case busy
        case service(Int)

        init(_ failure: ListenBrainzClient.Failure) {
            switch failure {
            case .noSuchUser: self = .noSuchUser
            case .hidden: self = .hidden
            case .network: self = .network
            case .rateLimited: self = .busy
            case let .http(status): self = .service(status)
            case .malformed: self = .service(0)
            }
        }
    }

    enum State: Equatable, Sendable { case loading, loaded, failed(Problem) }

    /// As it was typed or as ListenBrainz listed it; names differing only in case are one account.
    let name: String
    var id: String { name.lowercased() }
    var state = State.loading
    var playing: FriendListen?
    /// Newest first.
    var recent: [FriendListen] = []
    /// When `playing` and `recent` were last answered.
    var updated: Date?
    var topArtists: [FriendArtist] = []
    /// The week `topArtists` are of; nil while ListenBrainz has worked out neither.
    var topRange: ListenBrainzClient.StatsRange?
    /// Every listen the account has, ever.
    var listenCount: Int?
    /// When the weekly numbers were last asked for.
    var statsAsked: Date?

    /// A song reported as playing is believed for this long after the answer.
    /// Offline, or with the page long closed, "listening now" would otherwise stay up for hours.
    static let believed: TimeInterval = 5 * 60

    func isListening(asOf date: Date) -> Bool {
        playing != nil && updated.map { date.timeIntervalSince($0) < Self.believed } ?? false
    }

    /// When they were last known to listen.
    var lastActive: Date? { playing != nil ? updated : recent.first?.listenedAt }
    /// The song the card leads with.
    var headline: FriendListen? { playing ?? recent.first }
    /// The songs before the headline. Many players report a song as listened
    /// while it still plays, so the newest listen is often the one playing.
    var earlier: [FriendListen] {
        guard let playing else { return Array(recent.dropFirst()) }
        if let first = recent.first, first.title == playing.title, first.artist == playing.artist { return Array(recent.dropFirst()) }
        return recent
    }

    /// The ones listening now first, then by how recently they listened, then
    /// those nothing is known of. Names settle ties, so the order holds still between refreshes.
    static func ordered(_ friends: [Friend], asOf date: Date) -> [Friend] {
        func rank(_ friend: Friend) -> Int { friend.isListening(asOf: date) ? 0 : (friend.lastActive == nil ? 2 : 1) }
        return friends.sorted { a, b in
            let (rankA, rankB) = (rank(a), rank(b))
            if rankA != rankB { return rankA < rankB }
            if rankA == 1, let lastA = a.lastActive, let lastB = b.lastActive, lastA != lastB { return lastA > lastB }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

/// The Friends page's list and its refreshing. Friends are ListenBrainz
/// account names kept in the settings; what they listen to is asked of
/// ListenBrainz's public API, only while the page asks for it (`keepFresh`
/// runs in the page's task and ends with it), one friend after another through
/// the client's single paced line. The names are the only thing sent.
@MainActor
@Observable
final class FriendsModel {
    enum AddProblem: Equatable {
        case noSuchUser(String), alreadyAdded(String), full
        case failed(Friend.Problem)
    }

    /// Each friend costs two requests a pass at one request a second, so this
    /// many are a pass of under a minute.
    static let limit = 25
    /// Between passes while the page shows.
    static var interval: TimeInterval = 60
    /// A pass this recent isn't repeated when the page is opened again.
    static var settled: TimeInterval { min(15, interval / 4) }
    /// ListenBrainz works its statistics out about once a day.
    static var statsLife: TimeInterval = 3 * 3600
    static let recentCount = 5
    static let topCount = 5

    /// In the order they were added; the page shows `ordered`.
    private(set) var friends: [Friend]
    private(set) var isRefreshing = false
    /// The moment the page's "now" and "ago" are counted from: the last pass, or the page opening.
    private(set) var asOf: Date
    /// What stopped the last pass for everyone: `.network` or `.busy`.
    private(set) var problem: Friend.Problem?
    private(set) var isAdding = false
    var addProblem: AddProblem?
    /// The listener's own ListenBrainz name, if they gave one: only to offer the people it follows.
    private(set) var myName: String
    /// The names `myName` follows; nil until asked.
    private(set) var followed: [String]?
    private(set) var followedProblem: Friend.Problem?
    private(set) var isLoadingFollowed = false
    /// Goes up when a refresh is asked for by hand, to restart the page's task.
    private(set) var refreshRequests = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let client: ListenBrainzClient
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var lastPass: Date?
    @ObservationIgnored private var forced = false

    private static let namesKey = "friendsListenBrainzNames"
    private static let myNameKey = "friendsMyListenBrainzName"

    init(defaults: UserDefaults = .standard, client: ListenBrainzClient = ListenBrainzClient(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.client = client
        self.now = now
        friends = Self.unique(defaults.stringArray(forKey: Self.namesKey) ?? []).prefix(Self.limit).map { Friend(name: $0) }
        myName = defaults.string(forKey: Self.myNameKey) ?? ""
        asOf = now()
    }

    var ordered: [Friend] { Friend.ordered(friends, asOf: asOf) }
    var isFull: Bool { friends.count >= Self.limit }

    /// The people `myName` follows who aren't friends here yet.
    var suggestions: [String] {
        let known = Set(friends.map(\.id) + [myName.lowercased()])
        return Self.unique(followed ?? []).filter { !known.contains($0.lowercased()) }
    }

    // MARK: - The list

    /// A name as people give it: bare, with an @, or as the address of a ListenBrainz profile.
    nonisolated static func cleaned(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = name.range(of: "listenbrainz.org/user/", options: .caseInsensitive) {
            name = String(name[range.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" })
            name = name.removingPercentEncoding ?? name
        }
        if name.hasPrefix("@") { name.removeFirst() }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.map(cleaned).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Asks ListenBrainz about the name before keeping it. True when it was added.
    @discardableResult
    func add(_ raw: String) async -> Bool {
        let name = Self.cleaned(raw)
        guard !name.isEmpty, !isAdding else { return false }
        addProblem = nil
        if let known = friends.first(where: { $0.id == name.lowercased() }) {
            addProblem = .alreadyAdded(known.name)
            return false
        }
        guard !isFull else { addProblem = .full; return false }
        isAdding = true
        defer { isAdding = false }
        do {
            // The check is also the first of the friend's two answers.
            let playing = try await client.playingNow(name)
            guard !friends.contains(where: { $0.id == name.lowercased() }), !isFull else { return false }
            friends.append(Friend(name: name, playing: playing, updated: now()))
            save()
            try? await loadActivity(name)
            try? await loadStats(name)
            return true
        } catch let failure as ListenBrainzClient.Failure {
            addProblem = failure == .noSuchUser ? .noSuchUser(name) : .failed(Friend.Problem(failure))
        } catch {}
        return false
    }

    func remove(_ friend: Friend) {
        friends.removeAll { $0.id == friend.id }
        save()
    }

    /// Adds the people `myName` follows, as many as there's room for. They
    /// come from ListenBrainz's own list, so none is checked first.
    func addSuggestions() {
        let room = Self.limit - friends.count
        guard room > 0 else { return }
        friends += suggestions.prefix(room).map { Friend(name: $0) }
        save()
        requestRefresh()
    }

    private func save() {
        defaults.set(friends.map(\.name), forKey: Self.namesKey)
    }

    /// Keeps the listener's own name and asks whom it follows.
    func setMyName(_ raw: String) async {
        let name = Self.cleaned(raw)
        myName = name
        defaults.set(name, forKey: Self.myNameKey)
        followed = nil
        followedProblem = nil
        if !name.isEmpty { await loadFollowed() }
    }

    private func loadFollowed() async {
        let name = myName
        guard !name.isEmpty, !isLoadingFollowed else { return }
        isLoadingFollowed = true
        defer { isLoadingFollowed = false }
        do {
            let names = try await client.following(name)
            if name == myName { followed = names }
        } catch let failure as ListenBrainzClient.Failure {
            if name == myName { followedProblem = Friend.Problem(failure) }
        } catch {}
    }

    // MARK: - Refreshing

    /// A refresh by hand: the page's task starts over and passes at once.
    func requestRefresh() {
        forced = true
        refreshRequests += 1
    }

    /// Passes now and then every `interval`, until the task it runs in is
    /// cancelled. The page runs it only while it is the page showing, in a
    /// visible window of the active app, so nothing is asked in the background.
    func keepFresh() async {
        asOf = now()
        while !Task.isCancelled {
            if !forced, let lastPass {
                let age = now().timeIntervalSince(lastPass)
                // Just refreshed (the page was left and opened again): wait out the rest.
                if age < Self.settled, (try? await Task.sleep(for: .seconds(Self.interval - age))) == nil { return }
            }
            forced = false
            // A pass the last task started may still be letting go of its request.
            while isRefreshing {
                guard (try? await Task.sleep(for: .milliseconds(50))) != nil else { return }
            }
            await refresh()
        }
    }

    /// One pass: every friend's playing song and latest listens first, since
    /// that is what the page is for, then the weekly numbers that have gone
    /// stale. A pass that can't reach ListenBrainz stops at once rather than
    /// failing once per friend.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        var stopped: Friend.Problem?
        do {
            for name in friends.map(\.name) {
                do {
                    try await loadActivity(name)
                } catch let failure as ListenBrainzClient.Failure where failure != .network && !failure.isRateLimit {
                    update(name) { friend in
                        friend.state = .failed(Friend.Problem(failure))
                        // A name that is gone has nothing to show; a hiccup keeps what was there.
                        if failure == .noSuchUser || failure == .hidden { friend.playing = nil; friend.recent = [] }
                    }
                }
            }
            for friend in friends where friend.state == .loaded && friend.statsAsked.map({ now().timeIntervalSince($0) >= Self.statsLife }) ?? true {
                do {
                    try await loadStats(friend.name)
                } catch let failure as ListenBrainzClient.Failure where failure != .network && !failure.isRateLimit {
                    update(friend.name) { $0.statsAsked = now() }
                }
            }
            // Once a run, so the offer is there without being asked for.
            if followed == nil, followedProblem == nil, !myName.isEmpty { await loadFollowed() }
        } catch let failure as ListenBrainzClient.Failure {
            stopped = Friend.Problem(failure)
        } catch {
            // Cancelled: the page went away mid-pass. The next one starts from the top.
            return
        }
        if let stopped {
            for friend in friends where friend.state == .loading { update(friend.name) { $0.state = .failed(stopped) } }
        }
        problem = stopped
        asOf = now()
        lastPass = asOf
    }

    private func loadActivity(_ name: String) async throws {
        let playing = try await client.playingNow(name)
        let recent = try await client.listens(name, count: Self.recentCount)
        update(name) { friend in
            friend.playing = playing
            friend.recent = recent
            friend.updated = now()
            friend.state = .loaded
        }
    }

    /// This week's artists, or last week's while this week has none yet
    /// (statistics are a day behind, so every Monday would be empty), and the
    /// account's count of listens.
    private func loadStats(_ name: String) async throws {
        var range = ListenBrainzClient.StatsRange.thisWeek
        var artists = try await client.topArtists(name, range: range, count: Self.topCount) ?? []
        if artists.isEmpty {
            range = .lastWeek
            artists = try await client.topArtists(name, range: range, count: Self.topCount) ?? []
        }
        let count = try await client.listenCount(name)
        update(name) { friend in
            friend.topArtists = artists
            friend.topRange = artists.isEmpty ? nil : range
            friend.listenCount = count
            friend.statsAsked = now()
        }
    }

    /// Changes a friend who is still in the list; an answer for one removed meanwhile is dropped.
    private func update(_ name: String, _ change: (inout Friend) -> Void) {
        guard let index = friends.firstIndex(where: { $0.name == name }) else { return }
        var friend = friends[index]
        change(&friend)
        if friend != friends[index] { friends[index] = friend }
    }
}

private extension ListenBrainzClient.Failure {
    var isRateLimit: Bool {
        if case .rateLimited = self { true } else { false }
    }
}
