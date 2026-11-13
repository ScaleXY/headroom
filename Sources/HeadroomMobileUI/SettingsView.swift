import HeadroomKit
import HeadroomSync
import SwiftUI

/// The canonical privacy promise (the README's wording).
public enum PrivacyPromise {
    public static let headline = "Nothing leaves your Apple Account, even when you sync."
    public static let body = "Headroom on your Mac sends its readings, history, token counts, account emails and how its agent runs are going through your own private iCloud to devices signed in to the same Apple Account, end-to-end encrypted. There's no Headroom server and no sign-up, so we never see any of it. Prompts, project names, file paths and sign-in details never leave your Mac, and run and task names only when you include them in Headroom's settings on the Mac."
}

struct MobileSettingsView: View {
    @Bindable var model: MobileModel

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $prefs.appearance) {
                    ForEach(MobileAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle("When a 5-hour session is back", isOn: $prefs.notifySessionBack)
                Toggle("Before the week renews unused", isOn: $prefs.notifyWeekRenews)
            } header: {
                Text("Notifications")
            } footer: {
                Text("These are scheduled on this device from the reset times your Mac reported, so they arrive on time even while your Mac sleeps.")
            }
            Section {
                Toggle("When a run needs your input", isOn: $prefs.notifyRunNeedsInput)
                Toggle("When a run stops with work left", isOn: $prefs.notifyRunStopped)
                Toggle("When a run finishes", isOn: $prefs.notifyRunFinished)
            } header: {
                Text("Agent runs")
            } footer: {
                Text("These arrive when your Mac syncs, usually within a minute or two. Each run alerts once per question and once when it stops or ends. While you're using the Mac, a question waits two minutes here, so you only hear about it once.")
            }
            if model.setTracking != nil {
                Section {
                    Toggle("Track sessions automatically", isOn: $prefs.autoTrackSessions)
                    Toggle("Show live agent runs", isOn: $prefs.trackRuns)
                } header: {
                    Text("Live Activity")
                } footer: {
                    Text("Shows the 5-hour session on the Lock Screen and in the Dynamic Island when you open Headroom during one. Countdowns stay exact; the rest updates as your Mac syncs. A live agent run gets its own, started when you open Headroom and ended when the run finishes or its Mac goes quiet.")
                }
            }
            if !model.reader.accounts.isEmpty {
                Section("Accounts") {
                    ForEach(model.reader.accounts) { a in
                        Toggle(isOn: Binding(
                            get: { !model.prefs.hiddenAccounts.contains(a.id) },
                            set: { on in if on { model.prefs.hiddenAccounts.remove(a.id) } else { model.prefs.hiddenAccounts.insert(a.id) } })) {
                            VStack(alignment: .leading) {
                                Text(a.label)
                                Text(a.provider.displayName + (a.isActive ? "" : " · not signed in on any Mac")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                Toggle("Show sample data", isOn: Binding(get: { model.reader.isDemo }, set: { on in Task { await model.setDemo(on) } }))
                    .disabled(model.iCloud == .unsupported)
                LabeledContent("iCloud", value: iCloudText)
            } header: {
                Text("Data")
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(PrivacyPromise.headline).font(.subheadline.weight(.semibold))
                    Text(PrivacyPromise.body).font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Privacy")
            }
            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                Link("Headroom for Mac", destination: URL(string: "https://github.com/ScaleXY/headroom")!)
            } footer: {
                Text("Claude is a trademark of Anthropic. OpenAI and Codex are trademarks of OpenAI. Headroom is an independent project and isn't affiliated with either.")
            }
        }
        .navigationTitle("Settings")
    }

    var iCloudText: String {
        switch model.iCloud {
        case .checking: "Checking…"
        case .available: model.reader.isDemo ? "Signed in (showing samples)" : "Signed in"
        case .noAccount: "Not signed in"
        case .restricted: "Restricted"
        case .unsupported: "Not in this build"
        case .unknown: "Unavailable"
        }
    }
}
