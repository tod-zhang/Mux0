import Foundation
import Observation

@Observable
final class WorkspaceMetadata {
    var gitBranch: String?
    var prStatus: String?          // "open", "merged", "closed", nil = unknown
    var workingDirectory: String?
    var latestNotification: String?
    /// Aggregated insertions vs HEAD across the working tree (staged + unstaged
    /// tracked changes). Nil → not in a git repo or no probe has run yet. Zero
    /// → working tree matches HEAD on the insertions axis.
    var gitDiffAdded: Int?
    /// Aggregated deletions vs HEAD. See `gitDiffAdded`.
    var gitDiffDeleted: Int?
}
