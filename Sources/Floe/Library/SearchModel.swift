import Foundation
import Observation

/// Owns search results separately from view lifetime. A revision prevents late
/// requests (including "Show more") from mixing songs from different queries.
@MainActor
@Observable
final class SearchModel {
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            revision += 1
            results = nil
            songs = []
            error = nil
            canLoadMoreSongs = false
            isSearching = !query.isEmpty
            isLoadingMore = false
        }
    }
    private(set) var results: SearchResults?
    private(set) var songs: [Track] = []
    private(set) var canLoadMoreSongs = false
    private(set) var isSearching = false
    private(set) var isLoadingMore = false
    private(set) var error: String?
    @ObservationIgnored private var revision = 0
    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    func search(_ api: WebAPI) async {
        let query = query
        let revision = revision
        guard !query.isEmpty else { isSearching = false; return }
        isSearching = true
        defer { if revision == self.revision { isSearching = false } }
        do {
            try await Task.sleep(for: .milliseconds(300))
            let found = try await api.search(query)
            guard !Task.isCancelled, revision == self.revision else { return }
            results = found
            songs = found.tracks?.items ?? []
            canLoadMoreSongs = found.tracks?.next != nil
            error = nil
        } catch {
            if !Task.isCancelled, revision == self.revision { self.error = error.localizedDescription }
        }
    }

    func loadMoreSongs(_ api: WebAPI) async {
        guard canLoadMoreSongs, !isLoadingMore, !isSearching else { return }
        let revision = revision
        isLoadingMore = true
        defer { if revision == self.revision { isLoadingMore = false } }
        do {
            let more = try await api.search(query, offset: songs.count)
            guard !Task.isCancelled, revision == self.revision else { return }
            songs += more.tracks?.items ?? []
            canLoadMoreSongs = more.tracks?.next != nil
        } catch {
            if !Task.isCancelled, revision == self.revision { self.error = error.localizedDescription }
        }
    }
}
