import Foundation

/// Which build is talking, for the two headers the ingest endpoint reads.
///
/// Metadata rather than request fields: it describes the caller and not the
/// observation, so putting it in the message would mean every batch restating
/// it. The server attaches it to the batch once per call.
enum AppBuild {
    /// `CFBundleShortVersionString`, which `project.yml` fills from
    /// `MARKETING_VERSION`.
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    /// `CFBundleVersion`, from `CURRENT_PROJECT_VERSION`.
    ///
    /// Debug pins this to `1`, which is why it cannot identify a parser on its
    /// own — `ObservationCapture.extractorRevision` is what does that.
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
}
