#if os(macOS)
import ConduitCore
import SwiftUI

/// File-backed project scope picker for task navigation.
///
/// Every project shown here comes from `AppModel.projects`, which is rebuilt
/// from MainFrame. Selecting a scope changes only the task-history filter.
struct ProjectScopeBrowser: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var matchingProjects: [MainframeProject] {
        model.projects.filter {
            ProjectNavigation.matches($0, query: searchText)
        }
    }

    private var rootProjects: [MainframeProject] {
        matchingProjects.filter(\.isMainframeRoot)
    }

    private var activeProjects: [MainframeProject] {
        matchingProjects.filter {
            !$0.isMainframeRoot && ProjectNavigation.isActive($0)
        }
    }

    private var otherProjects: [MainframeProject] {
        matchingProjects.filter {
            !$0.isMainframeRoot && !ProjectNavigation.isActive($0)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.line)
            searchField
            Divider().overlay(palette.line)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        scopeSectionLabel("Workspace")
                        allMainFrameRow
                    }

                    projectSection("MainFrame Root", projects: rootProjects)
                    projectSection("Active Projects", projects: activeProjects)
                    projectSection("Other Projects", projects: otherProjects)

                    if matchingProjects.isEmpty {
                        Text("No source-derived projects match “\(searchText)”.")
                            .font(.caption)
                            .foregroundStyle(palette.dim)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    }
                }
                .padding(14)
            }

            Divider().overlay(palette.line)
            footer
        }
        .frame(width: 560, height: 500)
        .background(palette.canvas)
        .onAppear {
            Task {
                await Task.yield()
                isSearchFocused = true
            }
        }
    }

    private var header: some View {
        ConduitSheetHeader(
            title: "Browse Projects",
            subtitle: "Filter task history by the current MainFrame file scan.",
            systemImage: "folder",
            onClose: { model.showProjectBrowser = false }
        )
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(palette.faint)
                .accessibilityHidden(true)
            TextField("Find a project", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .foregroundStyle(palette.text)
                .accessibilityLabel("Find a project")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(palette.dim)
                .accessibilityLabel("Clear project search")
                .help("Clear project search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(palette.rail)
    }

    private var allMainFrameRow: some View {
        scopeRow(
            title: "All MainFrame",
            subtitle: model.settings.mainframeRoot?.path
                ?? "All task histories under the selected root",
            systemImage: "square.grid.2x2",
            isSelected: model.taskScopeProjectID == nil
        ) {
            selectScope(nil)
        }
    }

    @ViewBuilder
    private func projectSection(
        _ title: String,
        projects: [MainframeProject]
    ) -> some View {
        if !projects.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                scopeSectionLabel(title)
                ForEach(projects) { project in
                    scopeRow(
                        title: project.metadata.title,
                        subtitle: project.isMainframeRoot
                            ? "MainFrame Root · \(project.path.path)"
                            : project.path.path,
                        systemImage: project.isMainframeRoot
                            ? "externaldrive"
                            : "folder",
                        isSelected: model.taskScopeProjectID == project.id
                    ) {
                        selectScope(project.id)
                    }
                }
            }
        }
    }

    private func scopeSectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(0.7)
            .foregroundStyle(palette.dim)
            .padding(.horizontal, 8)
    }

    private func scopeRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? palette.accent : palette.dim)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(palette.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(isSelected ? palette.accentSoft : palette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(
                        isSelected ? palette.accent.opacity(0.35) : palette.lineSoft,
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Filters task history without changing MainFrame files")
        .help(subtitle)
    }

    private var footer: some View {
        HStack {
            Button(action: model.chooseMainframeRoot) {
                Label("Choose Root", systemImage: "folder")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Choose MainFrame Root")
            .help("Choose a different MainFrame root")

            Button(action: model.refreshProjects) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.isScanningProjects || model.rootAccessNeedsAuthorization)
            .accessibilityLabel("Refresh MainFrame projects")
            .help("Refresh projects from MainFrame files")

            Spacer()

            Button("Done") {
                model.showProjectBrowser = false
            }
            .keyboardShortcut(.cancelAction)
        }
        .font(.system(size: 11))
        .padding(14)
        .background(palette.surface)
    }

    private func selectScope(_ projectID: String?) {
        model.taskScopeProjectID = projectID
        model.showProjectBrowser = false
    }
}
#endif
