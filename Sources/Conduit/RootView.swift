#if os(macOS)
import ConduitCore
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    /// NavigationSplitView owns the rail only. The trailing Inspector has its
    /// own responsive overlay/pin policy and never changes this visibility.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var inspectorFocusRequest = 0
    @State private var inspectorReturnFocusRequest = 0
    @State private var inspectorPriorWindow: NSWindow?
    @State private var inspectorPriorResponder: NSResponder?
    @AppStorage("conduit.inspectorWidth") private var storedInspectorWidth = 0.0
    @State private var inspectorDragStartWidth: Double?
    @State private var inspectorTransientWidth: Double?
    @State private var inspectorResizeCursorIsPushed = false
    @State private var inspectorResizeHandleHovered = false
    @FocusState private var inspectorResizeHandleFocused: Bool

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    /// Deterministic rail visibility for every density (never `.automatic`).
    private var densityColumnVisibility: NavigationSplitViewVisibility {
        switch model.density {
        case .focused:
            return .all
        case .balanced, .operator:
            return .all
        }
    }

    var body: some View {
        // Left rail collapses via NavigationSplitView. Right inspector is our
        // own trailing panel so it can hide independently without remounting
        // the workspace (terminals stay attached).
        collapsibleWorkspaceLayout
        .tint(palette.accent)
        .background(palette.app)
        .conduitSurfaceChrome(finish: themeStore.surfaceFinish, colorScheme: colorScheme)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                paletteMenu
            }
        }
        .alert("Conduit", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .sheet(isPresented: $model.showDiagnostics) {
            DiagnosticsView()
                .environmentObject(model)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $model.showResources) {
            ResourcePanelView()
                .environmentObject(model)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $model.showAgentUsage) {
            AgentUsageSheet()
                .environmentObject(model)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $model.showMindGraph) {
            MindGraphQueryView()
                .environmentObject(model)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $model.showContextBundle) {
            ContextBundleView()
                .environmentObject(model)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $model.showResumeSessions) {
            ResumeSessionsSheet()
                .environmentObject(model)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $model.showNewTask) {
            NewTaskView()
                .environmentObject(model)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $model.showProjectBrowser) {
            ProjectScopeBrowser()
                .environmentObject(model)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $model.showSettingsSheet) {
            NavigationStack {
                SettingsView()
                    .environmentObject(model)
                    .environmentObject(themeStore)
                    .frame(minWidth: 640, minHeight: 520)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { model.showSettingsSheet = false }
                        }
                    }
            }
            .frame(width: 700, height: 580)
        }
        .onChange(of: model.speech.isRecording) { recording in
            if !recording { model.absorbSpeechTranscript() }
        }
        .onChange(of: model.taskSearchFocusRequest) { _ in
            columnVisibility = densityColumnVisibility
        }
        .onChange(of: model.density) { _ in
            columnVisibility = densityColumnVisibility
        }
        .onChange(of: model.isContextInspectorPresented) { presented in
            if presented {
                inspectorPriorWindow = NSApp.keyWindow
                inspectorPriorResponder = inspectorPriorWindow?.firstResponder
                inspectorFocusRequest += 1
            } else {
                cancelInspectorResize()
                restoreInspectorOriginFocus()
            }
        }
        .task {
            await Task.yield()
            await model.bootstrap()
        }
    }

    /// Sidebar + workspace, with an independently collapsible trailing inspector.
    private var collapsibleWorkspaceLayout: some View {
        GeometryReader { proxy in
            let geometry = WorkspaceGeometryPolicy.resolve(
                windowWidth: proxy.size.width,
                density: model.density,
                isInspectorPresented: model.isContextInspectorPresented,
                preferredInspectorWidth: inspectorTransientWidth
                    ?? (storedInspectorWidth > 0 ? storedInspectorWidth : nil)
            )
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebarColumn(geometry: geometry)
            } detail: {
                responsiveWorkspace(geometry: geometry)
            }
        }
    }

    private func responsiveWorkspace(
        geometry: WorkspaceGeometry
    ) -> some View {
        ZStack(alignment: .trailing) {
            workspaceColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(
                    .trailing,
                    geometry.inspectorLayout == .pinned
                        ? CGFloat(geometry.inspectorWidth + 1)
                        : 0
                )

            if geometry.inspectorLayout != .hidden {
                HStack(spacing: 0) {
                    inspectorDivider
                    inspectorPanel(width: geometry.inspectorWidth)
                }
                .frame(width: CGFloat(geometry.inspectorWidth + 1))
                .overlay(alignment: .leading) {
                    inspectorResizeHandle(geometry: geometry)
                        .offset(
                            x: layoutDirection == .leftToRight ? -4.5 : 4.5
                        )
                }
                .shadow(
                    color: geometry.inspectorLayout == .overlay
                        ? Color.black.opacity(0.28)
                        : .clear,
                    radius: 18,
                    x: -6,
                    y: 0
                )
                .transition(
                    reduceMotion
                        ? .identity
                        : .move(edge: .trailing).combined(with: .opacity)
                )
                .zIndex(1)
            }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: model.isContextInspectorPresented
        )
    }

    private var inspectorDivider: some View {
        Rectangle()
            .fill(palette.line)
            .frame(width: 1)
            .accessibilityHidden(true)
    }

    /// A presentation-only splitter. It changes panel geometry and the saved
    /// preference, never density, task selection, or terminal/runtime identity.
    private func inspectorResizeHandle(geometry: WorkspaceGeometry) -> some View {
        Button {
            inspectorResizeHandleFocused = true
        } label: {
            ZStack {
                Color.clear
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        inspectorResizeHandleFocused || inspectorResizeHandleHovered
                            ? palette.accent.opacity(0.85)
                            : Color.clear
                    )
                    .frame(width: 2)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 10)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .focused($inspectorResizeHandleFocused)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    inspectorResizeHandleFocused = true
                    updateInspectorDrag(value, geometry: geometry)
                }
                .onEnded { value in
                    finishInspectorDrag(value, geometry: geometry)
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded { resetInspectorWidth() }
        )
        .onMoveCommand { direction in
            switch direction {
            case .left:
                adjustInspectorWidth(
                    by: layoutDirection == .leftToRight ? 24 : -24,
                    geometry: geometry
                )
            case .right:
                adjustInspectorWidth(
                    by: layoutDirection == .leftToRight ? -24 : 24,
                    geometry: geometry
                )
            default:
                break
            }
        }
        .onExitCommand {
            if model.isContextInspectorPresented {
                model.dismissContextInspector()
            }
        }
        .onHover { hovering in
            inspectorResizeHandleHovered = hovering
            if hovering, !inspectorResizeCursorIsPushed {
                NSCursor.resizeLeftRight.push()
                inspectorResizeCursorIsPushed = true
            } else if !hovering, inspectorResizeCursorIsPushed {
                NSCursor.pop()
                inspectorResizeCursorIsPushed = false
            }
        }
        .onDisappear {
            inspectorResizeHandleHovered = false
            if inspectorResizeCursorIsPushed {
                NSCursor.pop()
                inspectorResizeCursorIsPushed = false
            }
        }
        .help("Drag to resize Inspector. Double-click to restore the responsive default.")
        .contextMenu {
            Button("Restore responsive Inspector width") {
                resetInspectorWidth()
            }
        }
        // A transparent custom splitter did not consistently enter the macOS
        // accessibility tree even when exposed as a Button. SwiftUI Slider
        // entered as AXSlider but left AXTitle empty. An AppKit NSSlider
        // representation supplies real adjustable semantics and a stable
        // VoiceOver name without changing pointer/keyboard surface or
        // workspace topology.
        .accessibilityRepresentation {
            InspectorResizeAXSlider(
                value: geometry.inspectorWidth,
                range: geometry.inspectorMinimumWidth...geometry.inspectorMaximumWidth,
                step: 24,
                onChange: { width in
                    setInspectorWidth(width, geometry: geometry)
                },
                onReset: {
                    resetInspectorWidth()
                }
            )
        }
    }

    private func updateInspectorDrag(
        _ value: DragGesture.Value,
        geometry: WorkspaceGeometry
    ) {
        if inspectorDragStartWidth == nil {
            inspectorDragStartWidth = geometry.inspectorWidth
        }
        let start = inspectorDragStartWidth ?? geometry.inspectorWidth
        let translation = Double(value.translation.width)
            * (layoutDirection == .leftToRight ? 1 : -1)
        inspectorTransientWidth = WorkspaceGeometryPolicy.clampInspectorWidth(
            start - translation,
            minimum: geometry.inspectorMinimumWidth,
            maximum: geometry.inspectorMaximumWidth
        )
    }

    private func finishInspectorDrag(
        _ value: DragGesture.Value,
        geometry: WorkspaceGeometry
    ) {
        let start = inspectorDragStartWidth ?? geometry.inspectorWidth
        updateInspectorDrag(value, geometry: geometry)
        if let inspectorTransientWidth,
           WorkspaceGeometryPolicy.shouldCommitInspectorWidth(
               currentEffectiveWidth: start,
               proposedWidth: inspectorTransientWidth
           )
        {
            storedInspectorWidth = inspectorTransientWidth
        }
        inspectorTransientWidth = nil
        inspectorDragStartWidth = nil
    }

    private func adjustInspectorWidth(
        by delta: Double,
        geometry: WorkspaceGeometry
    ) {
        setInspectorWidth(
            geometry.inspectorWidth + delta,
            geometry: geometry
        )
    }

    private func setInspectorWidth(
        _ proposedWidth: Double,
        geometry: WorkspaceGeometry
    ) {
        let adjustedWidth = WorkspaceGeometryPolicy.clampInspectorWidth(
            proposedWidth,
            minimum: geometry.inspectorMinimumWidth,
            maximum: geometry.inspectorMaximumWidth
        )
        guard WorkspaceGeometryPolicy.shouldCommitInspectorWidth(
            currentEffectiveWidth: geometry.inspectorWidth,
            proposedWidth: adjustedWidth
        ) else { return }
        storedInspectorWidth = adjustedWidth
        inspectorTransientWidth = nil
        inspectorDragStartWidth = nil
    }

    private func resetInspectorWidth() {
        storedInspectorWidth = 0
        cancelInspectorResize()
    }

    private func cancelInspectorResize() {
        inspectorTransientWidth = nil
        inspectorDragStartWidth = nil
    }

    private func inspectorPanel(width: Double) -> some View {
        InspectorView(
            project: model.selectedTaskProject ?? model.selectedProject,
            showsCloseButton: true,
            focusRequest: inspectorFocusRequest,
            onClose: { model.dismissContextInspector() }
        )
        .frame(width: CGFloat(width))
        .frame(maxHeight: .infinity)
    }

    private func restoreInspectorOriginFocus() {
        let window = inspectorPriorWindow
        let responder = inspectorPriorResponder
        inspectorPriorWindow = nil
        inspectorPriorResponder = nil
        DispatchQueue.main.async {
            let restored: Bool
            if let window, let responder, window.isVisible,
               (responder as? NSView)?.window === window
            {
                restored = window.makeFirstResponder(responder)
                    && window.firstResponder === responder
            } else {
                restored = false
            }
            if !restored {
                let hasWorkspaceInspectorToggle = model.settings.mainframeRoot != nil
                    && !model.rootAccessNeedsAuthorization
                    && (
                        model.selectedTaskProject != nil
                            || model.selectedProject != nil
                            || model.selectedTaskSnapshot != nil
                    )
                if hasWorkspaceInspectorToggle {
                    inspectorReturnFocusRequest += 1
                } else {
                    model.requestTaskSearchFocus()
                }
            }
        }
    }

    private func sidebarColumn(geometry: WorkspaceGeometry) -> some View {
        sidebar
            .navigationSplitViewColumnWidth(
                min: CGFloat(geometry.railMinimumWidth),
                ideal: CGFloat(geometry.railIdealWidth),
                max: CGFloat(geometry.railMaximumWidth)
            )
            .background(
                ConduitFinishedFill(
                    base: palette.rail,
                    finish: themeStore.surfaceFinish,
                    colorScheme: colorScheme
                )
            )
    }

    private var workspaceColumn: some View {
        Group {
            if model.settings.mainframeRoot == nil {
                onboarding
            } else if model.rootAccessNeedsAuthorization {
                rootAuthorization
            } else if let project = model.selectedTaskProject ?? model.selectedProject {
                ProjectWorkspaceView(
                    project: project,
                    inspectorFocusRequest: inspectorReturnFocusRequest
                )
            } else if let task = model.selectedTaskSnapshot {
                HistoricalTaskWorkspaceView(
                    task: task,
                    inspectorFocusRequest: inspectorReturnFocusRequest
                )
            } else {
                EmptyStateView(
                    title: "No task selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: "Start a new task or choose one from task history."
                )
            }
        }
        .background(
            ConduitFinishedFill(
                base: palette.app,
                finish: themeStore.surfaceFinish,
                colorScheme: colorScheme
            )
        )
    }

    /// Always-reachable palette + surface-finish picker.
    private var paletteMenu: some View {
        Menu {
            ForEach(PaletteID.allCases, id: \.self) { id in
                Button {
                    themeStore.select(id)
                } label: {
                    Label {
                        Text(id.displayName)
                    } icon: {
                        Image(systemName: themeStore.selectedPalette == id ? "checkmark.circle.fill" : "circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                themeStore.accentSwatch(for: id, colorScheme: colorScheme),
                                themeStore.accentSwatch(for: id, colorScheme: colorScheme)
                            )
                    }
                }
            }
            Divider()
            Button {
                themeStore.surfaceFinish = themeStore.surfaceFinish == .matte ? .sheen : .matte
            } label: {
                Label(
                    themeStore.surfaceFinish == .sheen ? "Sheen finish on" : "Sheen finish off",
                    systemImage: themeStore.surfaceFinish == .sheen ? "sparkles" : "circle.dashed"
                )
            }
        } label: {
            Label("Palette", systemImage: "paintpalette")
        }
        .help("Choose color palette and surface finish")
        .accessibilityLabel("Palette")
        .accessibilityValue(
            "\(themeStore.selectedPalette.displayName), \(themeStore.surfaceFinish.displayName)"
        )
    }

    private var sidebar: some View {
        TaskSidebarView()
    }

    private var onboarding: some View {
        VStack(spacing: 18) {
            PixelOnboardingMark()
            Text("Connect Conduit to MainFrame")
                .font(.largeTitle.bold())
                .foregroundStyle(palette.text)
            Text("Choose the folder containing 00_inbox, 10_knowledge, 20_live, and 30_projects. Conduit keeps your files as the source of truth.")
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.dim)
                .frame(maxWidth: 560)
            Button("Choose MainFrame Root", action: model.chooseMainframeRoot)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Choose MainFrame Root")
            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }
        }
        .padding(40)
    }

    private var rootAuthorization: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Renew MainFrame Access")
                .font(.title2.bold())
                .foregroundStyle(palette.text)
            Text("macOS no longer recognizes this build's access to the saved folder. Choose the same MainFrame root once; Conduit will preserve that authorization for future launches.")
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.dim)
                .frame(maxWidth: 520)
            if let root = model.settings.mainframeRoot {
                Text(root.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.dim)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Button("Choose MainFrame Root", action: model.chooseMainframeRoot)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Choose MainFrame Root")
            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }
        }
        .padding(40)
        .accessibilityElement(children: .contain)
    }
}

private struct ProjectWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let project: MainframeProject
    let inspectorFocusRequest: Int

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(
                project: project,
                inspectorFocusRequest: inspectorFocusRequest
            )
            Divider()
            // Operator-only observed-state deck (above session strip / terminal).
            if model.density == .operator {
                OperatorOpsDeck(project: project)
                Divider()
            }
            // Optional multi-agent peek — density default or operator override.
            if model.showsOperatorPeek {
                OperatorPeekBar()
                Divider()
            }
            SessionSurfaceView(runtime: selectedTaskRuntime)
                .frame(minHeight: 240)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDropTargeted) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else {
                        url = item as? URL
                    }
                    if let url {
                        Task { @MainActor in model.addAttachments([url]) }
                    }
                }
            }
            return !providers.isEmpty
        }
        .overlay {
            if model.isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(palette.accent, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
    }

    private var selectedTaskRuntime: TerminalRuntime? {
        model.selectedTaskRuntime
    }
}

private struct HistoricalTaskWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var inspectorButtonFocused: Bool
    @AccessibilityFocusState private var inspectorButtonAccessibilityFocused: Bool
    let task: TaskSessionSnapshot
    let inspectorFocusRequest: Int

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.displayTitle)
                        .font(.headline)
                        .foregroundStyle(palette.text)
                    Text("\(task.metadata.workspace.fallbackTitle) is not in the current MainFrame scan")
                        .font(.caption)
                        .foregroundStyle(palette.dim)
                }
                Spacer()
                Button("Browse Projects") {
                    model.showProjectBrowser = true
                }
                .buttonStyle(.bordered)
                Button {
                    model.toggleContextPresentation()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .buttonStyle(.bordered)
                .focused($inspectorButtonFocused)
                .accessibilityFocused($inspectorButtonAccessibilityFocused)
                .accessibilityLabel(
                    model.isContextInspectorPresented
                        ? "Hide inspector"
                        : "Show inspector"
                )
                .help("Show or hide Inspector (Command-Backslash)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider().overlay(palette.line)
            SessionSurfaceView(runtime: model.selectedTaskRuntime)
        }
        .background(palette.app)
        .onChange(of: inspectorFocusRequest) { request in
            if request > 0 {
                DispatchQueue.main.async {
                    inspectorButtonFocused = true
                    inspectorButtonAccessibilityFocused = true
                }
            }
        }
    }
}

private struct EmptyStateView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let systemImage: String
    let description: String

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(palette.dim)
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(palette.text)
            Text(description)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.dim)
                .frame(maxWidth: 420)
        }
        .padding(32)
    }
}

private struct PixelOnboardingMark: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width / 12, size.height / 12)
            func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: Color) {
                context.fill(Path(CGRect(x: CGFloat(x) * unit, y: CGFloat(y) * unit, width: CGFloat(w) * unit, height: CGFloat(h) * unit)), with: .color(color))
            }
            fill(5, 0, 2, 2, palette.accent)
            fill(5, 2, 2, 1, palette.dim)
            fill(2, 3, 8, 6, palette.dim.opacity(0.85))
            fill(3, 4, 6, 4, palette.surface)
            fill(4, 5, 1, 1, palette.accent)
            fill(7, 5, 1, 1, palette.accent)
            fill(0, 5, 2, 3, palette.dim)
            fill(10, 5, 2, 3, palette.dim)
            fill(3, 9, 2, 3, palette.dim)
            fill(7, 9, 2, 3, palette.dim)
        }
        .frame(width: 88, height: 88)
        .accessibilityHidden(true)
    }
}

/// Accessibility-only representation of the custom Inspector splitter.
/// Pointer/keyboard resizing stays on the SwiftUI handle; this supplies an
/// AXSlider with a stable VoiceOver name that SwiftUI Slider left empty.
private struct InspectorResizeAXSlider: NSViewRepresentable {
    var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var onChange: (Double) -> Void
    var onReset: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(step: step, onChange: onChange, onReset: onReset)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.valueChanged(_:))
        context.coordinator.applyAccessibility(to: slider, value: value)
        context.coordinator.installCustomActions(on: slider)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.step = step
        context.coordinator.onChange = onChange
        context.coordinator.onReset = onReset
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        if abs(slider.doubleValue - value) > 0.01 {
            slider.doubleValue = value
        }
        context.coordinator.applyAccessibility(to: slider, value: value)
        context.coordinator.installCustomActions(on: slider)
    }

    final class Coordinator: NSObject {
        var step: Double
        var onChange: (Double) -> Void
        var onReset: () -> Void

        init(
            step: Double,
            onChange: @escaping (Double) -> Void,
            onReset: @escaping () -> Void
        ) {
            self.step = step
            self.onChange = onChange
            self.onReset = onReset
        }

        @objc func valueChanged(_ sender: NSSlider) {
            let snapped = snap(sender.doubleValue, min: sender.minValue, max: sender.maxValue)
            if abs(sender.doubleValue - snapped) > 0.01 {
                sender.doubleValue = snapped
            }
            sender.setAccessibilityValue("\(Int(snapped.rounded())) points" as NSString)
            onChange(snapped)
        }

        func applyAccessibility(to slider: NSSlider, value: Double) {
            slider.setAccessibilityElement(true)
            slider.setAccessibilityRole(.slider)
            slider.setAccessibilityLabel("Resize Inspector")
            slider.setAccessibilityIdentifier("inspector-resize-handle")
            slider.setAccessibilityHelp(
                "Adjusts Inspector width without changing workspace density."
            )
            slider.setAccessibilityValue(
                "\(Int(value.rounded())) points" as NSString
            )
        }

        func installCustomActions(on slider: NSSlider) {
            slider.setAccessibilityCustomActions([
                NSAccessibilityCustomAction(
                    name: "Restore responsive Inspector width"
                ) { [weak self] in
                    self?.onReset()
                    return true
                }
            ])
        }

        private func snap(_ raw: Double, min lower: Double, max upper: Double) -> Double {
            guard step > 0 else {
                return min(max(raw, lower), upper)
            }
            let snapped = (raw / step).rounded() * step
            return min(max(snapped, lower), upper)
        }
    }
}
#endif
