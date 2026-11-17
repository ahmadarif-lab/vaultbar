import AppKit
import SwiftUI
import VaultKit

/// "About VaultBar", inline in the popover like the extension's About dialog.
struct AboutView: View {
    let state: AppState
    @State private var copied = false

    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { state.showAbout = false } label: {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }.buttonStyle(.plain).handCursor()
                Text(t("about.title")).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().interpolation(.high).frame(width: 96, height: 96).padding(.top, 14)
                    Text("VaultBar").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(t("about.tagline")).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)

                    VStack(spacing: 0) {
                        row(t("about.version"), "\(state.appVersion) (\(build))")
                        if let url = state.settings.server?.url {
                            Rectangle().fill(Theme.stroke).frame(height: 1)
                            row(t("about.server"), url)
                        }
                        if let version = state.serverVersion {
                            Rectangle().fill(Theme.stroke).frame(height: 1)
                            row(t("about.serverVersion"), version)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke))
                    .padding(.top, 8)

                    Text(t("about.copyright")).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).padding(.top, 6)
                    Text(t("about.unofficial")).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button(copied ? t("about.copied") : t("about.copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(state.aboutSummary, forType: .string)
                            copied = true
                            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                        }
                        .buttonStyle(SecondaryButtonStyle()).handCursor()
                        Button(t("about.close")) { state.showAbout = false }
                            .buttonStyle(PrimaryButtonStyle()).handCursor()
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 13)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 12).frame(height: 38)
    }
}
