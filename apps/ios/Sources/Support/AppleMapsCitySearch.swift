import Foundation
import MapKit
import Combine

/// City autocomplete, from Apple rather than from Facebook.
///
/// Facebook's own typeahead exists, but driving it means typing into a React
/// input in a hidden webview and scraping a portal — brittle, and it was only
/// ever a means to an end. Apple already has a complete, fast, offline-capable
/// place index, and what the picker actually needs from a search box is a
/// *coordinate*: once there is one, `PlaceChooser` asks Facebook for its URL
/// segment through either the direct anonymous resolver or the full picker.
///
/// So the division is clean. Apple answers "where is the place the user typed",
/// Facebook answers "what URL represents that place", and neither is asked to
/// do the other's job.
@MainActor
final class AppleMapsCitySearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    struct Suggestion: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let subtitle: String
        fileprivate let completion: MKLocalSearchCompletion

        static func == (a: Suggestion, b: Suggestion) -> Bool {
            a.title == b.title && a.subtitle == b.subtitle
        }

        /// "Toronto, Ontario, Canada" — what the user picked, for confirmation
        /// before Facebook renames it to whatever it calls the place.
        var display: String {
            subtitle.isEmpty ? title : "\(title), \(subtitle)"
        }
    }

    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var isSearching = false

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        // Cities and neighbourhoods, not coffee shops. `.address` alone still
        // returns street addresses, which are harmless here — Facebook
        // resolves any coordinate to the place that contains it — but they
        // make the list noisier to read.
        completer.resultTypes = [.address]
    }

    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            suggestions = []
            completer.queryFragment = ""
            return
        }
        isSearching = true
        completer.queryFragment = trimmed
    }

    func clear() {
        suggestions = []
        completer.queryFragment = ""
    }

    /// The search that finds the coordinate behind a suggestion, **built now**
    /// and run by the caller later. `MKLocalSearchCompletion` carries no
    /// coordinate of its own — it's a query, not a place.
    ///
    /// Building and running are separate because the picker clears its search
    /// field the moment a suggestion is tapped, which resets the completer that
    /// vended it, while the coordinate is still wanted a moment afterwards. A
    /// request captured up front doesn't care what happens to the field behind
    /// it.
    func search(for suggestion: Suggestion) -> MKLocalSearch {
        MKLocalSearch(request: MKLocalSearch.Request(completion: suggestion.completion))
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in
            suggestions = results.prefix(8).map {
                Suggestion(title: $0.title, subtitle: $0.subtitle, completion: $0)
            }
            isSearching = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            suggestions = []
            isSearching = false
        }
    }
}
