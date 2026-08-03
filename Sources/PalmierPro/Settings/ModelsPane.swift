import SwiftUI

struct ModelsPane: View {
    private var prefs = ModelPreferences.shared
    private var catalog = ModelCatalog.shared
    private var account = AccountService.shared

    @State private var query = ""

    private struct Row: Identifiable {
        let id: String
        let displayName: String
        let paidOnly: Bool
    }

    private struct Section: Identifiable {
        let id: String
        let title: String
        let rows: [Row]
    }

    private func isLocked(_ row: Row) -> Bool { row.paidOnly && !account.isPaid }

    private var sections: [Section] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func prepare(_ rows: [Row]) -> [Row] {
            let matched = q.isEmpty ? rows : rows.filter { $0.displayName.lowercased().contains(q) }
            // Available models first, locked (paid-only) ones grouped at the bottom.
            return matched.filter { !isLocked($0) } + matched.filter { isLocked($0) }
        }
        return [
            Section(id: "image", title: "Image",
                    rows: prepare(catalog.image.map { Row(id: $0.id, displayName: $0.displayName, paidOnly: $0.paidOnly) })),
            Section(id: "video", title: "Video",
                    rows: prepare(catalog.video.map { Row(id: $0.id, displayName: $0.displayName, paidOnly: $0.paidOnly) })),
            Section(id: "audio", title: "Audio",
                    rows: prepare(catalog.audio.map { Row(id: $0.id, displayName: $0.displayName, paidOnly: $0.paidOnly) })),
        ].filter { !$0.rows.isEmpty }
    }

    @StateObject private var router = LocalAIRouter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            localAISection

            searchBar

            if sections.isEmpty {
                Text(catalog.isLoaded ? "No models match \"\(query)\"." : "Loading models…")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .padding(.top, AppTheme.Spacing.lg)
            } else {
                ForEach(sections) { section in
                    sectionView(section)
                }
            }
        }
    }

    private var localAISection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            SettingsSection(title: "AI Chat & Reasoning Model") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    HStack {
                        Text("Default Active Chat Model")
                            .font(.system(size: AppTheme.FontSize.md))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        Spacer()
                        Picker("", selection: $router.selectedChatModel) {
                            ForEach(ChatAIModel.allCases) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Text("You can also switch models on the fly directly inside the Chat Agent header.")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }

            SettingsSection(title: "API Keys & Custom Backends") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Google AI Studio (Gemini) Key")
                                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                                .foregroundStyle(AppTheme.Text.primaryColor)
                            Text("Used for Gemini 3.5 Flash, Gemini 2.5 Flash, Veo 3.1 & Nano Banana")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        Spacer()
                        SecureField("AIzaSy...", text: $router.googleAIKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                    }

                    Divider().opacity(0.3)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Anthropic API Key")
                                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                                .foregroundStyle(AppTheme.Text.primaryColor)
                            Text("Used for Claude 3.5 Sonnet & Haiku")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        Spacer()
                        SecureField("sk-ant-...", text: $router.anthropicAPIKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                    }

                    Divider().opacity(0.3)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("OpenAI / OpenRouter API Key")
                                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                                .foregroundStyle(AppTheme.Text.primaryColor)
                            Text("Used for GPT-4o & OpenRouter models")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        Spacer()
                        SecureField("sk-or-...", text: $router.openAIAPIKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                    }

                    Divider().opacity(0.3)

                    HStack {
                        Text("LM Studio Endpoint")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Spacer()
                        TextField("http://localhost:1234/v1", text: $router.lmStudioEndpoint)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                    }

                    HStack {
                        Text("MLX Server Endpoint")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Spacer()
                        TextField("http://localhost:8080", text: $router.mlxEndpoint)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                    }

                    HStack {
                        Text("ComfyUI Endpoint")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Spacer()
                        TextField("http://127.0.0.1:8188", text: $router.comfyEndpoint)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                    }
                }
            }

            SettingsSection(title: "Hardware Acceleration") {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "cpu")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Accent.primary)
                    Text("Video & Image upscaling is powered 100% locally on your Mac's Apple Neural Engine (ANE) and M-series GPU via Core ML & Metal Performance Shaders (PiperSR & Real-ESRGAN).")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
            TextField("Search models", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(Color.white.opacity(AppTheme.Opacity.subtle))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    private func sectionView(_ section: Section) -> some View {
        SettingsSection(title: section.title) {
            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    modelRow(row)
                    if index < section.rows.count - 1 {
                        Divider().overlay(AppTheme.Border.subtleColor)
                    }
                }
            }
            .padding(.vertical, AppTheme.Spacing.xs)
        }
    }

    @ViewBuilder
    private func modelRow(_ row: Row) -> some View {
        let locked = isLocked(row)
        HStack(spacing: AppTheme.Spacing.md) {
            Text(row.displayName)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(locked ? AppTheme.Text.tertiaryColor : AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.lg)
            if locked {
                Button("Subscribe") {
                    SettingsWindowController.shared.show(tab: .models)
                }
                .buttonStyle(.capsule(.secondary))
            } else {
                Toggle("", isOn: Binding(
                    get: { prefs.isEnabled(row.id) },
                    set: { prefs.setEnabled(row.id, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(row.displayName)
            }
        }
        .padding(.vertical, AppTheme.Spacing.smMd)
    }
}
