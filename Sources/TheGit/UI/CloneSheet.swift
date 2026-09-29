import SwiftUI

/// Clone Repository: an address, where it goes, and — once it is running —
/// how far along it is. Modelled on the Add Remote sheet: a form, two buttons.
struct CloneSheet: View {
    @ObservedObject var model: CloneModel
    /// Called with the new folder when git is done; opens it and closes this.
    let onFinished: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clone Repository")
                .font(.headline)

            TextField("URL (https://… or git@…)", text: $model.url)
                .frame(minWidth: 400)
                .disabled(model.isRunning)
                .onSubmit { start() }

            HStack(spacing: 8) {
                Text("Into")
                    .foregroundStyle(.secondary)
                Text(abbreviated(model.parent))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(model.parent)
                Spacer(minLength: 0)
                Button("Change…") { model.chooseParent() }
                    .disabled(model.isRunning)
            }

            TextField(
                "Folder name",
                text: Binding(get: { model.name }, set: { model.setName($0) })
            )
            .disabled(model.isRunning)

            status

            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancel()
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button("Clone") { start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(!model.canStart)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func start() {
        model.start(onFinished: onFinished)
    }

    /// One line under the form, whichever of the three things it has to say:
    /// how far along, why it can't, or why it failed.
    @ViewBuilder
    private var status: some View {
        if model.isRunning {
            VStack(alignment: .leading, spacing: 4) {
                if let progress = model.progress {
                    ProgressView(value: Double(progress.percent), total: 100)
                    Text("\(progress.phase) \(progress.percent)%")
                } else {
                    ProgressView().controlSize(.small)
                    Text("Connecting…")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let failure = model.failure {
            Text(failure)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if let problem = model.problem {
            Text(problem)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
