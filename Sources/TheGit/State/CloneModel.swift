import AppKit
import Foundation

/// The Clone sheet's state: what has been typed, where it will land, and how
/// far along the clone is. One per sheet — closing the sheet ends it.
@MainActor
final class CloneModel: ObservableObject, Identifiable {
    let id = UUID()

    @Published var url: String {
        didSet { if !nameEdited { name = Clone.folderName(from: url) ?? "" } }
    }
    @Published private(set) var name: String
    @Published var parent: String
    @Published private(set) var progress: Clone.Progress?
    @Published private(set) var isRunning = false
    @Published private(set) var failure: String?

    /// Once the folder name has been typed by hand it stops following the
    /// address — otherwise pasting a second URL would overwrite a name that
    /// was chosen on purpose.
    private var nameEdited = false
    private var task: Task<Void, Never>?

    /// Where the last clone went, so the next one starts there.
    static let parentKey = "TheGit.cloneParent"

    init(url: String = "") {
        self.url = url
        self.name = Clone.folderName(from: url) ?? ""
        self.parent = Self.defaultParent()
    }

    /// The last place a clone went; failing that `~/Git`, the folder this
    /// app's own users keep repositories in, if it exists; failing that home.
    static func defaultParent() -> String {
        let fm = FileManager.default
        if let saved = UserDefaults.standard.string(forKey: parentKey),
           fm.fileExists(atPath: saved) {
            return saved
        }
        let git = NSHomeDirectory() + "/Git"
        return fm.fileExists(atPath: git) ? git : NSHomeDirectory()
    }

    /// An address on the pasteboard, if that is what is there.
    static func addressOnPasteboard() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string),
              Clone.looksLikeRemote(text)
        else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setName(_ new: String) {
        nameEdited = true
        name = new
    }

    var destination: String {
        (parent as NSString).appendingPathComponent(name.trimmingCharacters(in: .whitespaces))
    }

    /// The one reason Clone is off, in words, or nil when it isn't. Says
    /// nothing while the fields are still empty — a form that opens already
    /// complaining reads as an error.
    var problem: String? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if url.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        if !Clone.isUsable(url) { return "That doesn’t look like a repository address." }
        if trimmedName.isEmpty { return "Give the folder a name." }
        if trimmedName.contains("/") || trimmedName.hasPrefix(".") && trimmedName.allSatisfy({ $0 == "." }) {
            return "That isn’t a folder name."
        }
        if FileManager.default.fileExists(atPath: destination) {
            return "“\(trimmedName)” already exists in that folder."
        }
        return nil
    }

    var canStart: Bool {
        !isRunning && Clone.isUsable(url)
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && problem == nil
    }

    func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: parent)
        panel.prompt = "Choose"
        panel.message = "Clone into which folder?"
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        parent = picked.path
    }

    /// `onFinished` gets the new folder once git is done; the caller opens it.
    func start(onFinished: @escaping (String) -> Void) {
        guard canStart else { return }
        isRunning = true
        failure = nil
        progress = nil
        UserDefaults.standard.set(parent, forKey: Self.parentKey)
        let address = url, parent = parent
        let folder = name.trimmingCharacters(in: .whitespaces)
        task = Task { [weak self] in
            do {
                let path = try await Clone.run(url: address, into: parent, name: folder) { update in
                    Task { @MainActor [weak self] in self?.progress = update }
                }
                self?.isRunning = false
                onFinished(path)
            } catch is CancellationError {
                self?.isRunning = false
            } catch {
                self?.isRunning = false
                self?.failure = error.localizedDescription
            }
        }
    }

    /// Stops git, which removes what it had made so far — see `Clone.run`.
    func cancel() {
        task?.cancel()
    }
}
