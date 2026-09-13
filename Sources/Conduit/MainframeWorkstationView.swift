#if os(macOS)
import ConduitCore
import SwiftUI

struct MainframeWorkstationView: View {
    @ObservedObject var model: MainframeKnowledgeWorkspaceModel
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedStationID: String?

    private var palette: ConduitPalette { themeStore.palette(for: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                regionMap
                authoritySummary
                stationSection(title: "Projects", stations: model.workstation?.projects ?? [])
                stationSection(title: "Operations", stations: model.workstation?.operations ?? [])
                attentionSection
                if let station = selectedStation {
                    evidenceSection(station)
                }
            }
            .padding(20)
            .frame(maxWidth: 1200, alignment: .leading)
        }
        .background(palette.app)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MainFrame Workstation")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Workstation", systemImage: "square.grid.2x2")
                    .font(.title2.bold())
                    .foregroundStyle(palette.text)
                Spacer()
                if model.indexMayBeIncomplete {
                    Label("Bounded source", systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.dim)
                }
            }
            Text("Lifecycle orientation and observed work signals. Counts describe what Conduit can inspect; they are not project health or percent complete.")
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var regionMap: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("MainFrame regions")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 9)], spacing: 9) {
                ForEach(MainframeWorkstationRegion.allCases, id: \.self) { region in
                    regionCard(region)
                }
            }
        }
    }

    private func regionCard(_ region: MainframeWorkstationRegion) -> some View {
        let count = indexedItemCount(region)
        return VStack(alignment: .leading, spacing: 7) {
            MainframeRegionMotif(region: region)
                .frame(width: 38, height: 28)
                .accessibilityHidden(true)
            Text(region.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.text)
            Text("\(count) indexed item\(count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(palette.dim)
            Text(region.directoryName)
                .font(.caption2.monospaced())
                .foregroundStyle(palette.faint)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(region.displayName), \(count) indexed items")
    }

    private var authoritySummary: some View {
        let lifecycleIssues = model.workstation?.lifecycleIssueCount ?? 0
        let rootIssues = model.workstation?.rootIssueCount ?? 0
        return HStack(spacing: 12) {
            summaryPill("Projects", value: "\(model.workstation?.projects.count ?? 0)", symbol: "hammer")
            summaryPill("Operations", value: "\(model.workstation?.operations.count ?? 0)", symbol: "gearshape.2")
            summaryPill("Lifecycle issues", value: "\(lifecycleIssues)", symbol: lifecycleIssues == 0 ? "checkmark.seal" : "exclamationmark.triangle")
            summaryPill("Root issues", value: "\(rootIssues)", symbol: rootIssues == 0 ? "checkmark.circle" : "exclamationmark.triangle")
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func stationSection(title: String, stations: [MainframeWorkstationStation]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading(title)
            if stations.isEmpty {
                Text("No validated \(title.lowercased()) are present in the current lifecycle projection.")
                    .font(.caption)
                    .foregroundStyle(palette.faint)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                    ForEach(stations) { station in
                        stationCard(station)
                    }
                }
            }
        }
    }

    private func stationCard(_ station: MainframeWorkstationStation) -> some View {
        let tasks = taskHistories(for: station)
        let runtimes = openRuntimeCount(for: station)
        let receipts = receipts(for: station)
        let attention = model.attentionItems.first(where: { $0.scopePath == station.id })
        return Button {
            selectedStationID = station.id
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(station.title)
                            .font(.headline)
                            .foregroundStyle(palette.text)
                            .multilineTextAlignment(.leading)
                        Text(station.id)
                            .font(.caption2.monospaced())
                            .foregroundStyle(palette.faint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Label(
                        station.isAuthoritative ? "VALIDATED" : "UNVERIFIED",
                        systemImage: station.isAuthoritative ? "checkmark.seal" : "questionmark.circle"
                    )
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(station.isAuthoritative ? palette.accent : palette.dim)
                }

                ForEach(primarySignals(station)) { signal in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(signal.label.uppercased())
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(palette.faint)
                        Text(signal.value)
                            .font(.caption)
                            .foregroundStyle(palette.text)
                            .lineLimit(2)
                    }
                }

                Divider().overlay(palette.line)

                HStack(spacing: 10) {
                    observedMini("tasks", tasks.count)
                    observedMini("open", runtimes)
                    observedMini("receipts", receipts.count)
                    if let attention, attention.visitCount > 0 {
                        observedMini("visits", attention.visitCount)
                    }
                }
                Text("Observed counts only · no health score")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 158, alignment: .topLeading)
            .background(palette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(selectedStationID == station.id ? palette.accent : palette.line, lineWidth: selectedStationID == station.id ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open in Reader") { model.open(relativePath: station.id, surface: .reader) }
        }
        .accessibilityLabel("\(station.title), \(station.recordType?.rawValue ?? "record"), \(station.isAuthoritative ? "validated" : "unverified")")
        .accessibilityValue("\(tasks.count) task histories, \(runtimes) open runtimes, \(receipts.count) receipts")
    }

    private var attentionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Operator attention")
            Text("Derived only from navigation in this Explorer session. More visits means more navigation, not greater importance or urgency.")
                .font(.caption)
                .foregroundStyle(palette.dim)
            if model.attentionItems.isEmpty {
                Text("No project or operation navigation has been observed in this Explorer session yet.")
                    .font(.caption)
                    .foregroundStyle(palette.faint)
            } else {
                ForEach(model.attentionItems) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.isCurrent ? "scope" : "circle")
                            .foregroundStyle(item.isCurrent ? palette.accent : palette.faint)
                        Text(item.scopePath)
                            .font(.caption.monospaced())
                            .foregroundStyle(palette.text)
                            .lineLimit(1)
                        Spacer()
                        Text("\(item.visitCount) visit\(item.visitCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(palette.dim)
                    }
                }
            }
        }
        .padding(12)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func evidenceSection(_ station: MainframeWorkstationStation) -> some View {
        let tasks = taskHistories(for: station)
        let receipts = receipts(for: station)
        let events = evidenceEvents(station: station, tasks: tasks, receipts: receipts)
        let trail = MainframeEvidenceTrail(events: events)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeading("Evidence trail · \(station.title)")
                Spacer()
                Button("Open station") { model.open(relativePath: station.id, surface: .reader) }
                    .buttonStyle(.bordered)
            }
            Text("This trail contains explicit lifecycle objectives, durable Conduit task-history timestamps, and project-matched Conduit work-session receipts. It does not infer implementation success or review approval.")
                .font(.caption)
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)

            if trail.events.isEmpty {
                Text("No explicit trail sources are available for this station.")
                    .font(.caption)
                    .foregroundStyle(palette.faint)
            } else {
                ForEach(trail.events) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: evidenceSymbol(event.kind))
                            .foregroundStyle(palette.dim)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(palette.text)
                            if let detail = event.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(palette.dim)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack(spacing: 5) {
                                if let date = event.observedAt {
                                    Text(date.formatted(date: .abbreviated, time: .shortened))
                                } else {
                                    Text("No timestamp claimed")
                                }
                                Text("·")
                                Text(event.sourceLabel)
                            }
                            .font(.caption2)
                            .foregroundStyle(palette.faint)
                        }
                        Spacer(minLength: 0)
                        if let path = event.sourcePath, model.contentIndex?.records.contains(where: { $0.path == path }) == true {
                            Button("Open") { model.open(relativePath: path, surface: .reader) }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                    }
                    Divider().overlay(palette.line)
                }
            }
        }
        .padding(12)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var selectedStation: MainframeWorkstationStation? {
        guard let selectedStationID else { return nil }
        return model.workstation?.stations.first(where: { $0.id == selectedStationID })
    }

    private func taskHistories(for station: MainframeWorkstationStation) -> [TaskSessionSnapshot] {
        let absolute = model.root.appendingPathComponent(station.id).standardizedFileURL.path
        return appModel.taskSessions.filter { task in
            task.metadata.workspace.projectPath == absolute
        }
        .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private func openRuntimeCount(for station: MainframeWorkstationStation) -> Int {
        let absolute = model.root.appendingPathComponent(station.id).standardizedFileURL.path
        return appModel.sessions.filter { $0.descriptor.projectPath.standardizedFileURL.path == absolute }.count
    }

    private func receipts(for station: MainframeWorkstationStation) -> [MainframeDocumentRecord] {
        guard let records = model.contentIndex?.records else { return [] }
        return records.filter { record in
            guard record.path.hasPrefix("20_live/conduit/sessions/"), let markdown = record.markdown else { return false }
            return markdown.frontmatter["project"] == station.slug
                && markdown.frontmatter["tags"]?.contains("session-receipt") == true
        }
        .sorted { lhs, rhs in
            receiptDate(lhs) ?? .distantPast > receiptDate(rhs) ?? .distantPast
        }
    }

    private func evidenceEvents(
        station: MainframeWorkstationStation,
        tasks: [TaskSessionSnapshot],
        receipts: [MainframeDocumentRecord]
    ) -> [MainframeEvidenceEvent] {
        var events: [MainframeEvidenceEvent] = []
        if let goal = station.signals.first(where: { $0.kind == .goal }) {
            events.append(MainframeEvidenceEvent(
                id: "goal:\(station.id)",
                kind: .objective,
                title: "Lifecycle goal",
                detail: goal.value,
                observedAt: nil,
                sourceLabel: "Lifecycle authority",
                sourcePath: goal.sourcePath
            ))
        }
        for task in tasks.prefix(12) {
            events.append(MainframeEvidenceEvent(
                id: "task:\(task.id.rawValue.uuidString)",
                kind: .task,
                title: task.displayTitle,
                detail: task.metadata.agentName.map { "Conduit task history · \($0)" } ?? "Conduit task history",
                observedAt: task.createdAt,
                sourceLabel: "Conduit task metadata",
                sourcePath: nil
            ))
        }
        for receipt in receipts.prefix(12) {
            let objective = receipt.markdown.flatMap(receiptObjective)
            events.append(MainframeEvidenceEvent(
                id: "receipt:\(receipt.path)",
                kind: .receipt,
                title: receipt.markdown?.frontmatter["title"] ?? receipt.name,
                detail: objective,
                observedAt: receiptDate(receipt),
                sourceLabel: "Durable Conduit receipt",
                sourcePath: receipt.path
            ))
        }
        return events
    }

    private func receiptDate(_ record: MainframeDocumentRecord) -> Date? {
        guard let raw = record.markdown?.frontmatter["ended"] ?? record.markdown?.frontmatter["started"] else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    private func receiptObjective(_ document: MainframeMarkdownDocument) -> String? {
        guard let headingIndex = document.blocks.firstIndex(where: {
            if case .heading(let heading) = $0 { return heading.text.caseInsensitiveCompare("Objective") == .orderedSame }
            return false
        }) else { return nil }
        let next = headingIndex + 1
        guard document.blocks.indices.contains(next), case .paragraph(let text) = document.blocks[next] else { return nil }
        return text
    }

    private func primarySignals(_ station: MainframeWorkstationStation) -> [MainframeWorkstationSignal] {
        let priorities: [MainframeWorkstationSignalKind] = [.lifecycleState, .goal, .nextAction, .updated]
        return priorities.compactMap { kind in station.signals.first(where: { $0.kind == kind }) }
    }

    private func indexedItemCount(_ region: MainframeWorkstationRegion) -> Int {
        let prefix = region.directoryName + "/"
        return model.contentIndex?.filesystemEntries.filter { $0.relativePath == region.directoryName || $0.relativePath.hasPrefix(prefix) }.count ?? 0
    }

    private func observedMini(_ label: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(palette.text)
            Text(label)
                .font(.caption2)
                .foregroundStyle(palette.faint)
        }
    }

    private func summaryPill(_ label: String, value: String, symbol: String) -> some View {
        Label("\(label) \(value)", systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(palette.dim)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(palette.surface)
            .clipShape(Capsule())
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(palette.text)
    }

    private func evidenceSymbol(_ kind: MainframeEvidenceEventKind) -> String {
        switch kind {
        case .objective: return "scope"
        case .task: return "terminal"
        case .fileChange: return "doc.badge.ellipsis"
        case .test: return "checkmark.circle"
        case .pullRequest: return "arrow.triangle.pull"
        case .receipt: return "doc.text"
        case .review: return "eye"
        case .decision: return "signpost.right"
        case .milestone: return "flag"
        case .other: return "circle"
        }
    }
}

private struct MainframeRegionMotif: View {
    let region: MainframeWorkstationRegion
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette { themeStore.palette(for: colorScheme) }

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width / 9, size.height / 7)
            func block(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ opacity: Double = 1) {
                let rect = CGRect(x: CGFloat(x) * unit, y: CGFloat(y) * unit, width: CGFloat(w) * unit, height: CGFloat(h) * unit)
                context.fill(Path(rect), with: .color(palette.accent.opacity(opacity)))
            }
            switch region {
            case .inbox:
                block(1, 4, 7, 2, 0.65); block(2, 2, 5, 2, 0.35)
            case .ingest:
                block(1, 1, 2, 5, 0.35); block(4, 2, 4, 1, 0.65); block(4, 4, 3, 1, 0.5)
            case .knowledge:
                block(1, 1, 2, 5, 0.35); block(4, 1, 1, 5, 0.65); block(6, 1, 2, 5, 0.45)
            case .live:
                block(1, 3, 1, 2, 0.35); block(3, 2, 1, 4, 0.55); block(5, 1, 1, 5, 0.75); block(7, 3, 1, 2, 0.45)
            case .projects:
                block(1, 4, 7, 2, 0.45); block(2, 2, 2, 2, 0.65); block(5, 1, 2, 3, 0.35)
            case .operations:
                block(2, 1, 5, 1, 0.45); block(2, 3, 5, 1, 0.65); block(2, 5, 5, 1, 0.35); block(1, 2, 1, 3, 0.5); block(7, 2, 1, 3, 0.5)
            case .archive:
                block(1, 2, 7, 4, 0.35); block(2, 1, 5, 1, 0.65); block(3, 3, 3, 1, 0.45)
            }
        }
    }
}
#endif
