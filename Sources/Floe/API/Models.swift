import Foundation

// Web API objects, decoded with `.convertFromSnakeCase`. Only the fields Tint uses.
// Decoding is lenient: Spotify returns `null` entries in some lists, local files
// without IDs, and (since 2026) `items`/`item` where older responses said `tracks`/`track`.

struct SpotifyImage: Codable, Hashable, Sendable {
    let url: URL
    let width: Int?
    let height: Int?
}

struct UserProfile: Codable, Sendable {
    let id: String
    let displayName: String?
    let images: [SpotifyImage]?
}

struct ArtistRef: Codable, Hashable, Sendable, Identifiable {
    let id: String?
    let uri: String?
    let name: String
}

struct AlbumRef: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let uri: String
    let name: String
    let images: [SpotifyImage]?
    let artists: [ArtistRef]?
    let releaseDate: String?
    let totalTracks: Int?
    let albumType: String?

    var year: String? { releaseDate.map { String($0.prefix(4)) } }
}

struct Track: Codable, Hashable, Sendable, Identifiable {
    let id: String?
    let uri: String
    let name: String
    let durationMs: Int
    let explicit: Bool?
    let artists: [ArtistRef]
    let album: AlbumRef?
    let trackNumber: Int?
    let discNumber: Int?
    let isLocal: Bool?
    let isPlayable: Bool?

    var artistLine: String { artists.map(\.name).joined(separator: ", ") }
    /// Liking and context playback only make sense for catalogue tracks.
    var isCatalogTrack: Bool { uri.hasPrefix("spotify:track:") }
}

struct PlaylistOwner: Codable, Hashable, Sendable {
    let id: String
    let displayName: String?
}

struct PlaylistRef: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let uri: String
    let name: String
    let description: String?
    let images: [SpotifyImage]?
    let owner: PlaylistOwner
    let collaborative: Bool?
    /// `{ total }` under `items` (2026+) or `tracks` (before).
    let itemCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, uri, name, description, images, owner, collaborative, items, tracks
    }

    private struct Count: Decodable { let total: Int? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        uri = try c.decode(String.self, forKey: .uri)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        images = try? c.decodeIfPresent([SpotifyImage].self, forKey: .images)
        owner = try c.decode(PlaylistOwner.self, forKey: .owner)
        collaborative = try c.decodeIfPresent(Bool.self, forKey: .collaborative)
        let count = (try? c.decodeIfPresent(Count.self, forKey: .items))
            ?? (try? c.decodeIfPresent(Count.self, forKey: .tracks))
        itemCount = count?.total
    }
}

struct PlaylistItem: Decodable, Sendable {
    let addedAt: Date?
    let track: Track?

    enum CodingKeys: String, CodingKey { case addedAt, item, track }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        addedAt = try? c.decodeIfPresent(Date.self, forKey: .addedAt)
        // Episodes and broken entries fail to decode as Track; skip them.
        track = (try? c.decodeIfPresent(Track.self, forKey: .item))
            ?? (try? c.decodeIfPresent(Track.self, forKey: .track))
    }
}

struct SavedTrack: Decodable, Sendable {
    let addedAt: Date?
    let track: Track
}

struct SavedAlbum: Decodable, Sendable {
    let album: AlbumRef
}

struct Artist: Decodable, Sendable, Identifiable {
    let id: String
    let uri: String
    let name: String
    let images: [SpotifyImage]?
    let genres: [String]?
}

/// Enough of an artist to list and un-hide it in Settings without a request.
struct HiddenArtist: Codable, Hashable, Identifiable {
    let uri: String
    let name: String
    var id: String { uri }
}

struct Album: Decodable, Sendable {
    let id: String
    let uri: String
    let name: String
    let images: [SpotifyImage]?
    let artists: [ArtistRef]
    let releaseDate: String?
    let albumType: String?
    let totalTracks: Int?
    let tracks: Paging<Track>

    var ref: AlbumRef {
        AlbumRef(id: id, uri: uri, name: name, images: images, artists: artists,
                 releaseDate: releaseDate, totalTracks: totalTracks, albumType: albumType)
    }
}

struct PlayHistory: Decodable, Sendable {
    struct Context: Decodable, Sendable {
        let type: String
        let uri: String
    }

    let track: Track
    let context: Context?
}

struct Paging<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
    let next: String?
    let total: Int?
    let offset: Int?

    enum CodingKeys: String, CodingKey { case items, next, total, offset }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try c.decodeIfPresent([Lossy<Item>].self, forKey: .items) ?? []).compactMap(\.value)
        next = try c.decodeIfPresent(String.self, forKey: .next)
        total = try c.decodeIfPresent(Int.self, forKey: .total)
        offset = try c.decodeIfPresent(Int.self, forKey: .offset)
    }
}

struct SearchResults: Decodable, Sendable {
    let tracks: Paging<Track>?
    let artists: Paging<Artist>?
    let albums: Paging<AlbumRef>?
    let playlists: Paging<PlaylistRef>?
}

/// Decodes `T` or yields nil (for `null` entries and shapes we can't use).
struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(T.self)
    }
}

extension Array where Element == SpotifyImage {
    /// The smallest image at least `pixels` wide, else the largest available.
    func best(forPixels pixels: CGFloat) -> URL? {
        let sorted = self.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        return (sorted.first { CGFloat($0.width ?? 0) >= pixels } ?? sorted.last)?.url
    }
}
