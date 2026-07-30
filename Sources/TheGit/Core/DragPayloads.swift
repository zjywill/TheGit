import CoreTransferable
import UniformTypeIdentifiers

/// Private drag types. Text would work, but then any dragged string from
/// any app would look like a branch to our drop targets — these make a
/// drop mean something only when it started inside TheGit.
extension UTType {
    static let thegitBranch = UTType(exportedAs: "com.thegit.branch")
    static let thegitCommit = UTType(exportedAs: "com.thegit.commit")
    static let thegitProject = UTType(exportedAs: "com.thegit.project")
}

/// A row of the repository list on its way into one of the user's sections.
/// The id is the project's, not a folder's: dragging one of three clones of
/// dim-agent moves the project, because a section holds projects.
struct DraggedProject: Codable, Transferable {
    let id: String
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .thegitProject)
    }
}

struct DraggedBranch: Codable, Transferable {
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .thegitBranch)
    }
}

struct DraggedCommit: Codable, Transferable {
    let hash: String
    let subject: String

    var shortHash: String { String(hash.prefix(7)) }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .thegitCommit)
    }
}
