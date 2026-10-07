import Foundation

struct LyricLine: Equatable, Sendable, Identifiable {
    let id: Int
    let time: TimeInterval
    let text: String
}

/// LRC line timings, including repeated tags and a file-wide millisecond offset.
/// Positive offsets advance the lyrics. Blank timed lines mark instrumental gaps.
enum LRC {
    static func parse(_ text: String) -> [LyricLine] {
        var offset = 0.0
        var lines: [(time: Double, text: String, order: Int)] = []
        for raw in text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var rest = raw.trimmingCharacters(in: .whitespaces)[...]
            var times: [Double] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                if tag.hasPrefix("offset:"), let ms = Double(tag.dropFirst(7)), ms.isFinite {
                    offset = ms / 1000
                } else if let time = timestamp(tag) {
                    times.append(time)
                }
            }
            // Enhanced LRC word timings can still be displayed as line-synced lyrics.
            let words = rest.replacingOccurrences(of: #"<\d+:\d{2}(?:\.\d+)?>"#,
                                                   with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            for time in times { lines.append((time, words, lines.count)) }
        }
        let adjusted: [(time: Double, text: String, order: Int)] = lines.map {
            (time: max(0, $0.time - offset), text: $0.text, order: $0.order)
        }
        let sorted = adjusted.sorted { a, b in a.time == b.time ? a.order < b.order : a.time < b.time }
        return sorted.enumerated().map { index, line in
            LyricLine(id: index, time: line.time, text: line.text)
        }
    }

    private static func timestamp(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].allSatisfy(\.isNumber),
              let minutes = Double(parts[0]), let seconds = Double(parts[1]),
              minutes.isFinite, seconds.isFinite, seconds >= 0, seconds < 60 else { return nil }
        let time = minutes * 60 + seconds
        return time.isFinite ? time : nil
    }

    /// Last timestamp at or before the position, also works after backward seeks.
    static func activeIndex(in lines: [LyricLine], at seconds: Double) -> Int? {
        var low = 0, high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].time <= seconds { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }
}
