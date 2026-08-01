import SwiftUI

/// The contents of a "Hand Off" menu: one section per installed agent, the
/// same workflows listed under each.
///
/// Sections, not a "Hand Off to Claude ▸" submenu per agent: with one agent
/// installed — the common case — the section title still names it, and no
/// workflow ends up two levels deep from the button it hangs off. With both
/// installed the two groups read as one list you scan once.
///
/// Empty when neither CLI is on the box, which makes the whole feature
/// leave no trace — the same bargain the pull-request section itself
/// strikes with `gh`. Settings › Tools is where a user learns it exists.
struct HandoffMenu: View {
    let tasks: [HandoffTask]
    let run: (HandoffTask, AgentTool) -> Void
    @ObservedObject private var agents = AgentTools.shared

    var body: some View {
        ForEach(agents.available) { agent in
            Section(agent.name) {
                ForEach(tasks) { task in
                    // No .help here on purpose: a menu shows no tooltips, so
                    // anything the user needs before clicking has to be in
                    // the title.
                    Button(task.title) { run(task, agent) }
                }
            }
        }
    }
}
