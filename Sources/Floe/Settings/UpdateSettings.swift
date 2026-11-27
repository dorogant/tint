import SwiftUI

/// Settings ▸ About ▸ Updates: whether a newer Tint is out, and the button
/// that moves to it. A copy built from source says that it stays as it is.
struct UpdateSection: View {
    @Environment(UpdateModel.self) private var updates
    @Environment(\.locale) private var locale

    var body: some View {
        @Bindable var updates = updates
        SwiftUI.Section {
            if updates.isEnabled {
                LabeledContent {
                    actions
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 3)
                }
                if let problem = updates.problem {
                    Label(UpdateText.problem(problem), systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Check for updates automatically", isOn: $updates.automatic)
            } else {
                Text("This copy of Tint was built from source, so it stays as it is. Build it again to update it.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Updates")
        } footer: {
            if updates.isEnabled {
                Text("Once a day Tint asks GitHub whether a newer version is out. Nothing about you or your music is sent. An update is only installed when you ask, and only if it carries Tint's own signature; playback stops while Tint reopens.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch updates.activity {
        case .idle:
            if let release = updates.release {
                HStack(spacing: 10) {
                    if release.isInstallable {
                        Link("What's New", destination: release.page)
                        Button("Install and Reopen") { Task { await updates.install() } }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Link("Download Page", destination: release.page)
                    }
                }
            } else {
                Button("Check Now") { Task { await updates.check() } }
            }
        case .checking, .downloading, .installing, .reopening:
            ProgressView().controlSize(.small)
        }
    }

    private var title: String {
        switch updates.activity {
        case .checking: return L10n.string("Checking for updates…")
        case .downloading: return L10n.string("Downloading the update…")
        case .installing: return L10n.string("Installing the update…")
        case .reopening: return L10n.string("Reopening Tint…")
        case .idle: break
        }
        if let release = updates.release { return L10n.string("Tint \(release.version.description) is available") }
        // Until GitHub has answered once, "up to date" would be a guess.
        return updates.lastChecked == nil ? L10n.string("Not checked yet") : L10n.string("Tint is up to date")
    }

    private var detail: String {
        if let release = updates.release {
            return release.isInstallable
                ? L10n.string("You have \(updates.version.description).")
                : L10n.string("You have \(updates.version.description). This version can't be installed from here: download it from its page.")
        }
        guard let checked = updates.lastChecked else { return L10n.string("You have \(updates.version.description).") }
        return L10n.string("Last checked \(checked.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))).")
    }
}

enum UpdateText {
    static func problem(_ problem: UpdateProblem) -> String {
        switch problem {
        case .unreachable: L10n.string("GitHub can't be reached. Check the connection and try again.")
        case .busy: L10n.string("GitHub is turning questions away for now. Try again in an hour.")
        case .unexpected: L10n.string("GitHub's answer couldn't be read. Try again later.")
        case .badSignature: L10n.string("The download doesn't carry Tint's signature, so it wasn't installed.")
        case .damaged: L10n.string("The download is damaged, so it wasn't installed. Try again.")
        case .notNewer: L10n.string("The download is no newer than this copy, so it wasn't installed.")
        case .translocated: L10n.string("Tint can't replace itself where it is. Quit, move Tint to the Applications folder, open it from there and try again.")
        case .notWritable: L10n.string("Tint can't change the folder it's in. Move Tint to the Applications folder, or download the new version from its page.")
        case .refused: L10n.string("macOS stopped Tint from replacing itself. Allow Tint in System Settings → Privacy & Security → App Management, then try again.")
        }
    }
}

/// The app menu's "Check for Updates…": opens Settings on About and asks.
struct CheckForUpdatesCommand: View {
    let updates: UpdateModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if updates.isEnabled {
            Button("Check for Updates…") {
                UpdateSection.show(openSettings)
                Task { await updates.check() }
            }
        }
    }
}

extension UpdateSection {
    /// Settings, turned to the section the updates are in.
    @MainActor static func show(_ openSettings: OpenSettingsAction) {
        UserDefaults.standard.set(SettingsView.Section.about.rawValue, forKey: "settingsSection")
        openSettings()
    }
}
