import SwiftUI
import Combine
import UIKit
#if canImport(Charts)
import Charts
#endif
#if canImport(UIKit)
import UIKit

final class OrientationAppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationAppDelegate.orientationLock
    }
}

// MARK: - Trip Logger

enum EVSourceChoice: String, Identifiable, CaseIterable {
    case evLab = "EV Lab Run"
    case manual = "Manual EV/hr"

    var id: String { rawValue }
}

enum SessionIncidentType: String, Identifiable, CaseIterable, Codable {
    case idCheck = "ID Check"
    case backoff = "Backoff"
    case trespass = "Trespass"

    var id: String { rawValue }
    var displayName: String { rawValue }
}

final class TripLoggerViewModel: ObservableObject {
    @Published var sessions: [TripSession] = []
    @Published var locationNotes: [LocationNote] = []
    @Published var loadErrorMessage: String?

    private let sessionKey = "tripSessions"
    private let locationNotesKey = "locationNotes"

    init() {
        sessions = []
        locationNotes = []
        loadErrorMessage = nil
    }

    func loadData() {
        loadSessions()
        loadLocationNotes()
    }

    func addOrUpdate(session: TripSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        persistSessions()
        updateLocationNotes(with: session)
    }

    func delete(session: TripSession) {
        sessions.removeAll { $0.id == session.id }
        persistSessions()
    }

    func save(note: LocationNote) {
        if let index = locationNotes.firstIndex(where: { $0.id == note.id }) {
            locationNotes[index] = note
        } else {
            locationNotes.append(note)
        }
        persistLocationNotes()
    }

    private func loadSessions() {
        guard let data = UserDefaults.standard.data(forKey: sessionKey), !data.isEmpty else {
            sessions = []
            return
        }

        do {
            sessions = try JSONDecoder().decode([TripSession].self, from: data)
        } catch {
            loadErrorMessage = "Previous trip log data was corrupted and has been reset."
            sessions = []
            UserDefaults.standard.set(Data(), forKey: sessionKey)
        }
    }

    private func loadLocationNotes() {
        guard let data = UserDefaults.standard.data(forKey: locationNotesKey), !data.isEmpty else {
            locationNotes = []
            return
        }

        do {
            locationNotes = try JSONDecoder().decode([LocationNote].self, from: data)
        } catch {
            loadErrorMessage = "Previous location notes were corrupted and have been reset."
            locationNotes = []
            UserDefaults.standard.set(Data(), forKey: locationNotesKey)
        }
    }

    private func persistSessions() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        UserDefaults.standard.set(data, forKey: sessionKey)
    }

    private func persistLocationNotes() {
        guard let data = try? JSONEncoder().encode(locationNotes) else { return }
        UserDefaults.standard.set(data, forKey: locationNotesKey)
    }

    private func updateLocationNotes(with session: TripSession) {
        let trimmed = session.comments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let key = "\(session.location.lowercased())|\(session.city.lowercased())"
        if let index = locationNotes.firstIndex(where: { $0.id == key }) {
            let combined = [locationNotes[index].notes, trimmed]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
            locationNotes[index].notes = combined
        } else {
            locationNotes.append(
                LocationNote(location: session.location, city: session.city, notes: trimmed)
            )
        }
        persistLocationNotes()
    }
}

struct TripLoggerView: View {
    @AppStorage("savedRuns") private var recentRunsData: Data = Data()
    @AppStorage("userSavedRuns") private var savedNamedRunsData: Data = Data()

    @StateObject private var viewModel = TripLoggerViewModel()
    @State private var showChart: Bool = true
    @State private var showAllSessions: Bool = false
    @State private var showAddSession: Bool = false
    @State private var editingSession: TripSession?
    @State private var selectedLocationNote: LocationNote?
    @State private var showLoadError: Bool = false

    private var sortedSessions: [TripSession] {
        viewModel.sessions.sorted { $0.timestamp > $1.timestamp }
    }

    private var displayedSessions: [TripSession] {
        let recent = Array(sortedSessions.prefix(10))
        return showAllSessions ? sortedSessions : recent
    }

    private var availableRuns: [SavedRun] {
        var runsByID: [UUID: SavedRun] = [:]
        decodeRuns(from: recentRunsData).forEach { runsByID[$0.id] = $0 }
        decodeRuns(from: savedNamedRunsData).forEach { runsByID[$0.id] = $0 }
        return runsByID.values.sorted { $0.timestamp > $1.timestamp }
    }

    private var totalEarnings: Double {
        viewModel.sessions.reduce(0) { $0 + $1.earnings }
    }

    private var totalHours: Double {
        viewModel.sessions.reduce(0) { $0 + $1.durationHours }
    }

    private var actualValuePerHour: Double {
        guard totalHours > 0 else { return 0 }
        return totalEarnings / totalHours
    }

    private var progressPoints: [TripProgressPoint] {
        var cumulativeHours: Double = 0
        var cumulativeActual: Double = 0
        var cumulativeExpected: Double = 0
        return sortedSessions.reversed().reduce(into: [TripProgressPoint]()) { partial, session in
            cumulativeHours += session.durationHours
            cumulativeActual += session.earnings
            cumulativeExpected += session.expectedValue
            partial.append(
                TripProgressPoint(
                    hourMark: cumulativeHours,
                    actual: cumulativeActual,
                    expected: cumulativeExpected
                )
            )
        }
        .sorted { $0.hourMark < $1.hourMark }
    }

    private var groupedLocationNotes: [LocationNote] {
        var notesByKey: [String: LocationNote] = [:]

        for note in viewModel.locationNotes {
            notesByKey[note.id] = note
        }

        for session in viewModel.sessions {
            let key = "\(session.location.lowercased())|\(session.city.lowercased())"
            if notesByKey[key] == nil {
                let trimmed = session.comments.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty || session.incidentType != nil {
                    notesByKey[key] = LocationNote(
                        location: session.location,
                        city: session.city,
                        notes: trimmed
                    )
                }
            }
        }

        return notesByKey.values.sorted { lhs, rhs in
            lhs.location.localizedCaseInsensitiveCompare(rhs.location) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                statsSection

                visualizeSection

                loggedSessionsSection

                locationNotesSection
            }
            .padding()
        }
        .navigationTitle("Trip Logger")
        .onAppear {
            viewModel.loadData()
            showLoadError = viewModel.loadErrorMessage != nil
        }
        .sheet(isPresented: $showAddSession) {
            SessionEditorView(
                availableRuns: availableRuns,
                sessionToEdit: nil
            ) { newSession in
                viewModel.addOrUpdate(session: newSession)
            }
        }
        .sheet(item: $editingSession) { session in
            SessionEditorView(
                availableRuns: availableRuns,
                sessionToEdit: session
            ) { updated in
                viewModel.addOrUpdate(session: updated)
            }
        }
        .sheet(item: $selectedLocationNote) { note in
            LocationNoteDetailView(
                note: note,
                sessions: viewModel.sessions,
                onSave: { updated in
                    viewModel.save(note: updated)
                }
            )
        }
        .alert(isPresented: $showLoadError) {
            Alert(title: Text("Trip Logger reset"), message: Text(viewModel.loadErrorMessage ?? ""), dismissButton: .default(Text("OK")))
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trackers")
                .font(.headline)

            HStack(spacing: 12) {
                statCard(title: "Total Earnings", value: totalEarnings, suffix: "", isCurrency: true)
                statCard(title: "AV ($/hr)", value: actualValuePerHour, suffix: " /hr", isCurrency: true)
                statCard(title: "Hours Played", value: totalHours, suffix: " hrs", isCurrency: false)
            }
        }
    }

    private var visualizeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Visualize Progress")
                    .font(.headline)
                Spacer()
                Button(showChart ? "Hide" : "Show") {
                    withAnimation { showChart.toggle() }
                }
                .buttonStyle(.bordered)
            }

            if showChart {
                if progressPoints.isEmpty {
                    Text("Log sessions to generate your Expected vs Actual progress chart.")
                        .foregroundColor(.secondary)
                } else {
#if canImport(Charts)
                    Chart {
                        ForEach(progressPoints) { point in
                            LineMark(
                                x: .value("Hours", point.hourMark),
                                y: .value("Value", point.actual)
                            )
                            .foregroundStyle(by: .value("Series", "Actual"))
                            .interpolationMethod(.catmullRom)
                        }

                        ForEach(progressPoints) { point in
                            LineMark(
                                x: .value("Hours", point.hourMark),
                                y: .value("Value", point.expected)
                            )
                            .foregroundStyle(by: .value("Series", "Expected"))
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    .frame(height: 220)
                    .chartForegroundStyleScale([
                        "Actual": .blue,
                        "Expected": .green
                    ])
                    .chartLegend(.visible)
#else
                    Text("Charts are not available on this platform.")
                        .foregroundColor(.secondary)
#endif
                }
            }
        }
    }

    private var loggedSessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Logged Sessions")
                    .font(.headline)
                Spacer()
                Button {
                    showAddSession = true
                } label: {
                    Label("Add Session", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            DisclosureGroup("Most recent sessions", isExpanded: .constant(true)) {
                    if displayedSessions.isEmpty {
                        Text("No sessions yet. Tap Add Session to start tracking.")
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(displayedSessions) { session in
                            sessionRow(session)
                            Divider()
                        }

                    if viewModel.sessions.count > 10 {
                        Button(showAllSessions ? "Show Fewer" : "See More") {
                            withAnimation { showAllSessions.toggle() }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    }
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(12)
        }
    }

    private func sessionRow(_ session: TripSession) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(session.location) — \(session.city)")
                    .font(.subheadline.weight(.semibold))
                Text(session.timestamp, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(String(format: "Earnings: $%.2f over %.2f hrs", session.earnings, session.durationHours))
                    .font(.caption)
                if let evName = session.evSourceName {
                    Text("EV Source: \(evName)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 12) {
                Button {
                    editingSession = session
                } label: {
                    Image(systemName: "pencil")
                }

                Button(role: .destructive) {
                    viewModel.delete(session: session)
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var locationNotesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Location Notes")
                .font(.headline)

            if groupedLocationNotes.isEmpty {
                Text("Your location notes will appear here after you log sessions.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(groupedLocationNotes) { note in
                    Button {
                        selectedLocationNote = note
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(note.location) — \(note.city)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(notePreview(note))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(12)
                    }
                }
            }
        }
    }

    private func notePreview(_ note: LocationNote) -> String {
        if let primaryIncident = incidentReports(for: note).first {
            return incidentDescription(from: primaryIncident)
        }
        let trimmed = note.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No comments yet" }
        return trimmed.components(separatedBy: .newlines).first ?? "No comments yet"
    }

    private func incidentReports(for note: LocationNote) -> [IncidentReport] {
        viewModel.sessions
            .filter {
                $0.incidentType != nil &&
                $0.location.caseInsensitiveCompare(note.location) == .orderedSame &&
                $0.city.caseInsensitiveCompare(note.city) == .orderedSame
            }
            .sorted { $0.timestamp > $1.timestamp }
            .compactMap {
                guard let type = $0.incidentType, let severity = $0.incidentSeverity else { return nil }
                return IncidentReport(type: type, severity: severity, date: $0.timestamp)
            }
    }

    private func incidentDescription(from report: IncidentReport) -> String {
        "\(report.type.displayName) (Severity \(Int(report.severity)))"
    }

    private func statCard(title: String, value: Double, suffix: String, isCurrency: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            let formattedValue = isCurrency ? String(format: "$%.2f", value) : String(format: "%.2f", value)
            Text(formattedValue)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if !suffix.isEmpty {
                Text(suffix)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(12)
    }

    private func decodeRuns(from data: Data) -> [SavedRun] {
        guard !data.isEmpty,
              let decoded = try? JSONDecoder().decode([SavedRun].self, from: data) else {
            return []
        }
        return decoded
    }
}

struct SessionEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let availableRuns: [SavedRun]
    var sessionToEdit: TripSession?
    var onSave: (TripSession) -> Void

    @State private var location: String = ""
    @State private var city: String = ""
    @State private var earningsText: String = ""
    @State private var durationText: String = ""
    @State private var comments: String = ""
    @State private var evChoice: EVSourceChoice = .evLab
    @State private var selectedRunID: UUID?
    @State private var manualEVText: String = ""
    @State private var validationAlert: String?
    @State private var showLowHoursAlert: Bool = false
    @State private var selectedIncident: SessionIncidentType?
    @State private var incidentSeverity: Double = 3

    private var selectedRun: SavedRun? {
        guard let id = selectedRunID else { return nil }
        return availableRuns.first(where: { $0.id == id })
    }

    private var totalHoursSimulated: Double {
        guard let run = selectedRun else { return 0 }
        return run.input.hoursToSimulate * Double(run.input.numRealities)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Session Details")) {
                    TextField("Location", text: $location)
                    TextField("City", text: $city)
                    TextField("Earnings", text: $earningsText)
                        .keyboardType(.decimalPad)
                    TextField("Duration (hours)", text: $durationText)
                        .keyboardType(.decimalPad)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Comments (optional)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextEditor(text: $comments)
                            .frame(minHeight: 80)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.2))
                            )
                    }
                }

                Section(header: Text("Backoffs / Trespasses")) {
                    Text("Select if you experienced any heat during this session.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(SessionIncidentType.allCases) { incident in
                        Toggle(isOn: Binding(
                            get: { selectedIncident == incident },
                            set: { isOn in
                                selectedIncident = isOn ? incident : nil
                            }
                        )) {
                            Text(incident.displayName)
                        }
                    }

                    if let incident = selectedIncident {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Severity of \(incident.displayName)")
                                .font(.subheadline)
                            HStack {
                                Slider(value: $incidentSeverity, in: 1...5, step: 1)
                                Text("\(Int(incidentSeverity))")
                                    .font(.caption)
                                    .frame(width: 28, alignment: .trailing)
                            }
                        }
                    }
                }

                Section(header: Text("Expected Value")) {
                    Picker("Source", selection: $evChoice) {
                        ForEach(EVSourceChoice.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    if evChoice == .evLab {
                        if availableRuns.isEmpty {
                            Text("Save a run in the EV Lab to link its EV/hr.")
                                .foregroundColor(.secondary)
                        } else {
                            Picker("Bet spread", selection: $selectedRunID) {
                                Text("Select a saved run").tag(UUID?.none)
                                ForEach(availableRuns) { run in
                                    Text(run.name ?? run.displayTitle).tag(Optional(run.id))
                                }
                            }
                            .onChange(of: selectedRunID) { _ in
                                if totalHoursSimulated < 1000 && selectedRunID != nil {
                                    showLowHoursAlert = true
                                }
                            }

                            if let run = selectedRun {
                                Text(String(format: "EV/hour: $%.2f", run.result.expectedValuePerHour))
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        TextField("EV per hour", text: $manualEVText)
                            .keyboardType(.decimalPad)
                    }
                }
            }
            .navigationTitle(sessionToEdit == nil ? "Add Session" : "Edit Session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save this Session") {
                        attemptSave()
                    }
                }
            }
            .onAppear(perform: loadExistingSession)
            .alert("Can't Save", isPresented: Binding(
                get: { validationAlert != nil },
                set: { newValue in
                    if !newValue { validationAlert = nil }
                }
            ), actions: {
                Button("OK", role: .cancel) { validationAlert = nil }
            }, message: {
                Text(validationAlert ?? "")
            })
            .alert("Consider longer simulations", isPresented: $showLowHoursAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("For more reliable EVs, try using bet spreads with at least 1000 simulated hours.")
            }
        }
    }

    private func loadExistingSession() {
        guard let sessionToEdit else { return }
        location = sessionToEdit.location
        city = sessionToEdit.city
        earningsText = String(format: "%.2f", sessionToEdit.earnings)
        durationText = String(format: "%.2f", sessionToEdit.durationHours)
        comments = sessionToEdit.comments
        manualEVText = String(format: "%.2f", sessionToEdit.evPerHour)
        selectedIncident = sessionToEdit.incidentType
        if let storedSeverity = sessionToEdit.incidentSeverity {
            incidentSeverity = storedSeverity
        }
        if let runID = sessionToEdit.evRunID, availableRuns.contains(where: { $0.id == runID }) {
            evChoice = .evLab
            selectedRunID = runID
        } else {
            evChoice = .manual
        }
    }

    private func attemptSave() {
        guard !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validationAlert = "Location and City are required."
            return
        }

        guard let earnings = Double(earningsText) else {
            validationAlert = "Please enter a valid number for earnings."
            return
        }

        guard let duration = Double(durationText), duration > 0 else {
            validationAlert = "Duration must be greater than zero."
            return
        }

        let evValue: Double
        var evSourceName: String? = nil
        var evRunID: UUID? = nil

        switch evChoice {
        case .evLab:
            guard let run = selectedRun else {
                validationAlert = "Select an EV Lab run to pull EV/hr from or switch to manual."
                return
            }
            evValue = run.result.expectedValuePerHour
            evSourceName = run.name ?? run.displayTitle
            evRunID = run.id
        case .manual:
            guard let manual = Double(manualEVText) else {
                validationAlert = "Enter a valid EV per hour value."
                return
            }
            evValue = manual
        }

        var newSession = sessionToEdit ?? TripSession(
            location: location,
            city: city,
            earnings: earnings,
            durationHours: duration,
            evPerHour: evValue,
            evRunID: evRunID,
            evSourceName: evSourceName,
            incidentType: selectedIncident,
            incidentSeverity: selectedIncident != nil ? incidentSeverity : nil,
            comments: comments
        )

        newSession.location = location
        newSession.city = city
        newSession.earnings = earnings
        newSession.durationHours = duration
        newSession.evPerHour = evValue
        newSession.evRunID = evRunID
        newSession.evSourceName = evSourceName
        newSession.incidentType = selectedIncident
        newSession.incidentSeverity = selectedIncident != nil ? incidentSeverity : nil
        newSession.comments = comments
        newSession.timestamp = sessionToEdit?.timestamp ?? Date()

        onSave(newSession)
        dismiss()
    }
}

struct LocationNoteDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let note: LocationNote
    var sessions: [TripSession]
    var onSave: (LocationNote) -> Void

    @State private var workingNotes: String = ""
    @State private var isEditing: Bool = false

    private var relatedComments: [String] {
        let existingNotesLower = note.notes.lowercased()
        return sessions
            .filter { $0.location.caseInsensitiveCompare(note.location) == .orderedSame && $0.city.caseInsensitiveCompare(note.city) == .orderedSame }
            .compactMap { $0.comments.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { comment in
                guard !comment.isEmpty else { return false }
                return !existingNotesLower.contains(comment.lowercased())
            }
    }

    private var incidentSummaries: [IncidentReport] {
        sessions
            .filter {
                $0.incidentType != nil &&
                $0.location.caseInsensitiveCompare(note.location) == .orderedSame &&
                $0.city.caseInsensitiveCompare(note.city) == .orderedSame
            }
            .sorted { $0.timestamp > $1.timestamp }
            .compactMap {
                guard let type = $0.incidentType, let severity = $0.incidentSeverity else { return nil }
                return IncidentReport(type: type, severity: severity, date: $0.timestamp)
            }
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                if !incidentSummaries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Heat Reports")
                            .font(.headline)
                        ForEach(incidentSummaries) { report in
                            Text(incidentDescription(from: report))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color.orange.opacity(0.1))
                                .cornerRadius(8)
                        }
                    }
                }

                if relatedComments.isEmpty && workingNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No comments yet")
                        .foregroundColor(.secondary)
                } else if !isEditing {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if !workingNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(workingNotes)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            ForEach(relatedComments.indices, id: \.self) { index in
                                Text(relatedComments[index])
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(Color.secondary.opacity(0.05))
                                    .cornerRadius(8)
                            }
                        }
                    }
                }

                if isEditing {
                    TextEditor(text: $workingNotes)
                        .frame(minHeight: 200)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3))
                        )
                }

                Spacer()
            }
            .padding()
            .navigationTitle("\(note.location) — \(note.city)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isEditing {
                        Button("Save") {
                            save()
                        }
                    } else {
                        Button("Edit or Add More Comments") {
                            isEditing = true
                        }
                    }
                }
            }
            .onAppear {
                workingNotes = note.notes
            }
        }
    }

    private func save() {
        var updated = note
        updated.notes = workingNotes
        onSave(updated)
        isEditing = false
    }

    private func incidentDescription(from report: IncidentReport) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        return "\(report.type.displayName) • Severity \(Int(report.severity)) • \(dateFormatter.string(from: report.date))"
    }
}

enum OrientationManager {
    static func forceLandscape() {
        setOrientation(.landscapeRight)
    }

    static func restorePortrait() {
        setOrientation(.portrait)
    }

    private static func setOrientation(_ orientation: UIInterfaceOrientation) {
        OrientationAppDelegate.orientationLock = orientation.isLandscape ? .landscape : .portrait
        UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()

        if #available(iOS 16.0, *), let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let mask: UIInterfaceOrientationMask = orientation.isLandscape ? .landscape : .portrait
            try? windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        }
    }
}
#endif

#if !canImport(UIKit)
enum OrientationManager {
    static func forceLandscape() {}
    static func restorePortrait() {}
}
#endif

// MARK: - Debug logging

struct DebugRecord: Identifiable, Codable {
    var id = UUID()
    var trueCount: Double
    var playerCards: [Int]
    var dealerUp: Int
    var dealerHole: Int
    var isSoft: Bool
    var total: Int
    var action: String
    var wager: Double
    var insuranceBet: Double
    var insuranceDecision: String
    var insuranceResult: String?
    var insuranceNet: Double?
    var bankrollStart: Double
    var payout: Double
    var bankrollEnd: Double
    var splitDepth: Int
    var result: String
    var realityIndex: Int
    var handIndex: Int
    var playerFinal: Int
    var dealerFinal: Int
}

// MARK: - Trip logging

struct TripSession: Identifiable, Codable, Equatable {
    var id: UUID = .init()
    var timestamp: Date = .init()
    var location: String
    var city: String
    var earnings: Double
    var durationHours: Double
    var evPerHour: Double
    var evRunID: UUID?
    var evSourceName: String?
    var incidentType: SessionIncidentType?
    var incidentSeverity: Double?
    var comments: String

    var expectedValue: Double { evPerHour * durationHours }
}

struct LocationNote: Identifiable, Codable, Equatable {
    var id: String { "\(location.lowercased())|\(city.lowercased())" }
    var location: String
    var city: String
    var notes: String
}

struct TripProgressPoint: Identifiable {
    var id: UUID = .init()
    var hourMark: Double
    var actual: Double
    var expected: Double
}

struct IncidentReport: Identifiable {
    var id: UUID = .init()
    var type: SessionIncidentType
    var severity: Double
    var date: Date
}

// MARK: - Core models

struct GameRules: Codable {
    var decks: Int
    var dealerHitsSoft17: Bool
    var doubleAfterSplit: Bool
    var surrenderAllowed: Bool
    /// Net profit multiple for a blackjack, e.g. 1.5 for 3:2, 1.2 for 6:5
    var blackjackPayout: Double
    var penetration: Double
}

extension GameRules {
    static var defaultStrategyRules: GameRules {
        GameRules(
            decks: 6,
            dealerHitsSoft17: true,
            doubleAfterSplit: true,
            surrenderAllowed: true,
            blackjackPayout: 1.5,
            penetration: 0.75
        )
    }
}

struct BetRampEntry: Identifiable, Codable {
    var id: UUID = .init()
    var trueCount: Int
    var bet: Double
}

struct BettingModel: Codable {
    var minBet: Double
    var spreads: [BetRampEntry]

    func bet(for trueCount: Double) -> Double {
        let sorted = spreads.sorted { $0.trueCount < $1.trueCount }
        var wager = minBet
        for entry in sorted {
            if trueCount >= Double(entry.trueCount) {
                wager = entry.bet
            } else {
                break
            }
        }
        return max(minBet, wager)
    }
}

struct DeviationManagerView: View {
    @Binding var deviations: [DeviationRule]
    var currentRules: GameRules

    @State private var selectedCategory: DeviationCategory = .all
    @State private var editorContext: DeviationRule?
    @State private var showingEditor: Bool = false
    @State private var showingChart: Bool = false
    @State private var duplicateAlert: Bool = false
    @State private var blockedByAllAlert: Bool = false
    @State private var moveToAllAlert: Bool = false
    @State private var pendingPromotionRule: DeviationRule?
    @State private var conflictingRule: DeviationRule?

    private var filteredDeviations: [DeviationRule] {
        deviations.filter { $0.category == selectedCategory }
    }

    private var sortedDeviations: [DeviationRule] {
        filteredDeviations.sorted(by: DeviationRule.sorter)
    }

    var body: some View {
        VStack {
            Picker("Category", selection: $selectedCategory) {
                ForEach(DeviationCategory.allCases) { category in
                    Text(category.displayName).tag(category)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            List {
                Section(header: categoryHeader) {
                    if filteredDeviations.isEmpty {
                        Text("No deviations in this category yet. Tap + to add one.")
                            .foregroundColor(.secondary)
                    }
                    ForEach(sortedDeviations) { deviation in
                        deviationRow(for: deviation)
                    }
                }
            }
            .listStyle(.insetGrouped)

            Button(action: { showingChart = true }) {
                Text("Visualize Deviations on Strategy Chart")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(12)
                    .padding(.horizontal)
            }
            .padding(.bottom)
        }
        .navigationTitle("Deviations")
        .alert("Duplicate deviation", isPresented: $duplicateAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("That deviation already exists in this category.")
        }
        .alert("Already in All", isPresented: $blockedByAllAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This deviation already exists in the All category. Please enable it there instead of creating a duplicate.")
        }
        .alert("Moved to All", isPresented: $moveToAllAlert) {
            Button("OK") { promotePendingRule() }
        } message: {
            Text("This deviation also exists in the other dealer rule set. It has been moved to the All category so it applies to both.")
        }
        .sheet(isPresented: $showingEditor) {
            DeviationEditorView(
                category: selectedCategory,
                existingRule: editorContext,
                onSave: { newRule in
                    addOrUpdateDeviation(newRule, editing: editorContext)
                },
                onDelete: { rule in
                    delete(rule)
                }
            )
        }
        .sheet(isPresented: $showingChart) {
            DeviationChartView(
                deviations: deviationsForVisualization,
                rules: visualizationRules,
                selectedCategory: selectedCategory
            )
        }
    }

    private var categoryHeader: some View {
        HStack {
            Text(selectedCategory.displayName)
            Spacer()
            Button(action: { showingEditor = true; editorContext = nil }) {
                Image(systemName: "plus.circle.fill")
                    .imageScale(.large)
            }
            .accessibilityLabel("Add deviation")
        }
    }

    private func addOrUpdateDeviation(_ newRule: DeviationRule, editing existing: DeviationRule?) {
        let duplicate = deviations.contains { candidate in
            candidate.hasSameSignature(as: newRule) && candidate.id != existing?.id
        }

        guard !duplicate else {
            duplicateAlert = true
            return
        }

        if let crossCategory = deviations.first(where: { candidate in
            candidate.hasSameCoreSignature(as: newRule) && candidate.category != newRule.category && candidate.id != existing?.id
        }) {
            if crossCategory.category == .all {
                blockedByAllAlert = true
                return
            }

            let isOppositeDealerRule = (newRule.category == .hit17 && crossCategory.category == .stand17) ||
                (newRule.category == .stand17 && crossCategory.category == .hit17)

            if isOppositeDealerRule {
                var promotedRule = newRule
                promotedRule.category = .all
                pendingPromotionRule = promotedRule
                conflictingRule = crossCategory
                moveToAllAlert = true
                return
            }
        }

        if let existing, let index = deviations.firstIndex(where: { $0.id == existing.id }) {
            deviations[index] = newRule
        } else {
            deviations.append(newRule)
        }
    }

    private func promotePendingRule() {
        guard let pendingPromotionRule else { return }

        if let conflictingRule {
            deviations.removeAll { $0.id == conflictingRule.id }
        }

        if let existing = editorContext, let index = deviations.firstIndex(where: { $0.id == existing.id }) {
            deviations[index] = pendingPromotionRule
        } else {
            deviations.append(pendingPromotionRule)
        }

        self.pendingPromotionRule = nil
        self.conflictingRule = nil
        self.moveToAllAlert = false
    }

    private func deviationRow(for deviation: DeviationRule) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(deviation.description)
                    .font(.body)
                Text(deviation.category.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let binding = binding(for: deviation) {
                Toggle("Enabled", isOn: binding)
                    .labelsHidden()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { beginEditing(deviation) }
        .swipeActions(allowsFullSwipe: false) {
            Button("Delete", role: .destructive) {
                delete(deviation)
            }
            Button("Edit") { beginEditing(deviation) }
                .tint(.blue)
        }
    }

    private func binding(for deviation: DeviationRule) -> Binding<Bool>? {
        guard let index = deviations.firstIndex(where: { $0.id == deviation.id }) else { return nil }
        return $deviations[index].isEnabled
    }

    private func beginEditing(_ deviation: DeviationRule) {
        editorContext = deviation
        showingEditor = true
    }

    private func delete(_ deviation: DeviationRule) {
        deviations.removeAll { $0.id == deviation.id }
    }

    private var deviationsForVisualization: [DeviationRule] {
        switch selectedCategory {
        case .all:
            return deviations.filter { $0.category == .all && $0.isEnabled }.sorted(by: DeviationRule.sorter)
        case .hit17, .stand17:
            let categorySpecific = deviations.filter { $0.category == selectedCategory && $0.isEnabled }
            let shared = deviations.filter { $0.category == .all && $0.isEnabled }
            return (categorySpecific + shared).sorted(by: DeviationRule.sorter)
        }
    }

    private var visualizationRules: GameRules {
        var rules = currentRules
        switch selectedCategory {
        case .hit17:
            rules.dealerHitsSoft17 = true
        case .stand17:
            rules.dealerHitsSoft17 = false
        case .all:
            break
        }
        return rules
    }
}

struct DeviationEditorView: View {
    @Environment(\.dismiss) private var dismiss
    var category: DeviationCategory
    var existingRule: DeviationRule?
    var onSave: (DeviationRule) -> Void
    var onDelete: ((DeviationRule) -> Void)? = nil

    @State private var playerCard1: Int = 10
    @State private var playerCard2: Int = 6
    @State private var dealerCard: Int = 10
    @State private var countMode: CountMode = .trueCountAtLeast
    @State private var trueCount: Int = 0
    @State private var action: PlayerAction = .stand

    private var availableActions: [PlayerAction] {
        var options: [PlayerAction] = [.hit, .stand, .surrender]
        let preview = handPreview
        options.append(.double)
        if preview.canSplit {
            options.append(.split)
        }
        return options
    }

    private var selectedCards: [Card] {
        [Card(rank: playerCard1), Card(rank: playerCard2)]
    }

    private var handPreview: Hand {
        Hand(cards: selectedCards)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Category")) {
                    Text(category.displayName)
                }

                Section(header: Text("Player hand")) {
                    Picker("First card", selection: $playerCard1) {
                        cardOptions
                    }
                    Picker("Second card", selection: $playerCard2) {
                        cardOptions
                    }
                    Text(handDescription())
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Dealer upcard")) {
                    Picker("Dealer card", selection: $dealerCard) {
                        cardOptions
                    }
                    .pickerStyle(.menu)
                }

                Section(header: Text("Count trigger")) {
                    Picker("Condition", selection: $countMode) {
                        ForEach(CountMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch countMode {
                    case .trueCountAtLeast:
                        Stepper("TC ≥ \(trueCount)", value: $trueCount, in: -20...20)
                    case .trueCountAtMost:
                        Stepper("TC ≤ \(trueCount)", value: $trueCount, in: -20...20)
                    case .runningPositive, .runningNegative:
                        Text(countMode == .runningPositive ? "Trigger on any positive running count" : "Trigger on any negative running count")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Action")) {
                    Picker("Action", selection: $action) {
                        ForEach(availableActions, id: \.self) { option in
                            Text(label(for: option)).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("Only viable actions for the selected hand are shown.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

            }
            .navigationTitle(existingRule == nil ? "New Deviation" : "Change Deviation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: { dismiss() })
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(availableActions.isEmpty)
                }
                if existingRule != nil {
                    ToolbarItem(placement: .bottomBar) {
                        Button(role: .destructive, action: deleteRule) {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Delete deviation")
                    }
                }
            }
            .onChange(of: availableActions) { options in
                if !options.contains(action) {
                    action = options.first ?? .stand
                }
            }
            .onAppear { preloadExisting() }
        }
    }

    private func handDescription() -> String {
        let descriptor = handPreview.isSoft ? "Soft" : "Hard"
        let dealerLabel = Card(rank: dealerCard).value == 11 ? "A" : "\(Card(rank: dealerCard).value)"
        return "\(descriptor) \(handPreview.bestValue) vs \(dealerLabel)"
    }

    private func label(for action: PlayerAction) -> String {
        switch action {
        case .hit: return "Hit"
        case .stand: return "Stand"
        case .double: return "Double"
        case .split: return "Split"
        case .surrender: return "Surrender"
        }
    }

    private func countCondition() -> CountCondition {
        switch countMode {
        case .trueCountAtLeast:
            return .trueCountAtLeast(trueCount)
        case .trueCountAtMost:
            return .trueCountAtMost(trueCount)
        case .runningPositive:
            return .runningPositive
        case .runningNegative:
            return .runningNegative
        }
    }

    private func save() {
        let hand = handPreview
        let rule = DeviationRule(
            id: existingRule?.id ?? UUID(),
            category: category,
            playerTotal: hand.bestValue,
            isSoft: hand.isSoft,
            pairRank: action == .split ? hand.cards.first?.rank : nil,
            dealerValue: Card(rank: dealerCard).value,
            action: action,
            countCondition: countCondition(),
            isEnabled: true
        )
        onSave(rule)
        dismiss()
    }

    private func deleteRule() {
        guard let existingRule, let onDelete else { return }
        onDelete(existingRule)
        dismiss()
    }

    private func preloadExisting() {
        guard let existingRule else { return }
        action = existingRule.action
        dealerCard = existingRule.dealerValue == 11 ? 1 : existingRule.dealerValue

        if let pairRank = existingRule.pairRank {
            playerCard1 = pairRank
            playerCard2 = pairRank
        } else if existingRule.isSoft {
            playerCard1 = 1
            playerCard2 = max(2, existingRule.playerTotal - 11)
        } else {
            let cardA = min(10, max(2, existingRule.playerTotal - 10))
            let cardB = max(2, existingRule.playerTotal - cardA)
            playerCard1 = cardA
            playerCard2 = cardB
        }

        switch existingRule.countCondition {
        case .trueCountAtLeast(let value):
            countMode = .trueCountAtLeast
            trueCount = value
        case .trueCountAtMost(let value):
            countMode = .trueCountAtMost
            trueCount = value
        case .runningPositive:
            countMode = .runningPositive
        case .runningNegative:
            countMode = .runningNegative
        }
    }

    private var cardOptions: some View {
        ForEach(1...10, id: \.self) { value in
            let label = value == 1 ? "A" : "\(value)"
            Text(label).tag(value)
        }
    }

    enum CountMode: String, CaseIterable, Identifiable {
        case trueCountAtLeast, trueCountAtMost, runningPositive, runningNegative

        var id: String { rawValue }

        var label: String {
            switch self {
            case .trueCountAtLeast: return "TC ≥"
            case .trueCountAtMost: return "TC ≤"
            case .runningPositive: return "+ Running"
            case .runningNegative: return "- Running"
            }
        }
    }
}

struct DeviationChartView: View {
    @Environment(\.dismiss) private var dismiss
    let deviations: [DeviationRule]
    let rules: GameRules
    let selectedCategory: DeviationCategory

    private let dealerValues = Array(2...11)

    private var rulesWithoutSurrender: GameRules {
        var copy = rules
        copy.surrenderAllowed = false
        return copy
    }

    private var standardDeviations: [DeviationRule] {
        deviations.filter { $0.action != .surrender }
    }

    private var surrenderDeviations: [DeviationRule] {
        deviations.filter { $0.action == .surrender }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Visualizing deviations for \(selectedCategory.displayName). Color-coded halves show base strategy on the left and deviations on the right.")
                        .font(.callout)
                        .foregroundColor(.secondary)

                    legendView

                    ChartSectionView(title: "Hard Totals", dealerValues: dealerValues, rows: hardRows)
                    ChartSectionView(title: "Soft Totals", dealerValues: dealerValues, rows: softRows)
                    ChartSectionView(title: "Pair Splitting", dealerValues: dealerValues, rows: pairRows)
                    ChartSectionView(title: "Surrender (Hard 14–16)", dealerValues: dealerValues, rows: surrenderRows)
                }
                .padding()
            }
            .navigationTitle("Strategy Chart")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: { dismiss() })
                }
            }
        }
        .onAppear { OrientationManager.forceLandscape() }
        .onDisappear { OrientationManager.restorePortrait() }
    }

    private var legendView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Legend")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                legendRow(color: chartActionColor(.hit), label: "H = Hit")
                legendRow(color: chartActionColor(.stand), label: "S = Stand")
                legendRow(color: chartActionColor(.double), label: "D = Double")
                legendRow(color: chartActionColor(.split), label: "P = Split")
                legendRow(color: chartActionColor(.surrender), label: "R = Surrender")
            }
        }
    }

    private func legendRow(color: Color, label: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color.opacity(0.6))
                .frame(width: 20, height: 14)

            Text(label)
                .font(.caption)
        }
    }

    private var hardRows: [ChartRowData] {
        (5...21).map { total in
            ChartRowData(label: "Hard \(total)", cells: cells(for: total, isSoft: false, pairRank: nil, deviations: standardDeviations, allowSurrenderBase: false))
        }
    }

    private var softRows: [ChartRowData] {
        (13...21).map { total in
            ChartRowData(label: "Soft \(total)", cells: cells(for: total, isSoft: true, pairRank: nil, deviations: standardDeviations, allowSurrenderBase: false))
        }
    }

    private var pairRows: [ChartRowData] {
        (1...10).map { rank in
            let label = rank == 1 ? "A,A" : "\(rank),\(rank)"
            return ChartRowData(label: "Pair \(label)", cells: cells(for: rank * 2, isSoft: false, pairRank: rank, deviations: standardDeviations, allowSurrenderBase: false))
        }
    }

    private var surrenderRows: [ChartRowData] {
        (14...16).map { total in
            ChartRowData(label: "Hard \(total)", cells: cells(for: total, isSoft: false, pairRank: nil, deviations: surrenderDeviations, allowSurrenderBase: true))
        }
    }

    private func cells(for total: Int, isSoft: Bool, pairRank: Int?, deviations: [DeviationRule], allowSurrenderBase: Bool) -> [ChartCellData] {
        dealerValues.map { dealer in
            let hand = handFor(total: total, isSoft: isSoft, pairRank: pairRank)
            let appliedRules = allowSurrenderBase ? rules : rulesWithoutSurrender
            let base = StrategyAdvisor.baseAction(for: hand, dealerUp: Card(rank: dealerCardRank(dealer)), rules: appliedRules)
            let deviationsHere = deviations.filter { rule in
                rule.playerTotal == total &&
                rule.isSoft == isSoft &&
                rule.dealerValue == dealer &&
                rule.pairRank == pairRank
            }
            let deviationEntries = deviationsHere
                .sorted(by: DeviationRule.sorter)
                .map { deviationEntry($0) }
            return ChartCellData(
                baseAction: base,
                baseLabel: shortLabel(for: base),
                deviations: deviationEntries,
                dealerValue: dealer
            )
        }
    }

    private func handFor(total: Int, isSoft: Bool, pairRank: Int?) -> Hand {
        if let pairRank {
            return Hand(cards: [Card(rank: pairRank), Card(rank: pairRank)])
        }

        if isSoft {
            let kicker = max(2, min(10, total - 11))
            return Hand(cards: [Card(rank: 1), Card(rank: kicker)])
        }

        for first in stride(from: min(total - 2, 10), through: 2, by: -1) {
            let second = total - first
            guard (2...10).contains(second) else { continue }
            let candidate = Hand(cards: [Card(rank: first), Card(rank: second)])
            if !candidate.isSoft { return candidate }
        }

        return Hand(cards: [Card(rank: 10), Card(rank: max(2, total - 10))])
    }

    private func dealerCardRank(_ value: Int) -> Int {
        value == 11 ? 1 : value
    }

    private func deviationEntry(_ deviation: DeviationRule) -> DeviationCellEntry {
        .init(
            action: deviation.action,
            label: "\(label(for: deviation.action)) (\(countLabel(deviation.countCondition)))"
        )
    }

    private func countLabel(_ condition: CountCondition) -> String {
        switch condition {
        case .trueCountAtLeast(let value):
            return "TC ≥ \(value)"
        case .trueCountAtMost(let value):
            return "TC ≤ \(value)"
        case .runningPositive:
            return "+ Running"
        case .runningNegative:
            return "- Running"
        }
    }

    private func label(for action: PlayerAction) -> String {
        switch action {
        case .hit: return "Hit"
        case .stand: return "Stand"
        case .double: return "Double"
        case .split: return "Split"
        case .surrender: return "Surrender"
        }
    }

    private func shortLabel(for action: PlayerAction) -> String {
        switch action {
        case .hit: return "H"
        case .stand: return "S"
        case .double: return "D"
        case .split: return "P"
        case .surrender: return "R"
        }
    }
}

struct BasicStrategyChartView: View {
    let rules: GameRules

    private let dealerValues = Array(2...11)

    private var rulesWithoutSurrender: GameRules {
        var copy = rules
        copy.surrenderAllowed = false
        return copy
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Standard basic strategy chart. Color coding matches the deviation visualizer for quick reference.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                legendView

                ChartSectionView(title: "Hard Totals", dealerValues: dealerValues, rows: hardRows)
                ChartSectionView(title: "Soft Totals", dealerValues: dealerValues, rows: softRows)
                ChartSectionView(title: "Pair Splitting", dealerValues: dealerValues, rows: pairRows)
                ChartSectionView(title: "Surrender (Hard 14–16)", dealerValues: dealerValues, rows: surrenderRows)
            }
            .padding()
        }
        .navigationTitle("Basic Strategy Chart")
        .onAppear { OrientationManager.forceLandscape() }
        .onDisappear { OrientationManager.restorePortrait() }
    }

    private var legendView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Legend")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                legendRow(color: chartActionColor(.hit), label: "H = Hit")
                legendRow(color: chartActionColor(.stand), label: "S = Stand")
                legendRow(color: chartActionColor(.double), label: "D = Double")
                legendRow(color: chartActionColor(.split), label: "P = Split")
                legendRow(color: chartActionColor(.surrender), label: "R = Surrender")
            }
        }
    }

    private func legendRow(color: Color, label: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color.opacity(0.6))
                .frame(width: 20, height: 14)

            Text(label)
                .font(.caption)
        }
    }

    private var hardRows: [ChartRowData] {
        (5...21).map { total in
            ChartRowData(label: "Hard \(total)", cells: cells(for: total, isSoft: false, pairRank: nil, allowSurrenderBase: false))
        }
    }

    private var softRows: [ChartRowData] {
        (13...21).map { total in
            ChartRowData(label: "Soft \(total)", cells: cells(for: total, isSoft: true, pairRank: nil, allowSurrenderBase: false))
        }
    }

    private var pairRows: [ChartRowData] {
        (2...10).map { rank in
            let label = rank == 1 ? "A" : "\(rank)"
            return ChartRowData(label: "Pair \(label)", cells: cells(for: rank * 2, isSoft: false, pairRank: rank, allowSurrenderBase: false))
        }
    }

    private var surrenderRows: [ChartRowData] {
        (14...16).map { total in
            ChartRowData(label: "Hard \(total)", cells: cells(for: total, isSoft: false, pairRank: nil, allowSurrenderBase: true))
        }
    }

    private func cells(for total: Int, isSoft: Bool, pairRank: Int?, allowSurrenderBase: Bool) -> [ChartCellData] {
        dealerValues.map { dealer in
            let hand = handFor(total: total, isSoft: isSoft, pairRank: pairRank)
            let appliedRules = allowSurrenderBase ? rules : rulesWithoutSurrender
            let base = StrategyAdvisor.baseAction(for: hand, dealerUp: Card(rank: dealerCardRank(dealer)), rules: appliedRules)
            return ChartCellData(
                baseAction: base,
                baseLabel: shortLabel(for: base),
                deviations: [],
                dealerValue: dealer
            )
        }
    }

    private func handFor(total: Int, isSoft: Bool, pairRank: Int?) -> Hand {
        if let pairRank {
            return Hand(cards: [Card(rank: pairRank), Card(rank: pairRank)])
        }

        if isSoft {
            let kicker = max(2, min(10, total - 11))
            return Hand(cards: [Card(rank: 1), Card(rank: kicker)])
        }

        for first in stride(from: min(total - 2, 10), through: 2, by: -1) {
            let second = total - first
            guard (2...10).contains(second) else { continue }
            let candidate = Hand(cards: [Card(rank: first), Card(rank: second)])
            if !candidate.isSoft { return candidate }
        }

        return Hand(cards: [Card(rank: 10), Card(rank: max(2, total - 10))])
    }

    private func dealerCardRank(_ value: Int) -> Int {
        value == 11 ? 1 : value
    }

    private func shortLabel(for action: PlayerAction) -> String {
        switch action {
        case .hit: return "H"
        case .stand: return "S"
        case .double: return "D"
        case .split: return "P"
        case .surrender: return "R"
        }
    }
}

struct ChartRowData: Identifiable {
    var id = UUID()
    let label: String
    let cells: [ChartCellData]
}

struct ChartCellData: Identifiable {
    var id = UUID()
    let baseAction: PlayerAction
    let baseLabel: String
    let deviations: [DeviationCellEntry]
    let dealerValue: Int
}

enum StrategyChartSectionType: String, CaseIterable, Identifiable {
    case hardTotals
    case softTotals
    case pairSplitting
    case surrender

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hardTotals: return "Hard Totals"
        case .softTotals: return "Soft Totals"
        case .pairSplitting: return "Pair Splitting"
        case .surrender: return "Surrender (Hard 14–16)"
        }
    }
}

struct StrategyChartSectionData: Identifiable {
    let id = UUID()
    let type: StrategyChartSectionType
    let rows: [ChartRowData]

    var title: String { type.title }
}

struct BasicStrategyChartBuilder {
    let rules: GameRules

    let dealerValues = Array(2...11)

    private var rulesWithoutSurrender: GameRules {
        var copy = rules
        copy.surrenderAllowed = false
        return copy
    }

    func sections(includeHard: Bool, includeSoft: Bool, includePairs: Bool, includeSurrender: Bool) -> [StrategyChartSectionData] {
        var result: [StrategyChartSectionData] = []

        if includeHard {
            result.append(.init(type: .hardTotals, rows: hardRows()))
        }

        if includeSoft {
            result.append(.init(type: .softTotals, rows: softRows()))
        }

        if includePairs {
            result.append(.init(type: .pairSplitting, rows: pairRows()))
        }

        if includeSurrender {
            result.append(.init(type: .surrender, rows: surrenderRows()))
        }

        return result
    }

    func hardRows() -> [ChartRowData] {
        (5...21).map { total in
            ChartRowData(label: "Hard \(total)", cells: cells(for: total, isSoft: false, pairRank: nil, allowSurrenderBase: false))
        }
    }

    func softRows() -> [ChartRowData] {
        (13...21).map { total in
            ChartRowData(label: "Soft \(total)", cells: cells(for: total, isSoft: true, pairRank: nil, allowSurrenderBase: false))
        }
    }

    func pairRows() -> [ChartRowData] {
        (2...10).map { rank in
            let label = rank == 1 ? "A" : "\(rank)"
            return ChartRowData(label: "Pair \(label)", cells: cells(for: rank * 2, isSoft: false, pairRank: rank, allowSurrenderBase: false))
        }
    }

    func surrenderRows() -> [ChartRowData] {
        (14...16).map { total in
            ChartRowData(label: "Hard \(total)", cells: cells(for: total, isSoft: false, pairRank: nil, allowSurrenderBase: true))
        }
    }

    private func cells(for total: Int, isSoft: Bool, pairRank: Int?, allowSurrenderBase: Bool) -> [ChartCellData] {
        dealerValues.map { dealer in
            let hand = handFor(total: total, isSoft: isSoft, pairRank: pairRank)
            let appliedRules = allowSurrenderBase ? rules : rulesWithoutSurrender
            let base = StrategyAdvisor.baseAction(for: hand, dealerUp: Card(rank: dealerCardRank(dealer)), rules: appliedRules)
            return ChartCellData(
                baseAction: base,
                baseLabel: shortLabel(for: base),
                deviations: [],
                dealerValue: dealer
            )
        }
    }

    private func handFor(total: Int, isSoft: Bool, pairRank: Int?) -> Hand {
        if let pairRank {
            return Hand(cards: [Card(rank: pairRank), Card(rank: pairRank)])
        }

        if isSoft {
            let kicker = max(2, min(10, total - 11))
            return Hand(cards: [Card(rank: 1), Card(rank: kicker)])
        }

        for first in stride(from: min(total - 2, 10), through: 2, by: -1) {
            let second = total - first
            guard (2...10).contains(second) else { continue }
            let candidate = Hand(cards: [Card(rank: first), Card(rank: second)])
            if !candidate.isSoft { return candidate }
        }

        return Hand(cards: [Card(rank: 10), Card(rank: max(2, total - 10))])
    }

    private func dealerCardRank(_ value: Int) -> Int {
        value == 11 ? 1 : value
    }

    private func shortLabel(for action: PlayerAction) -> String {
        switch action {
        case .hit: return "H"
        case .stand: return "S"
        case .double: return "D"
        case .split: return "P"
        case .surrender: return "R"
        }
    }
}

private func chartActionColor(_ action: PlayerAction) -> Color {
    switch action {
    case .hit:
        return .green
    case .double:
        return .red
    case .stand:
        return .yellow
    case .split:
        return .gray
    case .surrender:
        return .white
    }
}

struct DeviationCellEntry: Identifiable {
    var id = UUID()
    let action: PlayerAction
    let label: String
}

struct ChartSectionView: View {
    let title: String
    let dealerValues: [Int]
    let rows: [ChartRowData]

    private var columns: [GridItem] {
        [GridItem(.fixed(90))] + Array(repeating: GridItem(.flexible(minimum: 30)), count: dealerValues.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            LazyVGrid(columns: columns, spacing: 6) {
                Text("")
                ForEach(dealerValues, id: \.self) { value in
                    Text(value == 11 ? "A" : "\(value)")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                }

                ForEach(rows) { row in
                    Text(row.label)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    ForEach(row.cells) { cell in
                        chartCell(for: cell)
                    }
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(12)
    }

    @ViewBuilder
    private func chartCell(for cell: ChartCellData) -> some View {
        let deviationAction = cell.deviations.first?.action

        ZStack {
            if let deviationAction {
                HStack(spacing: 0) {
                    chartActionColor(cell.baseAction).opacity(0.35)
                        .frame(maxWidth: .infinity)

                    chartActionColor(deviationAction).opacity(0.55)
                        .frame(maxWidth: .infinity)
                }
            } else {
                chartActionColor(cell.baseAction).opacity(0.35)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(spacing: 4) {
                Text(cell.baseLabel)
                    .font(.subheadline.weight(.semibold))

                if !cell.deviations.isEmpty {
                    ForEach(cell.deviations) { deviation in
                        Text(deviation.label)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
}

struct SimulationInput: Codable {
    var rules: GameRules
    var betting: BettingModel
    /// Hours per simulation (per reality)
    var hoursToSimulate: Double
    /// Hands per hour
    var handsPerHour: Double
    /// Number of independent simulations (realities)
    var numRealities: Int
    var bankroll: Double
    var takeInsurance: Bool = true
    var useBasicDeviations: Bool = true
    var deviations: [DeviationRule] = DeviationRule.defaultRules

    enum CodingKeys: String, CodingKey {
        case rules
        case betting
        case hoursToSimulate
        case handsPerHour
        case numRealities
        case bankroll
        case takeInsurance
        case useBasicDeviations
        case deviations
    }

    init(
        rules: GameRules,
        betting: BettingModel,
        hoursToSimulate: Double,
        handsPerHour: Double,
        numRealities: Int,
        bankroll: Double,
        takeInsurance: Bool = true,
        useBasicDeviations: Bool = true,
        deviations: [DeviationRule] = DeviationRule.defaultRules
    ) {
        self.rules = rules
        self.betting = betting
        self.hoursToSimulate = hoursToSimulate
        self.handsPerHour = handsPerHour
        self.numRealities = numRealities
        self.bankroll = bankroll
        self.takeInsurance = takeInsurance
        self.useBasicDeviations = useBasicDeviations
        self.deviations = deviations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rules = try container.decode(GameRules.self, forKey: .rules)
        betting = try container.decode(BettingModel.self, forKey: .betting)
        hoursToSimulate = try container.decode(Double.self, forKey: .hoursToSimulate)
        handsPerHour = try container.decode(Double.self, forKey: .handsPerHour)
        numRealities = try container.decode(Int.self, forKey: .numRealities)
        bankroll = try container.decode(Double.self, forKey: .bankroll)
        takeInsurance = try container.decodeIfPresent(Bool.self, forKey: .takeInsurance) ?? true
        useBasicDeviations = try container.decodeIfPresent(Bool.self, forKey: .useBasicDeviations) ?? true
        deviations = try container.decodeIfPresent([DeviationRule].self, forKey: .deviations) ?? DeviationRule.defaultRules
    }
}

struct SimulationResult: Codable {
    var expectedValuePerHour: Double
    var standardDeviationPerHour: Double
    /// 0–1 probability of going broke in a reality
    var riskOfRuin: Double
    var averageBet: Double
    var medianBet: Double
    /// Fraction of realities that finished with bankroll > starting bankroll
    var percentPositiveOutcomes: Double
    /// Max final bankroll across realities
    var bestEndingBankroll: Double
    /// Min final bankroll across realities
    var worstEndingBankroll: Double
    /// Hours to bust for the worst reality (if that worst one busted)
    var hoursToBustWorst: Double?
    var totalEv: Double // EV/hand
    var totalSd: Double // SD/hand
}

struct Card {
    let rank: Int

    var hiLoValue: Int {
        switch rank {
        case 2...6: return 1
        case 7...9: return 0
        default: return -1
        }
    }

    var value: Int {
        switch rank {
        case 1: return 11
        case 11...13: return 10
        default: return rank
        }
    }
}

struct Hand {
    var cards: [Card]
    var isSplitAce: Bool = false
    var fromSplit: Bool = false

    var values: [Int] {
        var totals = [0]
        for card in cards {
            let cardValues: [Int]
            if card.rank == 1 {
                cardValues = [1, 11]
            } else {
                cardValues = [card.value]
            }

            var newTotals: [Int] = []
            for total in totals {
                for cValue in cardValues {
                    newTotals.append(total + cValue)
                }
            }
            totals = Array(Set(newTotals))
        }
        return totals
    }

    var bestValue: Int {
        let valid = values.filter { $0 <= 21 }
        return valid.max() ?? values.min() ?? 0
    }

    var isBlackjack: Bool {
        cards.count == 2 && bestValue == 21
    }

    var isBusted: Bool {
        bestValue > 21
    }

    /// true only if there is an alternate total 10 points lower (i.e. a usable Ace)
    var isSoft: Bool {
        let total = bestValue
        guard total <= 21 else { return false }
        return values.contains(total - 10)
    }

    var canSplit: Bool {
        cards.count == 2 && cards[0].rank == cards[1].rank
    }
}

enum PlayerAction: String, Codable, CaseIterable, Hashable {
    case hit, stand, double, split, surrender
}

enum DeviationCategory: String, Codable, CaseIterable, Identifiable {
    case hit17, stand17, all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hit17: return "Hit 17"
        case .stand17: return "Stand 17"
        case .all: return "All"
        }
    }
}

enum CountCondition: Codable, Equatable {
    case trueCountAtLeast(Int)
    case trueCountAtMost(Int)
    case runningPositive
    case runningNegative

    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    enum ConditionType: String, Codable {
        case trueCountAtLeast
        case trueCountAtMost
        case runningPositive
        case runningNegative
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ConditionType.self, forKey: .type)
        switch type {
        case .trueCountAtLeast:
            let value = try container.decode(Int.self, forKey: .value)
            self = .trueCountAtLeast(value)
        case .trueCountAtMost:
            let value = try container.decode(Int.self, forKey: .value)
            self = .trueCountAtMost(value)
        case .runningPositive:
            self = .runningPositive
        case .runningNegative:
            self = .runningNegative
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .trueCountAtLeast(let value):
            try container.encode(ConditionType.trueCountAtLeast, forKey: .type)
            try container.encode(value, forKey: .value)
        case .trueCountAtMost(let value):
            try container.encode(ConditionType.trueCountAtMost, forKey: .type)
            try container.encode(value, forKey: .value)
        case .runningPositive:
            try container.encode(ConditionType.runningPositive, forKey: .type)
        case .runningNegative:
            try container.encode(ConditionType.runningNegative, forKey: .type)
        }
    }
}

struct DeviationRule: Identifiable, Codable, Equatable {
    var id: UUID = .init()
    var category: DeviationCategory
    var playerTotal: Int
    var isSoft: Bool
    var pairRank: Int?
    var dealerValue: Int
    var action: PlayerAction
    var countCondition: CountCondition
    var isEnabled: Bool = true

    var description: String {
        let handDescription: String
        if let pairRank {
            handDescription = "Pair of \(rankLabel(pairRank))"
        } else {
            handDescription = isSoft ? "Soft \(playerTotal)" : "Hard \(playerTotal)"
        }

        let dealerLabel = dealerValue == 11 ? "A" : "\(dealerValue)"
        let countText: String
        switch countCondition {
        case .trueCountAtLeast(let value):
            countText = "TC ≥ \(value)"
        case .trueCountAtMost(let value):
            countText = "TC ≤ \(value)"
        case .runningPositive:
            countText = "Any positive running count"
        case .runningNegative:
            countText = "Any negative running count"
        }

        return "\(handDescription) vs \(dealerLabel): \(actionLabel(action)) when \(countText)"
    }

    func hasSameSignature(as other: DeviationRule) -> Bool {
        category == other.category &&
        playerTotal == other.playerTotal &&
        isSoft == other.isSoft &&
        pairRank == other.pairRank &&
        dealerValue == other.dealerValue &&
        action == other.action &&
        countCondition == other.countCondition
    }

    func hasSameCoreSignature(as other: DeviationRule) -> Bool {
        playerTotal == other.playerTotal &&
        isSoft == other.isSoft &&
        pairRank == other.pairRank &&
        dealerValue == other.dealerValue &&
        action == other.action &&
        countCondition == other.countCondition
    }

    static func sorter(lhs: DeviationRule, rhs: DeviationRule) -> Bool {
        let leftGroup = lhs.pairRank != nil ? 2 : (lhs.isSoft ? 1 : 0)
        let rightGroup = rhs.pairRank != nil ? 2 : (rhs.isSoft ? 1 : 0)

        if leftGroup != rightGroup { return leftGroup < rightGroup }

        if lhs.playerTotal != rhs.playerTotal { return lhs.playerTotal < rhs.playerTotal }

        if lhs.countSortValue != rhs.countSortValue { return lhs.countSortValue < rhs.countSortValue }

        return lhs.actionSortOrder < rhs.actionSortOrder
    }

    private var countSortValue: Int {
        switch countCondition {
        case .trueCountAtLeast(let value):
            return value
        case .trueCountAtMost(let value):
            return value
        case .runningNegative:
            return Int.min / 2
        case .runningPositive:
            return Int.max / 2
        }
    }

    private var actionSortOrder: Int {
        let order: [PlayerAction] = [.hit, .stand, .double, .split, .surrender]
        return order.firstIndex(of: action) ?? order.count
    }

    private func rankLabel(_ rank: Int) -> String {
        switch rank {
        case 1: return "A"
        case 11: return "J"
        case 12: return "Q"
        case 13: return "K"
        default: return "\(rank)"
        }
    }

    private func actionLabel(_ action: PlayerAction) -> String {
        switch action {
        case .hit: return "Hit"
        case .stand: return "Stand"
        case .double: return "Double"
        case .split: return "Split"
        case .surrender: return "Surrender"
        }
    }

    static var defaultRules: [DeviationRule] {
        [
            // Minimal starting set
            .init(category: .all, playerTotal: 20, isSoft: false, pairRank: 10, dealerValue: 6, action: .split, countCondition: .trueCountAtLeast(4)),
            .init(category: .all, playerTotal: 16, isSoft: false, pairRank: nil, dealerValue: 10, action: .stand, countCondition: .trueCountAtLeast(0)),
            .init(category: .all, playerTotal: 15, isSoft: false, pairRank: nil, dealerValue: 10, action: .stand, countCondition: .trueCountAtLeast(4))
        ]
    }
}

struct StrategyAdvisor {
    static func baseAction(for hand: Hand, dealerUp: Card, rules: GameRules) -> PlayerAction {
        // Surrender (late)
        if rules.surrenderAllowed && hand.cards.count == 2 {
            let dealerVal = dealerUp.value
            let dealerIsAce = (dealerUp.rank == 1)

            if hand.bestValue == 16 && (dealerVal == 9 || dealerVal == 10 || dealerIsAce) {
                return .surrender
            }
            if hand.bestValue == 15 && dealerVal == 10 {
                return .surrender
            }
        }

        // Pairs
        if hand.canSplit {
            let rank = hand.cards[0].rank
            switch rank {
            case 1:
                return .split
            case 10:
                return .stand
            case 9:
                return [2, 3, 4, 5, 6, 8, 9].contains(dealerUp.value) ? .split : .stand
            case 8:
                return .split
            case 7:
                return dealerUp.value <= 7 ? .split : .hit
            case 6:
                return dealerUp.value <= 6 ? .split : .hit
            case 5:
                return basicHardStrategy(total: 10, dealerUp: dealerUp)
            case 4:
                return (5...6).contains(dealerUp.value) ? .split : .hit
            case 3, 2:
                return dealerUp.value <= 7 ? .split : .hit
            default:
                break
            }
        }

        let total = hand.bestValue
        let containsAce = hand.values.contains(total - 10) && total <= 21

        var action: PlayerAction
        if containsAce && total <= 21 {
            action = basicSoftStrategy(total: total, dealerUp: dealerUp)
        } else {
            action = basicHardStrategy(total: total, dealerUp: dealerUp)
        }

        // No double after split when DAS is off
        if action == .double && hand.fromSplit && !rules.doubleAfterSplit {
            action = .hit
        }

        return action
    }

    private static func basicHardStrategy(total: Int, dealerUp: Card) -> PlayerAction {
        switch total {
        case ..<9:
            return .hit
        case 9:
            return (3...6).contains(dealerUp.value) ? .double : .hit
        case 10:
            return (2...9).contains(dealerUp.value) ? .double : .hit
        case 11:
            return .double
        case 12:
            return (4...6).contains(dealerUp.value) ? .stand : .hit
        case 13...16:
            return (2...6).contains(dealerUp.value) ? .stand : .hit
        default:
            return .stand
        }
    }

    private static func basicSoftStrategy(total: Int, dealerUp: Card) -> PlayerAction {
        switch total {
        case 13, 14:
            return (5...6).contains(dealerUp.value) ? .double : .hit
        case 15, 16:
            return (4...6).contains(dealerUp.value) ? .double : .hit
        case 17:
            return (3...6).contains(dealerUp.value) ? .double : .hit
        case 18:
            let up = dealerUp.value
            if (2...6).contains(up) { return .double }
            if (7...8).contains(up) { return .stand }
            return .hit
        case 19:
            if dealerUp.value == 6 { return .double }
            return .stand
        default:
            return .stand
        }
    }
}

enum HandResult: String {
    case win, loss, push, blackjack, surrender, bust
}

// MARK: - Simulator

class BlackjackSimulator {
    private var shoe: [Card] = []
    private var runningCount: Int = 0
    private var cutCardReached: Bool = false

    private let rules: GameRules
    private let betting: BettingModel
    private let activeDeviations: [DeviationRule]
    private let takeInsurance: Bool
    private let debugEnabled: Bool

    // Exposed debug log
    var debugLog: [DebugRecord] = []

    init(input: SimulationInput, debugEnabled: Bool = false) {
        self.rules = input.rules
        self.betting = input.betting
        self.activeDeviations = input.deviations.filter { $0.isEnabled }
        self.takeInsurance = input.takeInsurance
        self.debugEnabled = debugEnabled
        reshuffle()
    }

    private var trueCount: Double {
        let decksRemaining = Double(shoe.count) / 52.0
        guard decksRemaining > 0 else { return 0 }
        return Double(runningCount) / decksRemaining
    }

    private func reshuffle() {
        shoe.removeAll()
        for _ in 0..<rules.decks {
            for rank in 1...13 {
                for _ in 0..<4 {
                    shoe.append(Card(rank: rank))
                }
            }
        }
        shoe.shuffle()
        runningCount = 0
        cutCardReached = false
    }

    private func prepareShoeForNewHand() {
        let remainingFraction = Double(shoe.count) / Double(rules.decks * 52)
        if cutCardReached || remainingFraction < (1 - rules.penetration) {
            reshuffle()
        }
    }

    private func drawCard() -> Card {
        let remainingFraction = Double(shoe.count) / Double(rules.decks * 52)
        if !cutCardReached && remainingFraction < (1 - rules.penetration) {
            cutCardReached = true
        }
        if shoe.isEmpty {
            reshuffle()
        }
        let card = shoe.removeLast()
        runningCount += card.hiLoValue
        return card
    }

    private func dealerPlay(_ hand: Hand) -> Hand {
        var hand = hand
        while true {
            let value = hand.bestValue
            let isSoft = hand.values.contains(where: { $0 <= 21 && $0 + 10 == value }) && value <= 21
            if value < 17 || (value == 17 && rules.dealerHitsSoft17 && isSoft) {
                hand.cards.append(drawCard())
            } else {
                break
            }
        }
        return hand
    }

    private func basicStrategy(for hand: Hand, dealerUp: Card) -> PlayerAction {
        StrategyAdvisor.baseAction(for: hand, dealerUp: dealerUp, rules: rules)
    }

    private func actionName(_ action: PlayerAction) -> String {
        switch action {
        case .hit: return "H"
        case .stand: return "S"
        case .double: return "D"
        case .split: return "P"
        case .surrender: return "R"
        }
    }

    // Insurance helper: Hi-Lo, take insurance at TC >= +3 vs Ace
    private func insuranceBetAmount(for bet: Double, dealerUp: Card, splitDepth: Int) -> Double {
        guard takeInsurance else { return 0 }
        // Only on original hand and only vs Ace
        guard splitDepth == 0, dealerUp.rank == 1 else { return 0 }
        let tc = trueCount
        return tc >= 3 ? bet / 2.0 : 0.0
    }

    // Deviations: configurable per category
    private func applyDeviations(base: PlayerAction, hand: Hand, dealerUp: Card) -> PlayerAction {
        var current = base
        for deviation in activeDeviations where deviationMatches(deviation, hand: hand, dealerUp: dealerUp) {
            current = deviation.action
        }
        return current
    }

    private func deviationMatches(_ deviation: DeviationRule, hand: Hand, dealerUp: Card) -> Bool {
        switch deviation.category {
        case .all:
            break
        case .hit17:
            guard rules.dealerHitsSoft17 else { return false }
        case .stand17:
            guard !rules.dealerHitsSoft17 else { return false }
        }

        let total = hand.bestValue
        guard total == deviation.playerTotal else { return false }
        guard hand.isSoft == deviation.isSoft else { return false }

        if let pairRank = deviation.pairRank {
            guard hand.canSplit, hand.cards.first?.rank == pairRank else { return false }
        }

        if deviation.action == .split && !hand.canSplit {
            return false
        }

        if deviation.action == .surrender && !rules.surrenderAllowed {
            return false
        }

        if deviation.action == .double && hand.cards.count > 2 {
            return false
        }

        if deviation.action == .surrender && hand.cards.count > 2 {
            return false
        }

        let dealerValue = dealerUp.value
        guard dealerValue == deviation.dealerValue else { return false }

        let tc = Int(floor(trueCount))
        switch deviation.countCondition {
        case .trueCountAtLeast(let threshold):
            guard tc >= threshold else { return false }
        case .trueCountAtMost(let threshold):
            guard tc <= threshold else { return false }
        case .runningPositive:
            guard runningCount > 0 else { return false }
        case .runningNegative:
            guard runningCount < 0 else { return false }
        }

        return true
    }

    private func playHand(
        initialHand: Hand,
        dealerHand: Hand,
        bet: Double,
        splitDepth: Int = 0,
        bankrollStart: Double,
        realityIndex: Int,
        handIndex: Int
    ) -> Double {
        var hand = initialHand
        var wager = bet
        let dealerUp = dealerHand.cards.first ?? Card(rank: 10)

        // --- Insurance logic (original hand only, vs Ace up) ---
        let insuranceEligible = splitDepth == 0 && dealerUp.rank == 1
        let meetsInsuranceCount = trueCount >= 3
        let insuranceBet = insuranceBetAmount(for: wager, dealerUp: dealerUp, splitDepth: splitDepth)
        let insuranceTaken = insuranceBet > 0
        let insuranceDecision: String
        if insuranceEligible {
            if takeInsurance {
                insuranceDecision = insuranceTaken ? "taken" : (meetsInsuranceCount ? "skipped" : "below-threshold")
            } else {
                insuranceDecision = "disabled"
            }
        } else {
            insuranceDecision = "not-eligible"
        }

        var insuranceResult: String?
        var insuranceNet: Double?

        // Dealer peek for blackjack
        if dealerHand.isBlackjack {
            if insuranceTaken {
                let insurancePayout = insuranceBet * 2.0
                insuranceResult = "win"
                insuranceNet = insurancePayout
            }

            if hand.isBlackjack && !hand.fromSplit {
                // Push main bet; you just keep your stake and win insurance if any
                let finalProfit = insuranceNet ?? 0
                if debugEnabled && debugLog.count < 5000 {
                    let record = DebugRecord(
                        trueCount: trueCount,
                        playerCards: hand.cards.map { $0.rank },
                        dealerUp: dealerUp.rank,
                        dealerHole: dealerHand.cards.dropFirst().first?.rank ?? 0,
                        isSoft: hand.isSoft,
                        total: hand.bestValue,
                        action: "dealerBJ",
                        wager: wager,
                        insuranceBet: insuranceBet,
                        insuranceDecision: insuranceDecision,
                        insuranceResult: insuranceResult,
                        insuranceNet: insuranceNet,
                        bankrollStart: bankrollStart,
                        payout: finalProfit,
                        bankrollEnd: bankrollStart + finalProfit,
                        splitDepth: splitDepth,
                        result: HandResult.push.rawValue,
                        realityIndex: realityIndex,
                        handIndex: handIndex,
                        playerFinal: hand.bestValue,
                        dealerFinal: dealerHand.bestValue
                    )
                    debugLog.append(record)
                }
                return finalProfit
            } else {
                // Lose main bet
                let finalProfit = (insuranceNet ?? 0) - wager
                if debugEnabled && debugLog.count < 5000 {
                    let record = DebugRecord(
                        trueCount: trueCount,
                        playerCards: hand.cards.map { $0.rank },
                        dealerUp: dealerUp.rank,
                        dealerHole: dealerHand.cards.dropFirst().first?.rank ?? 0,
                        isSoft: hand.isSoft,
                        total: hand.bestValue,
                        action: "dealerBJ",
                        wager: wager,
                        insuranceBet: insuranceBet,
                        insuranceDecision: insuranceDecision,
                        insuranceResult: insuranceResult,
                        insuranceNet: insuranceNet,
                        bankrollStart: bankrollStart,
                        payout: finalProfit,
                        bankrollEnd: bankrollStart + finalProfit,
                        splitDepth: splitDepth,
                        result: HandResult.loss.rawValue,
                        realityIndex: realityIndex,
                        handIndex: handIndex,
                        playerFinal: hand.bestValue,
                        dealerFinal: dealerHand.bestValue
                    )
                    debugLog.append(record)
                }
                return finalProfit
            }
        }

        // No dealer blackjack; insurance (if taken) is lost
        let insuranceLoss = -insuranceBet
        if insuranceTaken {
            insuranceResult = "loss"
            insuranceNet = insuranceLoss
        }

        let firstAction = applyDeviations(base: basicStrategy(for: hand, dealerUp: dealerUp), hand: hand, dealerUp: dealerUp)

        var finalProfit: Double = 0
        var outcome: HandResult = .push
        var dealerFinalTotal: Int = dealerHand.bestValue
        var playerFinalTotal: Int = hand.bestValue
        var actions: [PlayerAction] = []

        switch firstAction {
        case .surrender:
            // Late surrender: dealer has already been checked for BJ, so just lose half plus any insurance loss.
            finalProfit = insuranceLoss - wager / 2.0
            outcome = .surrender
            dealerFinalTotal = dealerHand.bestValue
            playerFinalTotal = hand.bestValue
            actions.append(.surrender)

        case .split where splitDepth < 3 && hand.canSplit && (!hand.isSplitAce):
            let firstCard = hand.cards[0]
            let secondCard = hand.cards[1]

            var firstHand = Hand(cards: [firstCard], isSplitAce: firstCard.rank == 1, fromSplit: true)
            var secondHand = Hand(cards: [secondCard], isSplitAce: secondCard.rank == 1, fromSplit: true)

            firstHand.cards.append(drawCard())
            secondHand.cards.append(drawCard())

            if firstHand.isSplitAce {
                // One card to each Ace, no further hitting, settled independently.
                let win1 = settle(hand: firstHand, dealerHand: dealerHand, bet: wager, true)
                let win2 = settle(hand: secondHand, dealerHand: dealerHand, bet: wager, true)
                finalProfit = insuranceLoss + win1.profit + win2.profit
                dealerFinalTotal = win1.dealerTotal
                playerFinalTotal = firstHand.bestValue
                outcome = combinedResult(win1.result, win2.result)
            } else {
                let win1 = playHand(
                    initialHand: firstHand,
                    dealerHand: dealerHand,
                    bet: wager,
                    splitDepth: splitDepth + 1,
                    bankrollStart: bankrollStart,
                    realityIndex: realityIndex,
                    handIndex: handIndex
                )
                let bankrollAfterFirst = bankrollStart + win1
                let win2 = playHand(
                    initialHand: secondHand,
                    dealerHand: dealerHand,
                    bet: wager,
                    splitDepth: splitDepth + 1,
                    bankrollStart: bankrollAfterFirst,
                    realityIndex: realityIndex,
                    handIndex: handIndex
                )
                finalProfit = insuranceLoss + win1 + win2
                dealerFinalTotal = dealerHand.bestValue
                playerFinalTotal = hand.bestValue
                outcome = .push
            }

            actions.append(.split)

        case .double:
            if hand.cards.count == 2 {
                wager *= 2
                hand.cards.append(drawCard())
                let res = settle(hand: hand, dealerHand: dealerHand, bet: wager, true)
                finalProfit = insuranceLoss + res.profit
                dealerFinalTotal = res.dealerTotal
                playerFinalTotal = res.playerTotal
                outcome = res.result
                actions.append(.double)
            } else {
                let res = settle(hand: hand, dealerHand: dealerHand, bet: wager, false)
                finalProfit = insuranceLoss + res.profit
                dealerFinalTotal = res.dealerTotal
                playerFinalTotal = res.playerTotal
                outcome = res.result
                actions.append(.double)
            }

        default:
            var stood = false

            handLoop: while true {
                let baseAction = basicStrategy(for: hand, dealerUp: dealerUp)
                var currentAction = applyDeviations(base: baseAction, hand: hand, dealerUp: dealerUp)

                // Once an extra card has been taken, doubling is no longer available.
                if hand.cards.count > 2 && currentAction == .double {
                    currentAction = .hit
                }

                switch currentAction {
                case .hit:
                    hand.cards.append(drawCard())
                    actions.append(.hit)
                    if hand.isBusted {
                        stood = true
                        break handLoop
                    }

                case .stand:
                    stood = true
                    actions.append(.stand)
                    break handLoop

                default:
                    // Should not normally reach here (split/surrender handled earlier), but treat as standing.
                    stood = true
                    actions.append(currentAction)
                    break handLoop
                }
            }

            let res = settle(hand: hand, dealerHand: dealerHand, bet: wager, stood)
            finalProfit = insuranceLoss + res.profit
            dealerFinalTotal = res.dealerTotal
            playerFinalTotal = res.playerTotal
            outcome = res.result
        }

        if outcome == .push {
            outcome = resultFromProfit(finalProfit)
        }

        // Debug record of decision & outcome
        if debugEnabled && debugLog.count < 5000 {
            let record = DebugRecord(
                trueCount: trueCount,
                playerCards: hand.cards.map { $0.rank },
                dealerUp: dealerUp.rank,
                dealerHole: dealerHand.cards.dropFirst().first?.rank ?? 0,
                isSoft: hand.isSoft,
                total: hand.bestValue,
                action: actions.map(actionName).joined(separator: "-"),
                wager: wager,
                insuranceBet: insuranceBet,
                insuranceDecision: insuranceDecision,
                insuranceResult: insuranceResult,
                insuranceNet: insuranceNet,
                bankrollStart: bankrollStart,
                payout: finalProfit,
                bankrollEnd: bankrollStart + finalProfit,
                splitDepth: splitDepth,
                result: outcome.rawValue,
                realityIndex: realityIndex,
                handIndex: handIndex,
                playerFinal: playerFinalTotal,
                dealerFinal: dealerFinalTotal
            )
            debugLog.append(record)
        }

        return finalProfit
    }

    private func combinedResult(_ r1: HandResult, _ r2: HandResult) -> HandResult {
        if r1 == .loss && r2 == .loss { return .loss }
        if r1 == .win && r2 == .win { return .win }
        if r1 == .blackjack && r2 == .blackjack { return .blackjack }
        if r1 == .push && r2 == .push { return .push }
        if [r1, r2].contains(.win) || [r1, r2].contains(.blackjack) { return .win }
        if [r1, r2].contains(.push) { return .push }
        return .loss
    }

    private func resultFromProfit(_ profit: Double) -> HandResult {
        if profit > 0 { return .win }
        if profit < 0 { return .loss }
        return .push
    }

    private func settle(hand: Hand, dealerHand: Hand, bet: Double, _ stood: Bool) -> (profit: Double, dealerTotal: Int, playerTotal: Int, result: HandResult) {
        if hand.isBusted {
            return (-bet, dealerHand.bestValue, hand.bestValue, .bust)
        }

        if hand.cards.count == 2 && hand.isBlackjack {
            // no extra handling here; fromSplit prevents BJ bonus
        }

        var dealerHand = dealerHand

        if dealerHand.isBlackjack {
            if hand.isBlackjack && !hand.fromSplit {
                return (0, 21, hand.bestValue, .push)
            }
            return (-bet, 21, hand.bestValue, .loss)
        }

        // blackjackPayout is net profit multiple (1.5 for 3:2)
        if hand.isBlackjack && !hand.fromSplit {
            return (bet * rules.blackjackPayout, dealerHand.bestValue, hand.bestValue, .blackjack)
        }

        dealerHand = dealerPlay(dealerHand)

        if dealerHand.isBusted {
            return (bet, dealerHand.bestValue, hand.bestValue, .win)
        }

        let playerTotal = hand.bestValue
        let dealerTotal = dealerHand.bestValue

        if playerTotal > dealerTotal { return (bet, dealerTotal, playerTotal, .win) }
        if playerTotal < dealerTotal { return (-bet, dealerTotal, playerTotal, .loss) }
        return (0, dealerTotal, playerTotal, .push)
    }

    /// Multi-reality simulation using hours & hands/hour
    /// Stops once bankroll hits 0 and never goes negative.
    func simulate(
        input: SimulationInput,
        progress: @escaping (Int) -> Void,    // simulations completed
        shouldCancel: @escaping () -> Bool
    ) async -> SimulationResult? {
        let realities = max(input.numRealities, 1)
        let handsPerReality = max(Int(input.hoursToSimulate * input.handsPerHour), 1)
        let handsPerHour = input.handsPerHour
        let startingBankroll = input.bankroll

        var allProfits: [Double] = []
        var allBets: [Double] = []
        var finalProfits: [Double] = []
        var ruinedFlags: [Bool] = []
        var endingBankrolls: [Double] = []
        var bustHandIndex: [Int?] = Array(repeating: nil, count: realities)

        for reality in 0..<realities {
            if shouldCancel() { return nil }

            var cumProfit: Double = 0
            var ruined = false

            for handIndex in 0..<handsPerReality {
                if shouldCancel() { return nil }

                if handIndex % 500 == 0 {
                    await Task.yield()
                }

                let bankrollNow = startingBankroll + cumProfit

                // If there's no money left, stop this reality.
                if bankrollNow <= 0 {
                    ruined = true
                    if bustHandIndex[reality] == nil {
                        bustHandIndex[reality] = handIndex
                    }
                    break
                }

                prepareShoeForNewHand()

                // Never bet more than you have left.
                let baseBet = betting.bet(for: trueCount)
                let wager = min(baseBet, bankrollNow)

                // Safety: if for some reason the wager is 0 or less, treat as bust and stop.
                if wager <= 0 {
                    ruined = true
                    if bustHandIndex[reality] == nil {
                        bustHandIndex[reality] = handIndex
                    }
                    break
                }

                allBets.append(wager)

                let playerHand = Hand(cards: [drawCard(), drawCard()])
                let dealerUp = drawCard()
                let dealerHole = drawCard()
                let dealerHand = Hand(cards: [dealerUp, dealerHole])

                let profit = playHand(
                    initialHand: playerHand,
                    dealerHand: dealerHand,
                    bet: wager,
                    splitDepth: 0,
                    bankrollStart: bankrollNow,
                    realityIndex: reality,
                    handIndex: handIndex
                )
                cumProfit += profit
                allProfits.append(profit)

                let bankrollAfter = startingBankroll + cumProfit
                if bankrollAfter <= 0 {
                    ruined = true
                    if bustHandIndex[reality] == nil {
                        bustHandIndex[reality] = handIndex + 1
                    }
                    break
                }
            }

            finalProfits.append(cumProfit)
            ruinedFlags.append(ruined)

            // Clamp to 0 so worst case is never negative
            endingBankrolls.append(max(startingBankroll + cumProfit, 0))

            // progress in simulations, not hands
            await MainActor.run {
                progress(reality + 1)
            }
        }

        let totalHands = max(allProfits.count, 1)
        let avgProfitPerHand = allProfits.reduce(0, +) / Double(totalHands)

        let variancePerHand = allProfits.reduce(0.0) {
            $0 + pow($1 - avgProfitPerHand, 2)
        } / Double(max(totalHands - 1, 1))

        let sdPerHand = sqrt(variancePerHand)

        let hourlyEv = avgProfitPerHand * handsPerHour
        let hourlySd = sdPerHand * sqrt(handsPerHour)

        let sortedBets = allBets.sorted()
        let medianBet: Double
        if sortedBets.isEmpty {
            medianBet = 0
        } else if sortedBets.count % 2 == 0 {
            let mid = sortedBets.count / 2
            medianBet = (sortedBets[mid] + sortedBets[mid - 1]) / 2
        } else {
            medianBet = sortedBets[sortedBets.count / 2]
        }

        let avgBet = allBets.reduce(0, +) / Double(max(allBets.count, 1))

        let ruinedCount = ruinedFlags.filter { $0 }.count
        let riskOfRuin = Double(ruinedCount) / Double(realities)

        // Positive outcomes = ending bankroll > starting bankroll
        let positiveCount = endingBankrolls.filter { $0 > startingBankroll }.count
        let percentPositive = Double(positiveCount) / Double(realities)

        let bestEnding = endingBankrolls.max() ?? startingBankroll
        let worstEnding = endingBankrolls.min() ?? startingBankroll

        // Hours to bust for the worst outcome (if that reality actually busted)
        var hoursToBustWorst: Double? = nil
        if let worstIndex = endingBankrolls.enumerated().min(by: { $0.element < $1.element })?.offset,
           let bustIndex = bustHandIndex[worstIndex] {
            hoursToBustWorst = Double(bustIndex) / handsPerHour
        }

        return SimulationResult(
            expectedValuePerHour: hourlyEv,
            standardDeviationPerHour: hourlySd,
            riskOfRuin: riskOfRuin,
            averageBet: avgBet,
            medianBet: medianBet,
            percentPositiveOutcomes: percentPositive,
            bestEndingBankroll: bestEnding,
            worstEndingBankroll: worstEnding,
            hoursToBustWorst: hoursToBustWorst,
            totalEv: avgProfitPerHand,
            totalSd: sdPerHand
        )
    }
}

// MARK: - Persistence

struct SavedRun: Identifiable, Codable {
    var id: UUID = .init()
    var timestamp: Date
    var input: SimulationInput
    var result: SimulationResult
    var name: String?

    var betTitle: String {
        String(
            format: "Min $%.0f | Max $%.0f",
            input.betting.minBet,
            maxBet
        )
    }

    var maxBet: Double {
        max(input.betting.spreads.map { $0.bet }.max() ?? input.betting.minBet, input.betting.minBet)
    }

    var displayTitle: String {
        String(
            format: "Min $%.0f | Max $%.0f | EV/hr $%.2f | RoR %.1f%%",
            input.betting.minBet,
            maxBet,
            result.expectedValuePerHour,
            result.riskOfRuin * 100
        )
    }
}

struct SavedRunDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let run: SavedRun
    var existingSavedNames: [String] = []
    var onSaveRun: ((SavedRun, String) -> Void)?

    @State private var showingChart: Bool = false
    @State private var showingSaveSheet: Bool = false
    @State private var saveName: String = ""
    @State private var duplicateNameAlert: Bool = false

    private var deviationsUsed: [DeviationRule] {
        let deviations = run.input.deviations
        return deviations.isEmpty ? DeviationRule.defaultRules : deviations
    }

    private var defaultCategory: DeviationCategory {
        run.input.rules.dealerHitsSoft17 ? .hit17 : .stand17
    }

    private var sortedSpreads: [BetRampEntry] {
        run.input.betting.spreads.sorted { $0.trueCount < $1.trueCount }
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Results")) {
                    Text(String(format: "EV/hour: $%.2f", run.result.expectedValuePerHour))
                    Text(String(format: "SD/hour: $%.2f", run.result.standardDeviationPerHour))
                    Text(String(format: "Risk of ruin: %.2f%%", run.result.riskOfRuin * 100))
                }

                Section(header: Text("Rules")) {
                    Text("Decks: \(run.input.rules.decks)")
                    Text(run.input.rules.dealerHitsSoft17 ? "Dealer hits soft 17" : "Dealer stands on soft 17")
                    Text(run.input.rules.doubleAfterSplit ? "Double after split allowed" : "No double after split")
                    Text(run.input.rules.surrenderAllowed ? "Surrender allowed" : "Surrender not allowed")
                    Text(String(format: "Blackjack payout: %.1fx", run.input.rules.blackjackPayout))
                    Text(String(format: "Penetration: %.0f%%", run.input.rules.penetration * 100))
                }

                Section(header: Text("Bet Spread")) {
                    Text(String(format: "Min bet: $%.0f", run.input.betting.minBet))
                    ForEach(sortedSpreads) { spread in
                        HStack {
                            Text("TC \(spread.trueCount) →")
                            Spacer()
                            Text(String(format: "$%.0f", spread.bet))
                        }
                    }
                }

                Section(header: Text("Simulation Settings")) {
                    Text(String(format: "Hours per simulation: %.1f", run.input.hoursToSimulate))
                    Text(String(format: "Hands per hour: %.0f", run.input.handsPerHour))
                    Text("Simulations: \(run.input.numRealities)")
                    Text(String(format: "Bankroll: $%.0f", run.input.bankroll))
                    Text(run.input.takeInsurance ? "Insurance bets enabled (TC ≥ +3)" : "Insurance bets disabled")
                }

                Section(header: Text("Deviations Used")) {
                    if deviationsUsed.isEmpty {
                        Text("No deviations were used in this run.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(deviationsUsed.sorted(by: DeviationRule.sorter)) { deviation in
                            HStack {
                                Image(systemName: deviation.isEnabled ? "checkmark.circle" : "slash.circle")
                                    .foregroundColor(deviation.isEnabled ? .green : .secondary)
                                Text(deviation.description)
                            }
                        }
                    }

                    Button(action: { showingChart = true }) {
                        Text("Visualize Deviations Used This Run")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(deviationsUsed.isEmpty)
                }
            }
            .navigationTitle(run.name ?? run.betTitle)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                    }
                }

                if run.name == nil {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Save This Run") {
                            saveName = run.name ?? run.betTitle
                            showingSaveSheet = true
                        }
                        .disabled(onSaveRun == nil)
                    }
                }
            }
            .sheet(isPresented: $showingChart) {
                DeviationChartView(
                    deviations: deviationsUsed,
                    rules: run.input.rules,
                    selectedCategory: defaultCategory
                )
            }
            .sheet(isPresented: $showingSaveSheet) {
                NavigationView {
                    Form {
                        Section(header: Text("Name")) {
                            TextField("Run name", text: $saveName)
                        }
                    }
                    .navigationTitle("Save Run")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingSaveSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                attemptSaveRun()
                            }
                            .disabled(saveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .alert("Duplicate Name", isPresented: $duplicateNameAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Another saved run already uses that name. Please choose a unique name.")
            }
        }
    }

    private func attemptSaveRun() {
        let trimmed = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if existingSavedNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            duplicateNameAlert = true
            return
        }

        onSaveRun?(run, trimmed)
        showingSaveSheet = false
    }
}

// MARK: - UI

struct ContentView: View {
    @State private var decks: Int = 6
    @State private var dealerHitsSoft17: Bool = true
    @State private var dasAllowed: Bool = true
    @State private var surrenderAllowed: Bool = true
    @State private var blackjackPayout: Double = 1.5
    @State private var penetration: Double = 0.75
    @State private var takeInsurance: Bool = true

    @State private var minBet: Double = 10
    @State private var spreads: [BetRampEntry] = [
        BetRampEntry(trueCount: 1, bet: 20),
        BetRampEntry(trueCount: 2, bet: 40),
        BetRampEntry(trueCount: 3, bet: 80),
        BetRampEntry(trueCount: 4, bet: 100)
    ]

    @State private var hoursToSimulate: Double = 5
    @State private var handsPerHour: Double = 100
    @State private var numRealities: Int = 500
    @State private var bankroll: Double = 10000
    @State private var deviations: [DeviationRule] = DeviationRule.defaultRules
    @State private var debugEnabled: Bool = false

    @State private var result: SimulationResult?
    @State private var isSimulating: Bool = false
    @State private var completedSimulations: Int = 0
    @State private var startTime: Date?
    @State private var simulationTask: Task<Void, Never>?
    @State private var userCancelled: Bool = false

    @AppStorage("savedRuns") private var recentRunsData: Data = Data()
    @AppStorage("userSavedRuns") private var savedNamedRunsData: Data = Data()
    @State private var recentRuns: [SavedRun] = []
    @State private var savedNamedRuns: [SavedRun] = []
    @State private var selectedSavedRun: SavedRun?
    @State private var runBeingRenamed: SavedRun?
    @State private var renameText: String = ""
    @State private var duplicateRenameAlert: Bool = false

    @State private var debugRecords: [DebugRecord] = []
    @State private var debugCSV: String = ""
    @State private var copyStatus: String?

    private var currentRuleSet: GameRules {
        GameRules(
            decks: decks,
            dealerHitsSoft17: dealerHitsSoft17,
            doubleAfterSplit: dasAllowed,
            surrenderAllowed: surrenderAllowed,
            blackjackPayout: blackjackPayout,
            penetration: penetration
        )
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    rulesSection
                    bettingSection
                    deviationSection
                    simSection
                    progressSection
                    resultSection
                    recentRunsSection
                    savedRunsSection
                    debugSection
                }
                .padding()
            }
            .navigationTitle("Blackjack EV Lab")
            .onAppear(perform: loadSavedRuns)
            .sheet(item: $selectedSavedRun) { run in
                SavedRunDetailView(
                    run: run,
                    existingSavedNames: savedNamedRuns.compactMap { $0.name },
                    onSaveRun: { run, name in
                        saveNamedRun(run, with: name)
                    }
                )
            }
            .sheet(item: $runBeingRenamed) { _ in
                NavigationView {
                    Form {
                        Section(header: Text("Name")) {
                            TextField("Run name", text: $renameText)
                        }
                    }
                    .navigationTitle("Rename Run")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { runBeingRenamed = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { applyRename() }
                                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .alert("Duplicate Name", isPresented: $duplicateRenameAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Another saved run already uses that name. Please choose a unique name.")
            }
        }
    }

    // MARK: - Sections

    private var rulesSection: some View {
        Section(header: Text("Rules").font(.headline)) {
            Stepper("Decks: \(decks)", value: $decks, in: 1...8)
            Toggle("Dealer hits soft 17", isOn: $dealerHitsSoft17)
            Toggle("Double after split", isOn: $dasAllowed)
            Toggle("Surrender allowed", isOn: $surrenderAllowed)
            HStack {
                Text("Penetration")
                Slider(value: $penetration, in: 0.5...0.95)
                Text(String(format: "%.0f%%", penetration * 100))
            }
            HStack {
                Text("Blackjack payout")
                TextField("Payout", value: $blackjackPayout, format: .number)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var bettingSection: some View {
        Section(header: Text("Bet Spreads").font(.headline)) {
            HStack {
                Text("Min bet")
                TextField("Min", value: $minBet, format: .number)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
            }

            ForEach(spreads.indices, id: \.self) { index in
                let binding = $spreads[index]
                VStack(alignment: .leading) {
                    HStack {
                        Stepper("True count: \(binding.trueCount.wrappedValue)",
                                value: binding.trueCount,
                                in: 1...12)
                        Spacer()
                        TextField("Bet", value: binding.bet, format: .number)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        Button(role: .destructive) {
                            removeSpread(at: IndexSet(integer: index))
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(spreads.count <= 1)
                    }
                    Text("Bet when TC ≥ \(binding.trueCount.wrappedValue)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Button(action: addSpread) {
                Label("Add spread level", systemImage: "plus")
            }
            .disabled(spreads.count >= 12)

            Text("Define wager amounts up to a TC of 12; the highest matching level will be used.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var deviationSection: some View {
        Section(header: Text("Deviations").font(.headline)) {
            NavigationLink {
                DeviationManagerView(deviations: $deviations, currentRules: currentRuleSet)
            } label: {
                VStack(alignment: .leading) {
                    Text("Manage deviations")
                    Text("Tap to add, enable, or disable deviations for Hit 17, Stand 17, or all games.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Toggle("Take insurance bets", isOn: $takeInsurance)
            Text("Insurance is taken when the true count is +3 or higher against an Ace upcard.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var simSection: some View {
        Section(header: Text("Simulation").font(.headline)) {
            HStack {
                Text("Hours per simulation")
                TextField("5", value: $hoursToSimulate, format: .number)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Hands per hour")
                TextField("100", value: $handsPerHour, format: .number)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Number of simulations")
                TextField("500", value: $numRealities, format: .number)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Bankroll")
                TextField("10000", value: $bankroll, format: .number)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Enable debug logging", isOn: $debugEnabled)

            HStack {
                Button(action: runSimulation) {
                    HStack {
                        if isSimulating {
                            ProgressView()
                        }
                        Text("Run simulation")
                    }
                }
                .disabled(isSimulating)

                if isSimulating {
                    Button("Cancel", role: .destructive, action: cancelSimulation)
                }
            }
        }
    }

    private var progressSection: some View {
        Group {
            if isSimulating {
                Section(header: Text("Progress").font(.headline)) {
                    ProgressView(
                        value: Double(completedSimulations),
                        total: Double(max(numRealities, 1))
                    )
                    Text(
                        String(
                            format: "Simulations: %d / %d (%.1f%%)",
                            completedSimulations,
                            numRealities,
                            (Double(completedSimulations) / Double(max(numRealities, 1))) * 100
                        )
                    )
                    if let startTime {
                        let elapsed = Date().timeIntervalSince(startTime)
                        Text(String(format: "Elapsed: %.1f seconds", elapsed))
                    }
                    let handsPerSim = max(Int(hoursToSimulate * handsPerHour), 1)
                    Text("Hands per simulation: \(handsPerSim)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var resultSection: some View {
        Group {
            if let result {
                Section(header: Text("Results").font(.headline)) {
                    Text(String(format: "EV/hour: $%.2f", result.expectedValuePerHour))
                    Text(String(format: "SD/hour: $%.2f", result.standardDeviationPerHour))
                    Text(String(format: "Risk of ruin: %.2f%%", result.riskOfRuin * 100))
                    Text(String(format: "Average bet: $%.2f", result.averageBet))
                    Text(String(format: "Median bet: $%.2f", result.medianBet))
                    Text(String(format: "Positive outcomes: %.1f%%", result.percentPositiveOutcomes * 100))
                    Text(String(format: "Best ending bankroll: $%.2f", result.bestEndingBankroll))
                    Text(String(format: "Worst ending bankroll: $%.2f", result.worstEndingBankroll))
                    if let h = result.hoursToBustWorst {
                        Text(String(format: "Hours to bust (worst): %.2f", h))
                    } else {
                        Text("Hours to bust (worst): N/A")
                    }
                    Text(String(format: "EV/hand: $%.4f", result.totalEv))
                    Text(String(format: "SD/hand: $%.4f", result.totalSd))
                }
            }
        }
    }

    private var recentRunsSection: some View {
        Section(header: Text("Recent Runs").font(.headline)) {
            if recentRuns.isEmpty {
                Text("No recent runs yet. Completed simulations are stored here for reuse.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(recentRuns.indices, id: \.self) { index in
                    let run = recentRuns[index]
                    VStack(alignment: .leading, spacing: 4) {
                        Text(run.displayTitle)
                            .font(.subheadline)
                        Text(
                            String(
                                format: "Sims %d | Hours/sim %.1f | Bankroll $%.0f | Insurance %@",
                                run.input.numRealities,
                                run.input.hoursToSimulate,
                                run.input.bankroll,
                                run.input.takeInsurance ? "On" : "Off"
                            )
                        )
                        .font(.caption)
                        HStack {
                            Button("Load", action: { load(run: run) })
                            Spacer()
                            Button(role: .destructive) {
                                removeRecentRun(at: IndexSet(integer: index))
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    private var savedRunsSection: some View {
        Section(header: Text("Saved Runs").font(.headline)) {
            if savedNamedRuns.isEmpty {
                Text("No saved runs yet. Load a recent run and tap Save This Run to keep it here.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(savedNamedRuns.indices, id: \.self) { index in
                    let run = savedNamedRuns[index]
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(run.name ?? "Saved Run")
                                .font(.subheadline)
                            Spacer()
                            Button(action: { beginRenaming(run) }) {
                                Image(systemName: "pencil")
                            }
                        }
                        Text(run.displayTitle)
                            .font(.caption)
                        HStack {
                            Button("Load", action: { load(run: run) })
                            Spacer()
                            Button(role: .destructive) {
                                removeSavedRun(at: IndexSet(integer: index))
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    private var debugSection: some View {
        Section(header: Text("Debug").font(.headline)) {
            if debugEnabled {
                Text("Debug logging is ON. Run a simulation to capture decisions (up to 5000 hands).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Enable debug logging above to record per-hand decisions.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !debugRecords.isEmpty {
                Text("Logged \(debugRecords.count) decisions.")
                    .font(.subheadline)

                ScrollView(.horizontal) {
                    ScrollView {
                        Text(debugCSV)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                HStack {
                    Button("Copy CSV") {
                        copyDebugCSV()
                    }
                    .disabled(debugCSV.isEmpty)

                    if let copyStatus {
                        Text(copyStatus)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Text("Select and copy the text above to paste into a CSV file or spreadsheet.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Saved runs

    private func loadSavedRuns() {
        recentRuns = decodeRuns(from: recentRunsData)
        savedNamedRuns = decodeRuns(from: savedNamedRunsData)
        trimRecentRuns()
        persistRecentRuns()
    }

    private func decodeRuns(from data: Data) -> [SavedRun] {
        guard !data.isEmpty,
              let decoded = try? JSONDecoder().decode([SavedRun].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persistRecentRuns() {
        if let data = try? JSONEncoder().encode(recentRuns) {
            recentRunsData = data
        }
    }

    private func persistSavedNamedRuns() {
        if let data = try? JSONEncoder().encode(savedNamedRuns) {
            savedNamedRunsData = data
        }
    }

    private func load(run: SavedRun) {
        selectedSavedRun = run
    }

    private func removeRecentRun(at offsets: IndexSet) {
        recentRuns.remove(atOffsets: offsets)
        persistRecentRuns()
    }

    private func removeSavedRun(at offsets: IndexSet) {
        savedNamedRuns.remove(atOffsets: offsets)
        persistSavedNamedRuns()
    }

    private func trimRecentRuns() {
        recentRuns.sort { $0.timestamp > $1.timestamp }
        if recentRuns.count > 5 {
            recentRuns = Array(recentRuns.prefix(5))
        }
    }

    private func nameIsDuplicate(_ name: String, excluding runID: UUID? = nil) -> Bool {
        savedNamedRuns.contains { saved in
            guard saved.id != runID else { return false }
            return (saved.name ?? "").caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func saveNamedRun(_ run: SavedRun, with name: String) {
        guard !nameIsDuplicate(name) else {
            duplicateRenameAlert = true
            return
        }

        var namedRun = run
        namedRun.name = name

        if let existingIndex = savedNamedRuns.firstIndex(where: { $0.id == run.id }) {
            savedNamedRuns[existingIndex] = namedRun
        } else {
            savedNamedRuns.append(namedRun)
        }

        persistSavedNamedRuns()
    }

    private func beginRenaming(_ run: SavedRun) {
        runBeingRenamed = run
        renameText = run.name ?? run.displayTitle
    }

    private func applyRename() {
        guard let runToRename = runBeingRenamed else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            runBeingRenamed = nil
            return
        }

        if nameIsDuplicate(trimmed, excluding: runToRename.id) {
            duplicateRenameAlert = true
            return
        }

        if let index = savedNamedRuns.firstIndex(where: { $0.id == runToRename.id }) {
            savedNamedRuns[index].name = trimmed
            persistSavedNamedRuns()
        }

        runBeingRenamed = nil
    }

    private func addSpread() {
        guard spreads.count < 12 else { return }
        let nextTC = min((spreads.map { $0.trueCount }.max() ?? 0) + 1, 12)
        spreads.append(
            BetRampEntry(
                trueCount: nextTC,
                bet: max(minBet, spreads.last?.bet ?? minBet)
            )
        )
    }

    private func removeSpread(at offsets: IndexSet) {
        spreads.remove(atOffsets: offsets)
    }

    private func copyDebugCSV() {
        guard !debugCSV.isEmpty else { return }
#if canImport(UIKit)
        UIPasteboard.general.string = debugCSV
        copyStatus = "Copied to clipboard"
#else
        copyStatus = "Copy not supported on this platform"
#endif

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            copyStatus = nil
        }
    }

    // MARK: - Simulation controls

    private func cancelSimulation() {
        userCancelled = true
        simulationTask?.cancel()
        isSimulating = false
    }

    private func makeCSV(from records: [DebugRecord]) -> String {
        var lines: [String] = [
            "reality,handIndex,splitDepth,trueCount,playerCards,dealerUp,dealerHole,total,isSoft,action,wager,insuranceBet,insuranceDecision,insuranceResult,insuranceNet,bankrollStart,payout,bankrollEnd,result,playerFinal,dealerFinal"
        ]
        for r in records {
            let cards = r.playerCards.map(String.init).joined(separator: "-")
            let insuranceResult = r.insuranceResult ?? "null"
            let insuranceNet = r.insuranceNet.map { String(format: "%.2f", $0) } ?? "null"
            let entries: [String] = [
                "\(r.realityIndex)",
                "\(r.handIndex)",
                "\(r.splitDepth)",
                String(format: "%.2f", r.trueCount),
                cards,
                "\(r.dealerUp)",
                "\(r.dealerHole)",
                "\(r.total)",
                r.isSoft ? "1" : "0",
                r.action,
                String(format: "%.2f", r.wager),
                String(format: "%.2f", r.insuranceBet),
                r.insuranceDecision,
                insuranceResult,
                insuranceNet,
                String(format: "%.2f", r.bankrollStart),
                String(format: "%.2f", r.payout),
                String(format: "%.2f", r.bankrollEnd),
                r.result,
                "\(r.playerFinal)",
                "\(r.dealerFinal)"
            ]

            lines.append(entries.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private func runSimulation() {
        guard !isSimulating else { return }

        isSimulating = true
        userCancelled = false
        completedSimulations = 0
        startTime = Date()
        result = nil
        debugRecords = []
        debugCSV = ""
        copyStatus = nil

        let input = SimulationInput(
            rules: currentRuleSet,
            betting: BettingModel(
                minBet: minBet,
                spreads: spreads
            ),
            hoursToSimulate: max(hoursToSimulate, 0.01),
            handsPerHour: max(handsPerHour, 1),
            numRealities: max(numRealities, 1),
            bankroll: bankroll,
            takeInsurance: takeInsurance,
            useBasicDeviations: true,
            deviations: deviations
        )

        simulationTask = Task(priority: .userInitiated) {
            let simulator = BlackjackSimulator(input: input, debugEnabled: debugEnabled)

            let outcome = await simulator.simulate(
                input: input,
                progress: { simsDone in
                    self.completedSimulations = simsDone
                },
                shouldCancel: {
                    Task.isCancelled || self.userCancelled
                }
            )

            await MainActor.run {
                withAnimation {
                    self.isSimulating = false
                    if let outcome {
                        self.result = outcome
                        let saved = SavedRun(timestamp: Date(), input: input, result: outcome)
                        self.recentRuns.append(saved)
                        self.trimRecentRuns()
                        self.persistRecentRuns()

                        if self.debugEnabled {
                            self.debugRecords = simulator.debugLog
                            self.debugCSV = makeCSV(from: simulator.debugLog)
                        }
                    }
                }
            }
        }
    }
}

struct PlaceholderFeatureView: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Coming soon. Stay tuned!")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct StrategyQuizResult {
    let incorrectCount: Int
    let includedSections: [StrategyChartSectionType]
    let sectionStatus: [StrategyChartSectionType: Bool]

    var isPerfect: Bool { incorrectCount == 0 }

    var includesAllSections: Bool {
        Set(includedSections) == Set(StrategyChartSectionType.allCases)
    }
}

private struct QuizCellFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct StrategyQuizView: View {
    let rules: GameRules

    @AppStorage("strategyQuizHardCompletions") private var hardCompletions: Int = 0
    @AppStorage("strategyQuizSoftCompletions") private var softCompletions: Int = 0
    @AppStorage("strategyQuizPairCompletions") private var pairCompletions: Int = 0
    @AppStorage("strategyQuizSurrenderCompletions") private var surrenderCompletions: Int = 0
    @AppStorage("strategyQuizFullCompletions") private var fullChartCompletions: Int = 0

    @State private var includeHard: Bool = true
    @State private var includeSoft: Bool = true
    @State private var includePairs: Bool = true
    @State private var includeSurrender: Bool = true

    @State private var stage: Stage = .intro
    @State private var sections: [StrategyChartSectionData] = []
    @State private var selections: [UUID: PlayerAction?] = [:]
    @State private var selectedAction: PlayerAction? = .hit
    @State private var result: StrategyQuizResult?
    @State private var showResultAlert: Bool = false
    @State private var quizID = UUID()

    private let dealerValues = Array(2...11)

    private enum Stage {
        case intro, quiz
    }

    var body: some View {
        Group {
            switch stage {
            case .intro:
                introView
            case .quiz:
                quizBoard
            }
        }
        .navigationTitle("Strategy Quiz")
        .toolbar {
            if stage == .quiz {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Submit", action: submitQuiz)
                        .fontWeight(.semibold)
                }
            }
        }
        .alert(resultAlertTitle, isPresented: $showResultAlert, actions: alertActions, message: { Text(resultAlertMessage) })
        .onChange(of: stage) { newValue in
            if newValue == .quiz {
                OrientationManager.forceLandscape()
            } else {
                OrientationManager.restorePortrait()
            }
        }
        .onDisappear {
            OrientationManager.restorePortrait()
        }
    }

    private var introView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Build the basic strategy chart from scratch.")
                        .font(.title3.weight(.semibold))
                    Text("Pick which parts of the chart you want to practice, then recreate the actions by tapping cells. You can drag to paint multiple cells at once.")
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose sections to include:")
                        .font(.headline)
                    Toggle("Hard Totals", isOn: $includeHard)
                    Toggle("Soft Totals", isOn: $includeSoft)
                    Toggle("Pair Splitting", isOn: $includePairs)
                    Toggle("Surrender", isOn: $includeSurrender)
                }
                .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Completion stats")
                        .font(.headline)
                    statRow(title: "Hard", value: hardCompletions)
                    statRow(title: "Soft", value: softCompletions)
                    statRow(title: "Pairs", value: pairCompletions)
                    statRow(title: "Surrender", value: surrenderCompletions)
                    statRow(title: "Full chart", value: fullChartCompletions)
                }

                HStack {
                    Spacer()
                    Button(action: startQuiz) {
                        Text("Start")
                            .font(.headline)
                            .frame(maxWidth: 220)
                            .padding()
                            .background(includeSomething ? Color.accentColor : Color.secondary.opacity(0.3))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(!includeSomething)
                    Spacer()
                }
            }
            .padding()
        }
    }

    private var quizBoard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose an action from the legend and tap or drag across cells to paint that action onto the chart.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            actionLegend

            dealerHeaderRow

            StrategyQuizGrid(
                sections: sections,
                dealerValues: dealerValues,
                selections: $selections,
                selectedAction: $selectedAction
            )
            .id(quizID)
        }
        .padding(.bottom)
    }

    private var includeSomething: Bool {
        includeHard || includeSoft || includePairs || includeSurrender
    }

    private var actionLegend: some View {
        let actions: [(PlayerAction?, String)] = [
            (.hit, "Hit"),
            (.double, "Double"),
            (.stand, "Stand"),
            (.split, "Split"),
            (.surrender, "Surrender"),
            (nil, "Blank")
        ]

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(actions, id: \.0) { action, label in
                    Button {
                        selectedAction = action
                    } label: {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(legendColor(for: action))
                                .frame(width: 28, height: 20)
                                .overlay(
                                    Text(actionLabel(for: action))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.primary)
                                )
                            Text(label)
                                .font(.subheadline)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(selectedAction == action ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selectedAction == action ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private var dealerHeaderRow: some View {
        LazyVGrid(columns: quizColumns, spacing: 6) {
            Text("")
            ForEach(dealerValues, id: \.self) { value in
                Text(value == 11 ? "A" : "\(value)")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal)
    }

    private func statRow(title: String, value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)")
                .foregroundColor(.secondary)
        }
    }

    private var quizColumns: [GridItem] {
        [GridItem(.fixed(90))] + Array(repeating: GridItem(.flexible(minimum: 30)), count: dealerValues.count)
    }

    private func legendColor(for action: PlayerAction?) -> Color {
        guard let action else { return Color.secondary.opacity(0.15) }
        return chartActionColor(action).opacity(0.35)
    }

    private func actionLabel(for action: PlayerAction?) -> String {
        guard let action else { return "" }
        switch action {
        case .hit: return "H"
        case .double: return "D"
        case .stand: return "S"
        case .split: return "P"
        case .surrender: return "R"
        }
    }

    private func startQuiz() {
        guard includeSomething else { return }

        let builder = BasicStrategyChartBuilder(rules: rules)
        sections = builder.sections(
            includeHard: includeHard,
            includeSoft: includeSoft,
            includePairs: includePairs,
            includeSurrender: includeSurrender
        )
        resetSelections()
        stage = .quiz
        result = nil
        quizID = UUID()
    }

    private func resetSelections() {
        var newSelections: [UUID: PlayerAction?] = [:]
        for section in sections {
            for row in section.rows {
                for cell in row.cells {
                    newSelections[cell.id] = nil
                }
            }
        }
        selections = newSelections
    }

    private func submitQuiz() {
        let evaluation = evaluateSelections()
        result = evaluation
        if evaluation.isPerfect {
            recordSuccess(for: evaluation)
        }
        showResultAlert = true
    }

    private func evaluateSelections() -> StrategyQuizResult {
        var incorrect = 0
        var sectionStatus: [StrategyChartSectionType: Bool] = [:]

        for section in sections {
            var allCorrect = true
            for row in section.rows {
                for cell in row.cells {
                    let guess = selections[cell.id] ?? nil
                    if guess != cell.baseAction {
                        incorrect += 1
                        allCorrect = false
                    }
                }
            }
            sectionStatus[section.type] = allCorrect
        }

        return StrategyQuizResult(
            incorrectCount: incorrect,
            includedSections: sections.map { $0.type },
            sectionStatus: sectionStatus
        )
    }

    private func recordSuccess(for result: StrategyQuizResult) {
        for section in result.includedSections {
            guard result.sectionStatus[section] == true else { continue }
            switch section {
            case .hardTotals: hardCompletions += 1
            case .softTotals: softCompletions += 1
            case .pairSplitting: pairCompletions += 1
            case .surrender: surrenderCompletions += 1
            }
        }

        if result.includesAllSections && result.isPerfect {
            fullChartCompletions += 1
        }
    }

    private var resultAlertTitle: String {
        guard let result else { return "" }
        return result.isPerfect ? "Perfect!" : "Keep Going"
    }

    private var resultAlertMessage: String {
        guard let result else { return "" }
        if result.isPerfect {
            return "Everything matched the basic strategy chart."
        }
        return "You have \(result.incorrectCount) cell(s) incorrect. Adjust the chart and try again."
    }

    @ViewBuilder
    private func alertActions() -> some View {
        if let result {
            if result.isPerfect {
                Button("Back to Start") {
                    stage = .intro
                    OrientationManager.restorePortrait()
                }
            } else {
                Button("Keep Practicing", role: .cancel) { }
            }
        } else {
            EmptyView()
        }
    }
}

struct StrategyQuizGrid: View {
    let sections: [StrategyChartSectionData]
    let dealerValues: [Int]
    @Binding var selections: [UUID: PlayerAction?]
    @Binding var selectedAction: PlayerAction?

    @State private var cellFrames: [UUID: CGRect] = [:]
    @State private var dragAction: PlayerAction?
    @State private var draggedCellIDs: Set<UUID> = []

    private var columns: [GridItem] {
        [GridItem(.fixed(90))] + Array(repeating: GridItem(.flexible(minimum: 30)), count: dealerValues.count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .font(.headline)
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(section.rows) { row in
                                Text(row.label)
                                    .font(.caption)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 2)
                                ForEach(row.cells) { cell in
                                    quizCell(for: cell)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(12)
                }
            }
            .padding()
        }
        .coordinateSpace(name: "quizGrid")
        .onPreferenceChange(QuizCellFramePreferenceKey.self) { cellFrames = $0 }
        .simultaneousGesture(dragGesture)
        .onDisappear {
            dragAction = nil
            draggedCellIDs.removeAll()
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("quizGrid"))
            .onChanged { value in
                guard abs(value.translation.width) + abs(value.translation.height) > 2 else { return }
                handleDrag(at: value.location)
            }
            .onEnded { _ in
                dragAction = nil
                draggedCellIDs.removeAll()
            }
    }

    private func handleDrag(at location: CGPoint) {
        guard let targetID = cellFrames.first(where: { $0.value.contains(location) })?.key else { return }

        if dragAction == nil {
            draggedCellIDs.removeAll()
        }

        guard !draggedCellIDs.contains(targetID) else { return }

        selections[targetID] = selectedAction
        dragAction = selectedAction
        draggedCellIDs.insert(targetID)
    }

    private func quizCell(for cell: ChartCellData) -> some View {
        let selection = selections[cell.id] ?? nil
        return StrategyQuizCellView(selection: selection)
            .contentShape(Rectangle())
            .onTapGesture {
                selections[cell.id] = selectedAction
                dragAction = selectedAction
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: QuizCellFramePreferenceKey.self,
                        value: [cell.id: proxy.frame(in: .named("quizGrid"))]
                    )
                }
            )
    }
}

struct StrategyQuizCellView: View {
    let selection: PlayerAction?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(cellColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let selection {
                Text(label(for: selection))
                    .font(.headline.weight(.semibold))
                    .foregroundColor(.primary)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }

    private var cellColor: Color {
        guard let selection else { return Color.secondary.opacity(0.1) }
        return chartActionColor(selection).opacity(0.35)
    }

    private func label(for action: PlayerAction) -> String {
        switch action {
        case .hit: return "H"
        case .double: return "D"
        case .stand: return "S"
        case .split: return "P"
        case .surrender: return "R"
        }
    }
}

// MARK: - Training Suite

struct TrainingOption: Identifiable {
    let id: String
    let title: String
    let icon: String
    let destination: AnyView
}

struct TrainingSuiteView: View {
    private let options: [TrainingOption] = [
        TrainingOption(
            id: "cardSorting",
            title: "Card Sorting",
            icon: "square.grid.2x2",
            destination: AnyView(CardSortingView())
        ),
        TrainingOption(
            id: "speedCounter",
            title: "Speed Counter",
            icon: "speedometer",
            destination: AnyView(SpeedCounterView())
        ),
        TrainingOption(
            id: "deckCountThrough",
            title: "Deck Count Through",
            icon: "rectangle.stack",
            destination: AnyView(DeckCountThroughView())
        ),
        TrainingOption(
            id: "strategyQuiz",
            title: "Strategy Quiz",
            icon: "questionmark.square.dashed",
            destination: AnyView(StrategyQuizView(rules: GameRules.defaultStrategyRules))
        ),
        TrainingOption(
            id: "handSimulation",
            title: "Hand Simulation",
            icon: "hands.clap",
            destination: AnyView(HandSimulationView())
        ),
        TrainingOption(
            id: "deckEstimationBetSizing",
            title: "Deck Estimation and Bet Sizing",
            icon: "scalemass",
            destination: AnyView(DeckEstimationBetSizingView())
        ),
        TrainingOption(
            id: "testOut",
            title: "Test Out",
            icon: "checkmark.seal",
            destination: AnyView(TestOutView())
        ),
        TrainingOption(
            id: "stats",
            title: "Stats",
            icon: "chart.bar.doc.horizontal",
            destination: AnyView(TrainingStatsView())
        )
    ]

    private let columns: [GridItem] = [
        GridItem(.flexible(minimum: 120), spacing: 16),
        GridItem(.flexible(minimum: 120), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(options) { option in
                    NavigationLink {
                        option.destination
                            .navigationTitle(option.title)
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: option.icon)
                                .font(.largeTitle)
                                .frame(width: 64, height: 64)
                                .background(Color.accentColor.opacity(0.12))
                                .foregroundColor(.accentColor)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            Text(option.title)
                                .font(.headline)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
            .padding()
        }
    }
}

private enum DeckBetTrainingConstants {
    static let deckCounts: [Double] = stride(from: 0.25, through: 6.0, by: 0.25).map { value in
        Double(round(value * 100) / 100)
    }
    static let trueCountRange = 0...6

    static func deckLabel(_ value: Double) -> String {
        let formatted = String(format: "%.2f", value)
        return formatted.replacingOccurrences(of: ".00", with: "").replacingOccurrences(of: "0$", with: "", options: .regularExpression)
    }

    static func deckAssetName(for value: Double, showDividers: Bool) -> String {
        let label = deckLabel(value)
        return "\(label)_decks_\(showDividers ? "with_dividers" : "without_dividers")"
    }
}

private struct TrainingAlert: Identifiable {
    let id = UUID()
    let message: String
}

enum DeckBetTrainingMode: String, Identifiable, CaseIterable, Codable, Hashable {
    case deckEstimation = "Deck Estimation Only"
    case betSizing = "Bet Sizing Only"
    case combined = "Combined Training"

    var id: String { rawValue }
}

struct BetSizingTable: Codable, Hashable {
    private(set) var bets: [Int: Double]

    init(bets: [Int: Double]) {
        var normalized: [Int: Double] = [:]
        for tc in DeckBetTrainingConstants.trueCountRange {
            normalized[tc] = bets[tc] ?? 0
        }
        self.bets = normalized
    }

    static var `default`: BetSizingTable {
        var pairs: [(Int, Double)] = [(0, 25)]
        pairs.append(contentsOf: DeckBetTrainingConstants.trueCountRange.dropFirst().map { trueCount in
            (trueCount, Double(trueCount) * 100)
        })
        return BetSizingTable(bets: Dictionary(uniqueKeysWithValues: pairs))
    }

    static var testOutDefault: BetSizingTable {
        .default
    }

    static var defaultInputs: [Int: String] {
        var pairs: [(Int, String)] = [(0, "25")]
        pairs.append(contentsOf: DeckBetTrainingConstants.trueCountRange.dropFirst().map { trueCount in
            (trueCount, String(Int(Double(trueCount) * 100)))
        })
        return Dictionary(uniqueKeysWithValues: pairs)
    }

    mutating func update(trueCount: Int, value: Double) {
        let clamped = min(max(trueCount, DeckBetTrainingConstants.trueCountRange.lowerBound), DeckBetTrainingConstants.trueCountRange.upperBound)
        bets[clamped] = value
    }

    func value(for trueCount: Int) -> Double {
        let clamped = min(max(trueCount, DeckBetTrainingConstants.trueCountRange.lowerBound), DeckBetTrainingConstants.trueCountRange.upperBound)
        return bets[clamped, default: 0]
    }

    func formattedValue(for trueCount: Int) -> String {
        let value = value(for: trueCount)
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    func hash(into hasher: inout Hasher) {
        for key in DeckBetTrainingConstants.trueCountRange {
            hasher.combine(bets[key, default: 0])
        }
    }

    static func == (lhs: BetSizingTable, rhs: BetSizingTable) -> Bool {
        DeckBetTrainingConstants.trueCountRange.allSatisfy { key in
            lhs.bets[key, default: 0] == rhs.bets[key, default: 0]
        }
    }
}

struct DeckBetTrainingStats: Codable, Hashable {
    var deckEstimationCorrect: Int = 0
    var deckEstimationTotal: Int = 0
    var betSizingCorrect: Int = 0
    var betSizingTotal: Int = 0
    var combinedCorrect: Int = 0
    var combinedTotal: Int = 0

    static var empty: DeckBetTrainingStats { DeckBetTrainingStats() }

    var deckEstimationAccuracy: Double? {
        guard deckEstimationTotal > 0 else { return nil }
        return Double(deckEstimationCorrect) / Double(deckEstimationTotal)
    }

    var betSizingAccuracy: Double? {
        guard betSizingTotal > 0 else { return nil }
        return Double(betSizingCorrect) / Double(betSizingTotal)
    }

    var combinedAccuracy: Double? {
        guard combinedTotal > 0 else { return nil }
        return Double(combinedCorrect) / Double(combinedTotal)
    }

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    static func decode(from data: Data) -> DeckBetTrainingStats {
        (try? JSONDecoder().decode(DeckBetTrainingStats.self, from: data)) ?? .empty
    }
}

struct DeckBetTrainingConfig: Hashable {
    let mode: DeckBetTrainingMode
    let showDividers: Bool
    var betTable: BetSizingTable
}

struct DeckEstimationBetSizingView: View {
    @State private var selectedMode: DeckBetTrainingMode?
    @State private var showDividers: Bool = true
    @State private var betTable: BetSizingTable = .default
    @State private var betInputs: [Int: String] = BetSizingTable.defaultInputs
    @State private var navigationConfig: DeckBetTrainingConfig?

    @AppStorage("deckBetTrainingStats") private var storedStats: Data = Data()
    @State private var stats: DeckBetTrainingStats = .empty

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Build your deck estimation and bet sizing intuition. Choose a mode, adjust your bet ramp if desired, then start training.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                modeSelection

                if selectedMode == .deckEstimation || selectedMode == .combined {
                    Toggle("Show Deck Dividers", isOn: $showDividers)
                        .toggleStyle(.switch)
                }

                if selectedMode == .betSizing || selectedMode == .combined {
                    BetSizingTableView(
                        betTable: betTable,
                        isEditable: true,
                        betInputs: betInputs,
                        title: "True Count Bet Table",
                        onUpdate: updateBet(for:newValue:)
                    )
                }

                Button(action: startTraining) {
                    Text("Start Training")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(selectedMode == nil ? Color.secondary.opacity(0.2) : Color.accentColor)
                        .foregroundColor(selectedMode == nil ? .secondary : .white)
                        .cornerRadius(12)
                }
                .disabled(selectedMode == nil)
            }
            .padding()
        }
        .navigationTitle("Deck Estimation & Bet Sizing")
        .navigationBarTitleDisplayMode(.inline)
        .background(navigationLink)
        .onAppear {
            stats = DeckBetTrainingStats.decode(from: storedStats)
        }
        .onChange(of: stats) { newValue in
            storedStats = newValue.encoded()
        }
    }

    private var modeSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mode")
                .font(.headline)
            ForEach(DeckBetTrainingMode.allCases) { mode in
                Button {
                    withAnimation { selectedMode = mode }
                } label: {
                    HStack {
                        Image(systemName: selectedMode == mode ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selectedMode == mode ? .accentColor : .secondary)
                        Text(mode.rawValue)
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(10)
                }
            }
        }
    }

    private func updateBet(for trueCount: Int, newValue: String) {
        betInputs[trueCount] = newValue
        if let parsed = Double(newValue) {
            betTable.update(trueCount: trueCount, value: parsed)
        }
    }

    private func startTraining() {
        guard let mode = selectedMode else { return }
        let config = DeckBetTrainingConfig(mode: mode, showDividers: showDividers, betTable: betTable)
        navigationConfig = config
    }

    @ViewBuilder
    private var navigationLink: some View {
        NavigationLink(
            isActive: Binding(
                get: { navigationConfig != nil },
                set: { isActive in
                    if !isActive {
                        navigationConfig = nil
                    }
                }
            )
        ) {
            if let config = navigationConfig {
                switch config.mode {
                case .deckEstimation:
                    DeckEstimationTrainingView(showDividers: config.showDividers, stats: $stats)
                case .betSizing:
                    BetSizingTrainingView(config: config, stats: $stats)
                case .combined:
                    CombinedTrainingView(config: config, stats: $stats)
                }
            } else {
                EmptyView()
            }
        } label: {
            EmptyView()
        }
        .hidden()
    }
}

struct BetSizingTableView: View {
    let betTable: BetSizingTable
    var isEditable: Bool = false
    var betInputs: [Int: String] = [:]
    var title: String = "True Count Table"
    var onUpdate: ((Int, String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("True Counts")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    ForEach(DeckBetTrainingConstants.trueCountRange, id: \.self) { trueCount in
                        Text(trueCountLabel(trueCount))
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }

                GridRow {
                    Text("Bet Sizes")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    ForEach(DeckBetTrainingConstants.trueCountRange, id: \.self) { trueCount in
                        betCell(for: trueCount)
                    }
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(10)
        }
    }

    private func betCell(for trueCount: Int) -> some View {
        Group {
            if isEditable, let onUpdate {
                TextField("0", text: Binding(
                    get: { betInputs[trueCount] ?? betTable.formattedValue(for: trueCount) },
                    set: { newValue in onUpdate(trueCount, newValue) }
                ))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.caption)
            } else {
                Text(betTable.formattedValue(for: trueCount))
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(6)
        .background(Color.white.opacity(0.6))
        .cornerRadius(8)
    }

    private func trueCountLabel(_ value: Int) -> String {
        if value == 0 { return "0" }
        if value == DeckBetTrainingConstants.trueCountRange.upperBound {
            return "≥+\(value)"
        }
        return "+\(value)"
    }
}

struct DeckEstimationTrainingView: View {
    let showDividers: Bool
    @Binding var stats: DeckBetTrainingStats

    @State private var currentDecks: Double = DeckBetTrainingConstants.deckCounts.randomElement() ?? 0.25
    @State private var selectedGuess: Double = DeckBetTrainingConstants.deckCounts.first ?? 0.25
    @State private var feedback: String?
    @State private var correctionAlert: TrainingAlert?
    @State private var pendingDecks: Double?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Estimate the number of decks in the discard tray.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Image(DeckBetTrainingConstants.deckAssetName(for: currentDecks, showDividers: showDividers))
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(height: 320)
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(16)

                VStack(alignment: .leading, spacing: 8) {
                    Text("How many decks are present?")
                        .font(.headline)
                    Picker("Decks", selection: $selectedGuess) {
                        ForEach(DeckBetTrainingConstants.deckCounts, id: \.self) { value in
                            Text(DeckBetTrainingConstants.deckLabel(value)).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Button(action: submitGuess) {
                    Text("Submit Guess")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }

                if let feedback {
                    Text(feedback)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                accuracySummary
            }
            .padding()
        }
        .navigationTitle("Deck Estimation")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $correctionAlert) { alert in
            Alert(
                title: Text("Correction"),
                message: Text(alert.message),
                dismissButton: .default(Text("Got it")) {
                    if let next = pendingDecks {
                        currentDecks = next
                        selectedGuess = DeckBetTrainingConstants.deckCounts.first ?? 0.25
                        pendingDecks = nil
                    }
                }
            )
        }
    }

    private var accuracySummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Deck Estimation Correctness")
                .font(.headline)
            Text("Correct: \(stats.deckEstimationCorrect) / \(stats.deckEstimationTotal)")
                .font(.subheadline)
            Text("Accuracy: \(formattedPercent(stats.deckEstimationAccuracy))")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(12)
    }

    private func submitGuess() {
        let difference = abs(selectedGuess - currentDecks)
        let correct = difference <= 0.25 + 0.0001
        stats.deckEstimationTotal += 1
        if correct { stats.deckEstimationCorrect += 1 }

        let correctLabel = DeckBetTrainingConstants.deckLabel(currentDecks)
        feedback = correct
            ? "Within the margin! The discard tray showed \(correctLabel) decks."
            : "Not quite. It was \(correctLabel) decks."

        let nextDecks = DeckBetTrainingConstants.deckCounts.randomElement() ?? currentDecks

        if correct {
            currentDecks = nextDecks
            selectedGuess = DeckBetTrainingConstants.deckCounts.first ?? 0.25
        } else {
            pendingDecks = nextDecks
            correctionAlert = TrainingAlert(message: "The tray held \(correctLabel) decks.")
        }
    }

    private func formattedPercent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }
}

struct BetSizingTrainingView: View {
    let config: DeckBetTrainingConfig
    @Binding var stats: DeckBetTrainingStats

    @State private var runningCount: Int = 1
    @State private var decksInPlay: Int = 2
    @State private var decksInDiscard: Double = 0.5
    @State private var betInput: String = ""
    @State private var resultMessage: String?
    @State private var activeAlert: TrainingAlert?
    @State private var pendingScenarioAfterAlert: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                BetSizingTableView(betTable: config.betTable, title: "Your True Count Table")

                statRow

                VStack(alignment: .leading, spacing: 8) {
                    Text("What is your bet?")
                        .font(.headline)
                    TextField("Enter bet", text: $betInput)
                        .keyboardType(.numberPad)
                        .padding()
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(10)
                }

                Button(action: gradeBet) {
                    Text("Submit Bet")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }

                if let resultMessage {
                    Text(resultMessage)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle("Bet Sizing")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $activeAlert) { alert in
            Alert(
                title: Text("Note"),
                message: Text(alert.message),
                dismissButton: .default(Text("Got it")) {
                    if pendingScenarioAfterAlert {
                        pendingScenarioAfterAlert = false
                        generateScenario(resetFeedback: false)
                    }
                }
            )
        }
        .onAppear { generateScenario() }
    }

    private var statRow: some View {
        HStack(spacing: 12) {
            statTile(title: "Running Count", value: "\(runningCount)")
            statTile(title: "Decks in Play", value: DeckBetTrainingConstants.deckLabel(Double(decksInPlay)))
            statTile(title: "Decks in Discard", value: DeckBetTrainingConstants.deckLabel(decksInDiscard))
        }
    }

    private func statTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(12)
    }

    private func generateScenario(resetFeedback: Bool = true) {
        runningCount = Int.random(in: 1...20)
        decksInPlay = [2, 6, 8].randomElement() ?? 6
        decksInDiscard = randomDiscard(for: decksInPlay)
        betInput = ""
        if resetFeedback {
            resultMessage = nil
        }
    }

    private func randomDiscard(for decksInPlay: Int) -> Double {
        let cappedPlay = Double(decksInPlay)
        let upperBound = max(0.5, min(cappedPlay - 0.25, cappedPlay))
        let raw = Double.random(in: 0.5...upperBound)
        let truncated = floor(raw * 4) / 4
        return max(0.5, truncated)
    }

    private func gradeBet() {
        guard let betValue = Double(betInput) else {
            resultMessage = "Please enter a valid number."
            return
        }

        let decksRemaining = Double(decksInPlay) - decksInDiscard
        let trueCount = Double(runningCount) / max(0.25, decksRemaining)
        let evaluation = evaluateBet(betValue, trueCount: trueCount)

        stats.betSizingTotal += 1
        if evaluation.isCorrect { stats.betSizingCorrect += 1 }

        resultMessage = evaluation.feedback
        if let guidance = evaluation.guidance {
            activeAlert = TrainingAlert(message: guidance)
            pendingScenarioAfterAlert = true
        } else if !evaluation.isCorrect {
            activeAlert = TrainingAlert(message: evaluation.feedback)
            pendingScenarioAfterAlert = true
        } else {
            generateScenario(resetFeedback: false)
        }
    }

    private func evaluateBet(_ bet: Double, trueCount: Double) -> (isCorrect: Bool, feedback: String, guidance: String?) {
        let cappedTrueCount = min(trueCount, Double(DeckBetTrainingConstants.trueCountRange.upperBound))
        let lower = Int(floor(cappedTrueCount))
        let upper = Int(ceil(cappedTrueCount))
        let lowerBet = config.betTable.value(for: lower)
        let upperBet = config.betTable.value(for: upper)

        if lower == upper {
            let isCorrect = abs(bet - lowerBet) <= 0.01
            let feedback = isCorrect ? "Correct! True count +\(lower) maps to $\(Int(lowerBet))." : "True count +\(lower) maps to $\(Int(lowerBet))."
            return (isCorrect, feedback, nil)
        }

        let minAccepted = min(lowerBet, upperBet)
        let maxAccepted = max(lowerBet, upperBet)
        let isCorrect = bet >= minAccepted && bet <= maxAccepted
        let fraction = cappedTrueCount - Double(lower)
        let interpolated = lowerBet + fraction * (upperBet - lowerBet)
        let guidanceNeeded = isCorrect && interpolated > 0 && abs(bet - interpolated) > interpolated * 0.25

        let feedback: String
        if isCorrect {
            feedback = "Nice work. True count +\(String(format: "%.2f", cappedTrueCount)) supports between $\(Int(minAccepted)) and $\(Int(maxAccepted))."
        } else {
            feedback = "True count +\(String(format: "%.2f", cappedTrueCount)) calls for $\(Int(minAccepted))–$\(Int(maxAccepted))."
        }

        let guidance = guidanceNeeded ? "Your answer was acceptable, but an interpolated bet is about $\(Int(interpolated))." : nil

        return (isCorrect, feedback, guidance)
    }
}

struct CombinedTrainingView: View {
    let config: DeckBetTrainingConfig
    @Binding var stats: DeckBetTrainingStats

    @State private var runningCount: Int = 1
    @State private var decksInPlay: Int = 2
    @State private var decksInDiscard: Double = 0.5
    @State private var betInput: String = ""
    @State private var resultMessage: String?
    @State private var activeAlert: TrainingAlert?
    @State private var pendingScenarioAfterAlert: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                BetSizingTableView(betTable: config.betTable, title: "Your True Count Table")

                HStack(spacing: 12) {
                    statTile(title: "Running Count", value: "\(runningCount)")
                    statTile(title: "Decks in Play", value: DeckBetTrainingConstants.deckLabel(Double(decksInPlay)))
                }

                Image(DeckBetTrainingConstants.deckAssetName(for: decksInDiscard, showDividers: config.showDividers))
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(16)

                VStack(alignment: .leading, spacing: 8) {
                    Text("What is your bet?")
                        .font(.headline)
                    TextField("Enter bet", text: $betInput)
                        .keyboardType(.numberPad)
                        .padding()
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(10)
                }

                Button(action: gradeBet) {
                    Text("Submit Bet")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }

                if let resultMessage {
                    Text(resultMessage)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle("Combined Training")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $activeAlert) { alert in
            Alert(
                title: Text("Note"),
                message: Text(alert.message),
                dismissButton: .default(Text("Understood")) {
                    if pendingScenarioAfterAlert {
                        pendingScenarioAfterAlert = false
                        generateScenario(resetFeedback: false)
                    }
                }
            )
        }
        .onAppear { generateScenario() }
    }

    private func statTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(12)
    }

    private func generateScenario(resetFeedback: Bool = true) {
        runningCount = Int.random(in: 1...20)
        decksInPlay = [2, 6, 8].randomElement() ?? 6
        let cappedDiscardMax = min(Double(decksInPlay), 6.0)
        let upperBound = max(0.5, cappedDiscardMax - 0.25)
        let raw = Double.random(in: 0.5...upperBound)
        decksInDiscard = max(0.5, floor(raw * 4) / 4)
        betInput = ""
        if resetFeedback {
            resultMessage = nil
        }
    }

    private func gradeBet() {
        guard let betValue = Double(betInput) else {
            resultMessage = "Please enter a valid number."
            return
        }

        let decksRemaining = Double(decksInPlay) - decksInDiscard
        let trueCount = Double(runningCount) / max(0.25, decksRemaining)
        let evaluation = evaluateBet(betValue, trueCount: trueCount)

        stats.combinedTotal += 1
        if evaluation.isCorrect { stats.combinedCorrect += 1 }

        resultMessage = evaluation.feedback
        if let guidance = evaluation.guidance {
            activeAlert = TrainingAlert(message: guidance)
            pendingScenarioAfterAlert = true
        } else if !evaluation.isCorrect {
            activeAlert = TrainingAlert(message: evaluation.feedback)
            pendingScenarioAfterAlert = true
        } else {
            generateScenario(resetFeedback: false)
        }
    }

    private func evaluateBet(_ bet: Double, trueCount: Double) -> (isCorrect: Bool, feedback: String, guidance: String?) {
        let cappedTrueCount = min(trueCount, Double(DeckBetTrainingConstants.trueCountRange.upperBound))
        let lower = Int(floor(cappedTrueCount))
        let upper = Int(ceil(cappedTrueCount))
        let lowerBet = config.betTable.value(for: lower)
        let upperBet = config.betTable.value(for: upper)

        if lower == upper {
            let isCorrect = abs(bet - lowerBet) <= 0.01
            let feedback = isCorrect ? "Correct! True count +\(lower) maps to $\(Int(lowerBet))." : "True count +\(lower) maps to $\(Int(lowerBet))."
            return (isCorrect, feedback, nil)
        }

        let minAccepted = min(lowerBet, upperBet)
        let maxAccepted = max(lowerBet, upperBet)
        let isCorrect = bet >= minAccepted && bet <= maxAccepted
        let fraction = cappedTrueCount - Double(lower)
        let interpolated = lowerBet + fraction * (upperBet - lowerBet)
        let guidanceNeeded = isCorrect && interpolated > 0 && abs(bet - interpolated) > interpolated * 0.25

        let feedback: String
        if isCorrect {
            feedback = "Nice work. True count +\(String(format: "%.2f", cappedTrueCount)) supports between $\(Int(minAccepted)) and $\(Int(maxAccepted))."
        } else {
            feedback = "True count +\(String(format: "%.2f", cappedTrueCount)) calls for $\(Int(minAccepted))–$\(Int(maxAccepted))."
        }

        let guidance = guidanceNeeded ? "Your answer was acceptable, but an interpolated bet is about $\(Int(interpolated))." : nil

        return (isCorrect, feedback, guidance)
    }
}

// MARK: - Hand Simulation

struct HandSimulationSettings {
    var rules: GameRules = GameRules(
        decks: 6,
        dealerHitsSoft17: true,
        doubleAfterSplit: true,
        surrenderAllowed: true,
        blackjackPayout: 1.5,
        penetration: 0.75
    )
    var resplitAces: Bool = true
    var bettingEnabled: Bool = true
    var askRunningCount: Bool = true
    var runningCountCadence: Int = 3
    var betTable: BetSizingTable = .default
    var dealSpeed: Double = 0.45
}

struct HandSimulationSession: Identifiable, Codable {
    let id: UUID
    let date: Date
    let correctDecisions: Int
    let totalDecisions: Int
    let longestStreak: Int
    let shoesPlayed: Int
    let perfectShoes: Int
    let longestPerfectShoeStreak: Int

    init(date: Date, correctDecisions: Int, totalDecisions: Int, longestStreak: Int, shoesPlayed: Int, perfectShoes: Int, longestPerfectShoeStreak: Int) {
        id = UUID()
        self.date = date
        self.correctDecisions = correctDecisions
        self.totalDecisions = totalDecisions
        self.longestStreak = longestStreak
        self.shoesPlayed = shoesPlayed
        self.perfectShoes = perfectShoes
        self.longestPerfectShoeStreak = longestPerfectShoeStreak
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, correctDecisions, totalDecisions, longestStreak, shoesPlayed, perfectShoes, longestPerfectShoeStreak
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        correctDecisions = try container.decode(Int.self, forKey: .correctDecisions)
        totalDecisions = try container.decode(Int.self, forKey: .totalDecisions)
        longestStreak = try container.decode(Int.self, forKey: .longestStreak)
        shoesPlayed = try container.decode(Int.self, forKey: .shoesPlayed)
        perfectShoes = try container.decode(Int.self, forKey: .perfectShoes)
        longestPerfectShoeStreak = try container.decode(Int.self, forKey: .longestPerfectShoeStreak)
    }
}

struct TestOutConfiguration {
    let onFailure: (TestOutFailureReason) -> Void
}

enum TestOutFailureReason: Hashable {
    case basicStrategy(expected: String)
    case betting(expectedRange: String, trueCountLabel: String, actualBet: Int)
    case runningCount(expected: Int, guess: String)

    var title: String {
        switch self {
        case .basicStrategy: return "Basic Strategy Error"
        case .betting: return "Incorrect Bet"
        case .runningCount: return "Running Count Miss"
        }
    }

    var message: String {
        switch self {
        case .basicStrategy(let expected):
            return "The test ends immediately when you deviate from basic strategy. The correct play was \(expected)."
        case .betting(let expectedRange, let trueCountLabel, let actualBet):
            return "Bets must stay within the accepted range for each true count. At true count \(trueCountLabel), the correct bet was \(expectedRange); you bet $\(actualBet)."
        case .runningCount(let expected, let guess):
            return "Running count prompts must be within 1. You answered \(guess); the running count was \(expected)."
        }
    }
}

struct HandSimulationStats {
    let correctDecisions: Int
    let totalDecisions: Int
    let accuracy: Double?
    let longestStreak: Int
    let perfectShoes: Int
    let longestPerfectStreak: Int

    static func make(for sessions: [HandSimulationSession]) -> HandSimulationStats {
        let correct = sessions.reduce(0) { $0 + $1.correctDecisions }
        let total = sessions.reduce(0) { $0 + $1.totalDecisions }
        let accuracy = total > 0 ? Double(correct) / Double(total) : nil
        let longest = sessions.map(\.longestStreak).max() ?? 0
        let perfectShoes = sessions.reduce(0) { $0 + $1.perfectShoes }
        let longestPerfect = sessions.map(\.longestPerfectShoeStreak).max() ?? 0

        return HandSimulationStats(
            correctDecisions: correct,
            totalDecisions: total,
            accuracy: accuracy,
            longestStreak: longest,
            perfectShoes: perfectShoes,
            longestPerfectStreak: longestPerfect
        )
    }
}

struct HandSimulationView: View {
    @AppStorage("handSimulationSessions") private var storedSessions: Data = Data()

    @State private var settings = HandSimulationSettings()
    @State private var betInputs: [Int: String] = BetSizingTable.defaultInputs
    @State private var sessions: [HandSimulationSession] = []
    @State private var startRun: Bool = false
    @State private var activeSettings: HandSimulationSettings?

    private var overallStats: HandSimulationStats {
        HandSimulationStats.make(for: sessions)
    }

    private var weeklyStats: HandSimulationStats {
        guard let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return overallStats }
        let recent = sessions.filter { $0.date >= weekAgo }
        return HandSimulationStats.make(for: recent)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Build full-hand intuition by practicing betting, counting, and strategy fundamentals in one place.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    ruleSection
                    dealingSpeedSection
                    runningCountSection
                    betSection
                    statsSection
                }
                .padding()
            }
            .navigationTitle("Hand Simulation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Start Drill", action: beginRun)
                        .fontWeight(.semibold)
                }
            }

            NavigationLink(isActive: $startRun) {
                if let activeSettings {
                    HandSimulationRunView(settings: activeSettings) { session in
                        sessions.insert(session, at: 0)
                        persistSessions()
                    }
                } else {
                    EmptyView()
                }
            } label: {
                EmptyView()
            }
            .hidden()
        }
        .onAppear(perform: loadSessions)
    }

    private var ruleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Game Rules")
                .font(.headline)
            Stepper(value: $settings.rules.decks, in: 1...8) {
                Text("Number of Decks: \(settings.rules.decks)")
            }
            Toggle("Dealer Hits Soft 17", isOn: $settings.rules.dealerHitsSoft17)
            Toggle("Surrender Allowed", isOn: $settings.rules.surrenderAllowed)
            Toggle("Re-split Aces", isOn: $settings.resplitAces)
            VStack(alignment: .leading) {
                HStack {
                    Text("Penetration")
                    Spacer()
                    Text(String(format: "%.0f%%", settings.rules.penetration * 100))
                        .foregroundColor(.secondary)
                }
                Slider(value: $settings.rules.penetration, in: 0.5...0.95, step: 0.05)
            }
            Text("Double after split is always enabled for this drill.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(14)
    }

    private var runningCountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Ask Running Count", isOn: $settings.askRunningCount.animation())
            if settings.askRunningCount {
                Stepper(value: $settings.runningCountCadence, in: 1...10) {
                    Text("Hands Between Prompts: \(settings.runningCountCadence)")
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(14)
    }

    private var dealingSpeedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dealing Speed")
                .font(.headline)
            HStack {
                Text("Faster")
                    .font(.caption)
                Slider(value: $settings.dealSpeed, in: 0.2...1.2, step: 0.05) {
                    Text("Dealing Speed")
                }
                Text("Slower")
                    .font(.caption)
            }
            Text(String(format: "Current: %.2fs", settings.dealSpeed))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(14)
    }

    private var betSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Enable Betting Practice", isOn: $settings.bettingEnabled.animation())
            Text("True Count / Betting Table")
                .font(.headline)
            if settings.bettingEnabled {
                BetSizingTableView(
                    betTable: settings.betTable,
                    isEditable: true,
                    betInputs: betInputs,
                    title: "True Count Bet Table",
                    onUpdate: updateBet(for:newValue:)
                )
            }
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Performance")
                .font(.headline)
            statRow(title: "Accurate Decisions", overall: overallStats.accuracy, weekly: weeklyStats.accuracy, formatter: percentLabel)
            statRow(title: "Longest Decision Streak", overall: Double(overallStats.longestStreak), weekly: Double(weeklyStats.longestStreak), formatter: countLabel)
            statRow(title: "Perfect Shoes", overall: Double(overallStats.perfectShoes), weekly: Double(weeklyStats.perfectShoes), formatter: countLabel)
            statRow(title: "Longest Perfect Shoe Streak", overall: Double(overallStats.longestPerfectStreak), weekly: Double(weeklyStats.longestPerfectStreak), formatter: countLabel)
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(14)
    }

    private func statRow(title: String, overall: Double?, weekly: Double?, formatter: (Double?) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text("All-time: \(formatter(overall))")
            Text("Last 7 days: \(formatter(weekly))")
                .foregroundColor(.secondary)
        }
    }

    private func percentLabel(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }

    private func countLabel(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(Int(value))
    }

    private func updateBet(for trueCount: Int, newValue: String) {
        betInputs[trueCount] = newValue
        if let parsed = Double(newValue) {
            settings.betTable.update(trueCount: trueCount, value: parsed)
        }
    }

    private func beginRun() {
        activeSettings = settings
        startRun = true
    }

    private func loadSessions() {
        guard let decoded = try? JSONDecoder().decode([HandSimulationSession].self, from: storedSessions) else { return }
        sessions = decoded
    }

    private func persistSessions() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        storedSessions = data
    }
}

struct HandSimulationRunView: View {
    private let maxSplitDepth = 3
    private let discardSizes = DeckBetTrainingConstants.deckCounts
    private let baseCardWidth: CGFloat = 70
    private let baseCardOffsetX: CGFloat = 24
    private let baseCardOffsetY: CGFloat = 10
    private let baseCardTopBuffer: CGFloat = 25
    private let baseHandSpacing: CGFloat = 16
    private let baseTrayWidth: CGFloat = 90
    private var animationSpeed: Double { max(0.05, settings.dealSpeed) }

    private func layoutScale(for size: CGSize) -> CGFloat {
        let widthScale = size.width / 430
        let heightScale = size.height / 850
        return max(0.65, min(1.1, min(widthScale, heightScale)))
    }

    private func adjustedScale(from base: CGFloat, containerSize: CGSize) -> CGFloat {
        let tableVerticalBudget = max(containerSize.height * 0.38, 180)
        let headerAndSpacing = cardHeight(for: base) + 44
        let playerAreaBudget = max(120, tableVerticalBudget - headerAndSpacing)
        let currentHeight = maxHandHeight(scale: base)
        guard currentHeight > 0 else { return base }

        let heightScale = min(1, playerAreaBudget / currentHeight)
        return max(0.55, base * heightScale)
    }

    private func cardWidth(for scale: CGFloat) -> CGFloat { baseCardWidth * scale }
    private func cardHeight(for scale: CGFloat) -> CGFloat { cardWidth(for: scale) / (2.5/3.5) }
    private func cardOffsetX(for scale: CGFloat) -> CGFloat { baseCardOffsetX * scale }
    private func cardOffsetY(for scale: CGFloat) -> CGFloat { baseCardOffsetY * scale }
    private func cardTopBuffer(for scale: CGFloat) -> CGFloat { baseCardTopBuffer * scale }
    private func handSpacing(for scale: CGFloat) -> CGFloat { baseHandSpacing * scale }
    private func trayWidth(for scale: CGFloat) -> CGFloat { baseTrayWidth * scale }

    let settings: HandSimulationSettings
    let onComplete: (HandSimulationSession) -> Void
    var navigationTitle: String = "Hand Simulation"
    var endActionLabel: String = "End Drill"
    var testOutConfig: TestOutConfiguration? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var shoe: [SpeedCounterCard] = []
    @State private var dealerCards: [SpeedCounterDealtCard] = []
    @State private var playerHands: [SpeedCounterHandState] = []
    @State private var cardsPlayed: Int = 0
    @State private var runningCount: Int = 0
    @State private var awaitingBet: Bool = true
    @State private var negativeChipMode: Bool = false
    @State private var currentBet: Double = 0
    @State private var betFeedback: BetFeedback?
    @State private var activeAlert: SimulationAlert?
    @State private var showRunningCountPrompt: Bool = false
    @State private var runningCountGuess: String = ""
    @State private var sessionProfit: Double = 0
    @State private var lastHandProfit: Double? = nil
    @State private var decisions: Int = 0
    @State private var correctDecisions: Int = 0
    @State private var currentStreak: Int = 0
    @State private var longestStreak: Int = 0
    @State private var shoesPlayed: Int = 0
    @State private var currentShoePerfect: Bool = true
    @State private var perfectShoes: Int = 0
    @State private var perfectStreak: Int = 0
    @State private var longestPerfectStreak: Int = 0
    @State private var handsCompleted: Int = 0
    @State private var handsSinceCountPrompt: Int = 0
    @State private var sessionLogged: Bool = false
    @State private var showTrayExpanded: Bool = false
    @State private var showCounts: Bool = false
    @State private var awaitingNextHand: Bool = false
    @State private var initialDealTask: Task<Void, Never>?
    @State private var testOutTerminated: Bool = false

    private struct BetFeedback: Identifiable {
        let id = UUID()
        let message: String
        let isError: Bool
    }

    private struct SimulationAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let onDismiss: (() -> Void)?
    }

    private struct ChipOption: Identifiable {
        let id = UUID()
        let value: Int
        let color: Color
    }

    private let chipOptions: [ChipOption] = [
        ChipOption(value: 5, color: .red),
        ChipOption(value: 25, color: .green),
        ChipOption(value: 100, color: .black),
        ChipOption(value: 500, color: .purple)
    ]

    private var isTestOutMode: Bool {
        testOutConfig != nil
    }

    private var bettingEnabled: Bool {
        settings.bettingEnabled && !testOutTerminated
    }

    private var chipsEnabled: Bool {
        awaitingBet && !showRunningCountPrompt && bettingEnabled && !testOutTerminated
    }

    private var decksRemaining: Double {
        let remaining = Double(shoe.count) / 52.0
        return max(remaining, 0.25)
    }

    private var trueCount: Double {
        Double(runningCount) / decksRemaining
    }

    private var dealerUpCard: Card? {
        guard let up = dealerCards.last(where: { !$0.isFaceDown }) else { return nil }
        return Card(rank: up.card.rank)
    }

    private var recommendedAction: PlayerAction? {
        guard let hand = playerHands.first else { return nil }
        guard let dealerUp = dealerUpCard else { return nil }
        let handModel = convert(hand: hand)
        return advisedAction(for: handModel, dealerUp: dealerUp)
    }

    private func defaultBet() -> Double {
        settings.betTable.value(for: 0)
    }

    private var discardAssetName: String {
        let decksDiscarded = max(0.25, min(Double(cardsPlayed) / 52.0, Double(settings.rules.decks)))
        let closest = discardSizes.min(by: { abs($0 - decksDiscarded) < abs($1 - decksDiscarded) }) ?? 0.25
        return DeckBetTrainingConstants.deckAssetName(for: closest, showDividers: true)
    }

    private var rules: GameRules {
        var rules = settings.rules
        rules.doubleAfterSplit = true
        return rules
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = adjustedScale(from: layoutScale(for: proxy.size), containerSize: proxy.size)

            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()
                    .ignoresSafeArea(.keyboard, edges: .bottom)

                VStack(spacing: 12) {
                    tableArea(scale: scale, availableWidth: proxy.size.width)

                    betControls(scale: scale)

                    actionButtons(scale: scale)

                    sessionProfitView
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .onAppear(perform: startShoe)
                .onDisappear {
                    if !sessionLogged {
                        completeSession()
                    }
                }
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(endActionLabel, action: completeSession)
                            .fontWeight(.semibold)
                    }
                }

                if showRunningCountPrompt {
                    modalOverlay(scale: scale) { runningCountPrompt }
                }
            }
            .alert(item: $activeAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("Continue")) {
                        alert.onDismiss?()
                    }
                )
            }
            .sheet(isPresented: $showTrayExpanded) {
                VStack {
                    Image(discardAssetName)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .padding()
                    Button("Close") { showTrayExpanded = false }
                        .buttonStyle(.borderedProminent)
                        .padding(.bottom)
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func tableArea(scale: CGFloat, availableWidth: CGFloat) -> some View {
        VStack(spacing: 12) {
            if availableWidth < 430 {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        discardTray(scale: scale, expandedWidth: availableWidth)
                        Spacer()
                        countDisplay(scale: scale)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    dealerSection(scale: scale)
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    discardTray(scale: scale, expandedWidth: availableWidth)

                    dealerSection(scale: scale)

                    Spacer()

                    countDisplay(scale: scale)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Player")
                    .font(.headline)
                GeometryReader { proxy in
                    let contentWidth = totalHandsWidth(scale: scale)
                    let horizontalPadding = max((proxy.size.width - contentWidth) / 2, 0) + 16

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(playerHands) { hand in
                                playerHandView(hand, scale: scale)
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .frame(
                            maxWidth: max(proxy.size.width, contentWidth + (horizontalPadding * 2)),
                            alignment: .center
                        )
                        .frame(height: maxHandHeight(scale: scale) + 24, alignment: .bottom)
                    }
                }
                .frame(height: maxHandHeight(scale: scale) + 32)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            if awaitingBet {
                VStack(spacing: 14) {
                    Text("Tap Chips to Enter Bet")
                        .font(.title3.weight(.bold))
                        .multilineTextAlignment(.center)
                    Button(action: submitBetAndDeal) {
                        Text("Deal Next Hand")
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .frame(maxWidth: 220)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if awaitingNextHand {
                VStack(spacing: 14) {
                    Text("Hand Complete")
                        .font(.title3.weight(.bold))
                        .multilineTextAlignment(.center)
                    if let lastHandProfit {
                        Text(
                            lastHandProfit == 0
                                ? "Push"
                                : lastHandProfit > 0
                                    ? String(format: "Won $%.2f", lastHandProfit)
                                    : String(format: "Lost $%.2f", abs(lastHandProfit))
                        )
                        .font(.headline)
                        .foregroundColor(
                            lastHandProfit == 0
                                ? .primary
                                : lastHandProfit > 0 ? .green : .red
                        )
                    }
                    Button(action: proceedToNextHand) {
                        Text(showRunningCountPrompt ? "Answer count to continue" : "Next Hand")
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .frame(maxWidth: 220)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(showRunningCountPrompt)
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func countDisplay(scale: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 10) {
                Button(action: { showCounts.toggle() }) {
                    Image(systemName: showCounts ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 17 * scale, weight: .regular))
                }
                .buttonStyle(.plain)

                VStack(alignment: .trailing, spacing: 4) {
                    Text("Running Count")
                        .font(.system(size: 12 * scale))
                        .foregroundColor(.secondary)
                    Text(showCounts ? "\(runningCount)" : "— —")
                        .font(.system(size: 17 * scale, weight: .semibold, design: .monospaced))
                    Text("True Count")
                        .font(.system(size: 12 * scale))
                        .foregroundColor(.secondary)
                    Text(showCounts ? String(format: "%.2f", trueCount) : "— —")
                        .font(.system(size: 14 * scale, weight: .regular, design: .monospaced))
                }
            }
        }
        .frame(minWidth: 140 * scale, alignment: .trailing)
    }

    private func betControls(scale: CGFloat) -> some View {
        VStack(alignment: .center, spacing: 12) {
            VStack(spacing: 2) {
                Text("Bet Size:")
                    .font(.system(size: 17 * scale, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .center)
                Text("$\(Int(currentBet))")
                    .font(.system(size: 20 * scale, weight: .semibold))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if awaitingBet {
                Text("Tap Chips to Enter Bet")
                    .font(.system(size: 20 * scale, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if !bettingEnabled {
                Text("Betting is disabled for this drill.")
                    .font(.system(size: 15 * scale))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            HStack(spacing: 14 * scale) {
                Spacer()
                ForEach(chipOptions) { chip in
                    Button(action: { applyChip(chip) }) {
                        Text(chipLabel(for: chip))
                            .font(.system(size: 17 * scale, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 70 * scale, height: 70 * scale)
                            .background(chip.color)
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.6), lineWidth: 2)
                            )
                    }
                    .disabled(!chipsEnabled)
                    .opacity(chipsEnabled ? 1 : 0.35)
                }

                Button(action: { negativeChipMode.toggle() }) {
                    Image(systemName: negativeChipMode ? "plus.circle.fill" : "minus.circle.fill")
                        .font(.system(size: 28 * scale))
                        .foregroundColor(negativeChipMode ? .orange : .secondary)
                        .padding(6 * scale)
                }
                .background(.ultraThinMaterial)
                .clipShape(Circle())
                .disabled(!chipsEnabled)
                .opacity(chipsEnabled ? 1 : 0.35)
                Spacer()
            }

            if let betFeedback {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: betFeedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundColor(betFeedback.isError ? .orange : .green)
                    Text(betFeedback.message)
                        .font(.system(size: 12 * scale))
                        .foregroundColor(betFeedback.isError ? .primary : .green)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.horizontal, 6)
    }

    private func actionButtons(scale: CGFloat) -> some View {
        HStack(spacing: 10 * scale) {
            ForEach(PlayerAction.allCases, id: \.self) { action in
                Button(
                    action: { handleAction(action) },
                    label: { actionLabel(for: action) }
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10 * scale)
                .padding(.horizontal, 8 * scale)
                .background(buttonEnabled(action) ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.1))
                .foregroundColor(buttonEnabled(action) ? .primary : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(!buttonEnabled(action) || awaitingBet || awaitingNextHand || showRunningCountPrompt)
            }
        }
        .padding(.horizontal, 6 * scale)
    }

    private func actionLabel(for action: PlayerAction) -> some View {
        VStack {
            Text(label(for: action))
                .font(.system(size: 15, weight: .semibold))
            Text(actionTitle(for: action))
                .font(.system(size: 11))
        }
    }

    private func buttonEnabled(_ action: PlayerAction) -> Bool {
        if testOutTerminated { return false }
        guard let handState = playerHands.first else { return false }
        let hand = convert(hand: handState)
        switch action {
        case .double:
            return hand.cards.count == 2
        case .split:
            if !hand.canSplit { return false }
            if handState.splitDepth >= maxSplitDepth { return false }
            if hand.isSplitAce && !settings.resplitAces && handState.splitDepth > 0 { return false }
            return true
        case .surrender:
            return rules.surrenderAllowed && hand.cards.count == 2
        case .hit, .stand:
            return true
        }
    }

    private func label(for action: PlayerAction) -> String {
        switch action {
        case .hit: return "H"
        case .stand: return "S"
        case .double: return "D"
        case .split: return "P"
        case .surrender: return "R"
        }
    }

    private func actionTitle(for action: PlayerAction) -> String {
        switch action {
        case .hit: return "Hit"
        case .stand: return "Stand"
        case .double: return "Double"
        case .split: return "Split"
        case .surrender: return "Surrender"
        }
    }

    private var sessionProfitView: some View {
        VStack(spacing: 6) {
            Text("Session Profit")
                .font(.headline)
            Text(String(format: "$%.2f", sessionProfit))
                .font(.title2.weight(.semibold))
                .foregroundColor(sessionProfit >= 0 ? .green : .red)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
    }

    private func modalOverlay<Content: View>(scale: CGFloat = 1, @ViewBuilder content: () -> Content) -> some View {
        Color.black.opacity(0.35)
            .ignoresSafeArea()
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .overlay(
                content()
                    .frame(maxWidth: 360 * scale)
                    .padding(12 * scale)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16 * scale, style: .continuous))
                    .padding(12 * scale)
            )
    }

    private var runningCountPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's the running count?")
                .font(.headline)
            TextField("Enter count", text: $runningCountGuess)
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
            Button("Submit") {
                submitRunningCount()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func discardTray(scale: CGFloat, expandedWidth: CGFloat) -> some View {
        Image(discardAssetName)
            .resizable()
            .scaledToFit()
            .frame(width: trayWidth(for: scale))
            .onTapGesture { showTrayExpanded = true }
            .contextMenu {
                Image(discardAssetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: max(expandedWidth * 0.6, 220))
            }
    }

    private func dealerSection(scale: CGFloat) -> some View {
        VStack(alignment: .center, spacing: 6) {
            Text("Dealer")
                .font(.headline)
            HStack(spacing: 8 * scale) {
                ForEach(dealerCards) { card in
                    SpeedCounterCardView(card: card)
                        .frame(width: cardWidth(for: scale))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func playerHandView(_ hand: SpeedCounterHandState, scale: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(Array(hand.cards.enumerated()), id: \.offset) { index, card in
                SpeedCounterCardView(card: card)
                    .frame(width: cardWidth(for: scale))
                    .offset(x: CGFloat(index) * cardOffsetX(for: scale), y: CGFloat(-index) * cardOffsetY(for: scale))
            }

            if let doubleCard = hand.doubleCard {
                SpeedCounterCardView(card: doubleCard)
                    .frame(width: cardWidth(for: scale))
                    .rotationEffect(.degrees(90))
                    .offset(
                        x: CGFloat(hand.cards.count) * cardOffsetX(for: scale) + 6 * scale,
                        y: CGFloat(-hand.cards.count) * cardOffsetY(for: scale)
                    )
            }
        }
        .frame(
            width: handWidth(hand, scale: scale),
            height: handHeight(hand, scale: scale),
            alignment: .bottomLeading
        )
    }

    private func totalHandsWidth(scale: CGFloat) -> CGFloat {
        guard !playerHands.isEmpty else { return cardWidth(for: scale) }
        let width = playerHands.reduce(0) { partial, hand in
            partial + handWidth(hand, scale: scale)
        }
        let spacingWidth = handSpacing(for: scale) * CGFloat(max(playerHands.count - 1, 0))
        return width + spacingWidth
    }

    private func handWidth(_ hand: SpeedCounterHandState, scale: CGFloat) -> CGFloat {
        let count = max(hand.cards.count, 1)
        var width = cardWidth(for: scale) + CGFloat(max(0, count - 1)) * cardOffsetX(for: scale)
        if hand.doubleCard != nil {
            width += cardWidth(for: scale) * 0.6
        }
        return width
    }

    private func maxHandHeight(scale: CGFloat) -> CGFloat {
        guard !playerHands.isEmpty else { return cardHeight(for: scale) }
        return playerHands.map { handHeight($0, scale: scale) }.max() ?? cardHeight(for: scale)
    }

    private func handHeight(_ hand: SpeedCounterHandState, scale: CGFloat) -> CGFloat {
        let count = max(hand.cards.count, 1)
        var height = cardHeight(for: scale) + CGFloat(max(0, count - 1)) * cardOffsetY(for: scale)
        if hand.doubleCard != nil {
            height = max(height, cardWidth(for: scale) + cardOffsetY(for: scale))
        }
        return height + cardTopBuffer(for: scale)
    }

    private func dispatchFailure(_ reason: TestOutFailureReason) {
        Task { @MainActor in
            triggerFailure(reason)
        }
    }

    @MainActor
    private func triggerFailure(_ reason: TestOutFailureReason) {
        guard isTestOutMode, !testOutTerminated else { return }
        testOutTerminated = true
        sessionLogged = true
        initialDealTask?.cancel()
        showRunningCountPrompt = false
        awaitingBet = false
        awaitingNextHand = false
        activeAlert = SimulationAlert(
            title: reason.title,
            message: reason.message,
            onDismiss: { handleFailureAcknowledgement(reason) }
        )
    }

    @MainActor
    private func handleFailureAcknowledgement(_ reason: TestOutFailureReason) {
        testOutConfig?.onFailure(reason)
        dismiss()
    }

    private func startShoe() {
        guard !testOutTerminated else { return }
        shoe = SpeedCounterCard.shoe(decks: rules.decks)
        cardsPlayed = 0
        runningCount = 0
        dealerCards = []
        playerHands = []
        currentBet = defaultBet()
        betFeedback = nil
        negativeChipMode = false
        handsSinceCountPrompt = 0
        currentShoePerfect = true
        shoesPlayed += 1
        awaitingNextHand = false
        lastHandProfit = nil
        prepareForBettingOrDeal()
    }

    private func advanceHand() {
        guard !testOutTerminated else { return }
        dealerCards = []
        playerHands = []
        currentBet = defaultBet()
        betFeedback = nil
        negativeChipMode = false
        awaitingNextHand = false
        lastHandProfit = nil
        let reshuffled = checkForReshuffle()
        if !reshuffled {
            prepareForBettingOrDeal()
        }
    }

    private func prepareForBettingOrDeal() {
        guard !testOutTerminated else { return }
        awaitingBet = bettingEnabled
        if bettingEnabled {
            return
        }
        autoDealWithoutBetting()
    }

    private func autoDealWithoutBetting() {
        guard !testOutTerminated else { return }
        currentBet = 0
        betFeedback = nil
        negativeChipMode = false
        awaitingBet = false
        dealInitialCards()
    }

    private func proceedToNextHand() {
        guard awaitingNextHand, !showRunningCountPrompt, !testOutTerminated else { return }
        advanceHand()
    }

    private func checkForReshuffle() -> Bool {
        let remainingFraction = Double(shoe.count) / Double(max(rules.decks * 52, 1))
        if remainingFraction < (1 - rules.penetration) || shoe.count < 20 {
            finalizeShoeIfNeeded()
            startShoe()
            return true
        }
        return false
    }

    private func finalizeShoeIfNeeded() {
        guard cardsPlayed > 0 else { return }
        if currentShoePerfect {
            perfectShoes += 1
            perfectStreak += 1
            longestPerfectStreak = max(longestPerfectStreak, perfectStreak)
        } else {
            perfectStreak = 0
        }
        currentShoePerfect = true
    }

    private func drawCard(faceDown: Bool = false) -> SpeedCounterDealtCard? {
        guard !shoe.isEmpty, !testOutTerminated else { return nil }
        let next = shoe.removeLast()
        cardsPlayed += 1
        if !faceDown {
            runningCount += next.hiLoValue
        }
        return SpeedCounterDealtCard(card: next, isFaceDown: faceDown, isPerpendicular: false)
    }

    private func dealInitialCards() {
        guard !testOutTerminated else { return }
        initialDealTask?.cancel()
        dealerCards = []
        playerHands = [SpeedCounterHandState(cards: [], doubleCard: nil, isSplitAce: false, splitDepth: 0)]

        initialDealTask = Task {
            await dealInitialCardsSequentially()
            await MainActor.run { initialDealTask = nil }
        }
    }

    private func dealInitialCardsSequentially() async {
        guard await dealCardToPlayerHand(0) != nil else { await restartAfterFailedDeal(); return }
        guard await dealCardToDealer(faceDown: true) != nil else { await restartAfterFailedDeal(); return }
        guard await dealCardToPlayerHand(0) != nil else { await restartAfterFailedDeal(); return }
        guard await dealCardToDealer(faceDown: false) != nil else { await restartAfterFailedDeal(); return }
        await handleDealerPeekIfNeeded()
    }

    private func restartAfterFailedDeal() async {
        await MainActor.run {
            initialDealTask = nil
            startShoe()
        }
    }

    private func dealCardToPlayerHand(_ index: Int) async -> SpeedCounterDealtCard? {
        guard !testOutTerminated else { return nil }
        guard let next = await MainActor.run(body: { drawCard() }) else { return nil }
        await MainActor.run {
            withAnimation(.easeInOut(duration: animationSpeed)) {
                playerHands[index].cards.append(next)
            }
        }
        await pauseBetweenDeals()
        return next
    }

    private func dealCardToDealer(faceDown: Bool) async -> SpeedCounterDealtCard? {
        guard !testOutTerminated else { return nil }
        guard let next = await MainActor.run(body: { drawCard(faceDown: faceDown) }) else { return nil }
        await MainActor.run {
            withAnimation(.easeInOut(duration: animationSpeed)) {
                dealerCards.append(next)
            }
        }
        await pauseBetweenDeals()
        return next
    }

    @MainActor
    private func pauseBetweenDeals() async {
        let delay = animationSpeed
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    private func convert(hand: SpeedCounterHandState) -> Hand {
        var cards = hand.cards.map { Card(rank: $0.card.rank) }
        if let double = hand.doubleCard {
            cards.append(Card(rank: double.card.rank))
        }
        return Hand(cards: cards, isSplitAce: hand.isSplitAce, fromSplit: hand.splitDepth > 0)
    }

    private func handleDealerPeekIfNeeded() async {
        guard !testOutTerminated else { return }

        let peekContext = await MainActor.run { () -> (Hand, Hand)? in
            guard let upCard = dealerUpCard else { return nil }
            let shouldPeek = upCard.rank == 1 || upCard.value == 10
            guard shouldPeek else { return nil }
            guard let playerHandState = playerHands.first else { return nil }
            let playerHand = convert(hand: playerHandState)
            let dealerHand = dealerHandModel()
            return (playerHand, dealerHand)
        }

        guard let (playerHand, dealerHand) = peekContext else { return }
        guard dealerHand.isBlackjack else { return }

        await MainActor.run {
            revealHoleCardIfNeeded()
        }

        let playerHasBlackjack = playerHand.isBlackjack && !playerHand.fromSplit
        let profit = playerHasBlackjack ? 0 : -currentBet
        await finishHand(with: profit)
    }

    private func advisedAction(for hand: Hand, dealerUp: Card) -> PlayerAction {
        StrategyAdvisor.baseAction(for: hand, dealerUp: dealerUp, rules: rules)
    }

    private func applyChip(_ chip: ChipOption) {
        guard chipsEnabled else { return }
        let delta = Double(chip.value) * (negativeChipMode ? -1 : 1)
        currentBet = max(0, currentBet + delta)
    }

    private func chipLabel(for chip: ChipOption) -> String {
        let sign = negativeChipMode ? "-" : ""
        return "\(sign)$\(chip.value)"
    }

    private func submitBetAndDeal() {
        guard awaitingBet, !testOutTerminated else { return }
        let evaluation = betEvaluation(for: currentBet)
        if isTestOutMode && !evaluation.isWithinRange {
            dispatchFailure(
                .betting(
                    expectedRange: evaluation.rangeLabel,
                    trueCountLabel: evaluation.tcLabel,
                    actualBet: Int(currentBet)
                )
            )
            return
        }
        recordDecision(correct: evaluation.isWithinRange)
        betFeedback = evaluation.isWithinRange ? nil : BetFeedback(message: evaluation.feedback, isError: true)

        if !evaluation.isWithinRange {
            currentShoePerfect = false
            activeAlert = SimulationAlert(
                title: "Bet Correction",
                message: evaluation.feedback,
                onDismiss: nil
            )
        }

        awaitingBet = false
        dealInitialCards()
    }

    private func betEvaluation(for bet: Double) -> (isWithinRange: Bool, feedback: String, rangeLabel: String, tcLabel: String) {
        let tc = trueCount
        let lower = Int(floor(tc))
        let upper = Int(ceil(tc))
        let lowerBet = settings.betTable.value(for: lower)
        let upperBet = settings.betTable.value(for: upper)
        let minAccepted = isTestOutMode ? 0 : min(lowerBet, upperBet)
        let maxAccepted = max(lowerBet, upperBet)
        let correctRange = bet >= minAccepted && bet <= maxAccepted

        let rangeLabel = "$\(Int(minAccepted))–$\(Int(maxAccepted))"
        let tcLabel = String(format: "%.2f", tc)
        let feedback: String
        if correctRange {
            feedback = "Nice bet. True count \(tcLabel) supports \(rangeLabel)."
        } else {
            feedback = "Recommended bet for true count \(tcLabel) is \(rangeLabel)."
        }

        return (correctRange, feedback, rangeLabel, tcLabel)
    }

    private func handleAction(_ action: PlayerAction) {
        Task {
            guard await MainActor.run(body: { !awaitingBet && !awaitingNextHand && !testOutTerminated }) else { return }
            guard let recommended = await MainActor.run(body: { recommendedAction }) else {
                await MainActor.run {
                    activeAlert = SimulationAlert(
                        title: "Strategy Correction",
                        message: "Finish dealing the hand before choosing an action.",
                        onDismiss: nil
                    )
                }
                return
            }
            let correct = action == recommended
            if isTestOutMode && !correct {
                dispatchFailure(.basicStrategy(expected: actionTitle(for: recommended)))
                return
            }
            await MainActor.run {
                recordDecision(correct: correct)
                if !correct {
                    currentShoePerfect = false
                }
            }
            let correctionMessage = correct ? nil : "Basic strategy recommends \(actionTitle(for: recommended))."
            await resolveCurrentHand(with: action, correctionMessage: correctionMessage)
        }
    }

    private func resolveCurrentHand(with action: PlayerAction, correctionMessage: String? = nil) async {
        guard !testOutTerminated else { return }
        guard var handState = await MainActor.run(body: { playerHands.first }),
              let dealerUp = await MainActor.run(body: { dealerUpCard }) else { return }
        var dealerHand = await MainActor.run(body: { dealerHandModel() })
        var profit: Double = 0
        var handFinished = false

        switch action {
        case .surrender:
            await pauseBeforeDealerHand()
            dealerHand = await MainActor.run(body: { revealDealerHand() })
            profit = await MainActor.run(body: { -currentBet / 2.0 })
            handFinished = true
        case .stand:
            await pauseBeforeDealerHand()
            dealerHand = await MainActor.run(body: { revealDealerHand() })
            await dealerPlay(&dealerHand)
            profit = await MainActor.run(body: { settle(hand: convert(hand: handState), dealerHand: dealerHand, bet: currentBet) })
            handFinished = true
        case .double:
            if let newCard = await MainActor.run(body: { drawCard() }) {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: animationSpeed)) {
                        handState.doubleCard = newCard
                        playerHands[0] = handState
                    }
                }
            }
            await pauseBeforeDealerHand()
            dealerHand = await MainActor.run(body: { revealDealerHand() })
            await dealerPlay(&dealerHand)
            profit = await MainActor.run(body: { settle(hand: convert(hand: handState), dealerHand: dealerHand, bet: currentBet * 2) })
            handFinished = true
        case .hit:
            if let newCard = await MainActor.run(body: { drawCard() }) {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: animationSpeed)) {
                        playerHands[0].cards.append(newCard)
                    }
                    handState = playerHands[0]
                }
            }
            let model = await MainActor.run(body: { convert(hand: handState) })
            if model.isBusted {
                await pauseBeforeDealerHand()
                await MainActor.run(body: { revealHoleCardIfNeeded() })
                profit = -currentBet
                handFinished = true
            } else if model.bestValue >= 21 {
                await pauseBeforeDealerHand()
                dealerHand = await MainActor.run(body: { revealDealerHand() })
                await dealerPlay(&dealerHand)
                profit = await MainActor.run(body: { settle(hand: model, dealerHand: dealerHand, bet: currentBet) })
                handFinished = true
            }
        case .split:
            profit = await resolveSplitHands(initial: handState, dealerUp: dealerUp)
            handFinished = true
        }

        if let correctionMessage {
            await MainActor.run {
                activeAlert = SimulationAlert(
                    title: "Strategy Correction",
                    message: correctionMessage,
                    onDismiss: nil
                )
            }
        }

        if handFinished {
            await finishHand(with: profit)
        }
    }

    @MainActor
    private func resolveSplitHands(initial: SpeedCounterHandState, dealerUp: Card) async -> Double {
        guard !testOutTerminated else { return 0 }
        guard initial.cards.count == 2 else { return 0 }

        let first = initial.cards[0]
        let second = initial.cards[1]

        var handsToPlay: [SpeedCounterHandState] = []

        let left = SpeedCounterHandState(cards: [first], doubleCard: nil, isSplitAce: first.card.rank == 1, splitDepth: initial.splitDepth + 1)
        let right = SpeedCounterHandState(cards: [second], doubleCard: nil, isSplitAce: second.card.rank == 1, splitDepth: initial.splitDepth + 1)
        handsToPlay.append(left)
        handsToPlay.append(right)

        playerHands = handsToPlay

        for index in playerHands.indices {
            if let extra = drawCard() {
                withAnimation(.easeInOut(duration: animationSpeed)) {
                    playerHands[index].cards.append(extra)
                }
            }
        }

        var outcomes: [(Hand, Double)] = []

        for index in playerHands.indices {
            var model = convert(hand: playerHands[index])
            var bet = currentBet

            if model.isSplitAce {
                // One card only on split aces
            } else {
                while true {
                    if model.isBusted { break }
                    let action = advisedAction(for: model, dealerUp: dealerUp)
                    if action == .double && model.cards.count == 2 {
                        if let newCard = drawCard() {
                            withAnimation(.easeInOut(duration: animationSpeed)) {
                                playerHands[index].doubleCard = newCard
                            }
                            model.cards.append(Card(rank: newCard.card.rank))
                            bet *= 2
                        }
                        break
                    } else if action == .hit {
                        if let newCard = drawCard() {
                            withAnimation(.easeInOut(duration: animationSpeed)) {
                                playerHands[index].cards.append(newCard)
                            }
                            model.cards.append(Card(rank: newCard.card.rank))
                        } else {
                            break
                        }
                    } else {
                        break
                    }
                }
            }

            outcomes.append((model, bet))
        }

        await pauseBeforeDealerHand()
        revealHoleCardIfNeeded()
        var dealerHandCopy = dealerHandModel()
        let hasLiveHand = outcomes.contains { !$0.0.isBusted }
        if hasLiveHand {
            await dealerPlay(&dealerHandCopy)
        }

        var profit: Double = 0
        for outcome in outcomes {
            if outcome.0.isBusted {
                profit -= outcome.1
            } else {
                profit += settle(hand: outcome.0, dealerHand: dealerHandCopy, bet: outcome.1)
            }
        }
        return profit
    }

    private func dealerHandModel() -> Hand {
        Hand(cards: dealerCards.map { Card(rank: $0.card.rank) })
    }

    @MainActor
    private func pauseBeforeDealerHand() async {
        await pauseBetweenDeals()
    }

    private func revealDealerHand() -> Hand {
        revealHoleCardIfNeeded()
        return dealerHandModel()
    }

    @MainActor
    private func finishHand(with profit: Double) async {
        revealHoleCardIfNeeded()
        sessionProfit += profit
        lastHandProfit = profit
        handsCompleted += 1
        handsSinceCountPrompt += 1

        if settings.askRunningCount && handsSinceCountPrompt >= settings.runningCountCadence {
            showRunningCountPrompt = true
            runningCountGuess = ""
            handsSinceCountPrompt = 0
        }

        await pauseBetweenDeals()
        awaitingNextHand = true
    }

    private func revealHoleCardIfNeeded() {
        if let index = dealerCards.firstIndex(where: { $0.isFaceDown }) {
            dealerCards[index].isFaceDown = false
            runningCount += dealerCards[index].card.hiLoValue
        }
    }

    @MainActor
    private func dealerPlay(_ hand: inout Hand) async {
        guard !testOutTerminated else { return }
        while true {
            let value = hand.bestValue
            let soft = hand.isSoft
            if value < 17 || (value == 17 && rules.dealerHitsSoft17 && soft) {
                guard let newCard = drawCard() else { break }
                withAnimation(.easeInOut(duration: animationSpeed)) {
                    hand.cards.append(Card(rank: newCard.card.rank))
                    dealerCards.append(newCard)
                }
                await pauseBetweenDeals()
            } else {
                break
            }
        }
    }

    private func settle(hand: Hand, dealerHand: Hand, bet: Double) -> Double {
        if hand.isBusted { return -bet }
        if hand.cards.count == 2 && hand.isBlackjack && !hand.fromSplit {
            return bet * rules.blackjackPayout
        }
        var dealerHand = dealerHand
        revealHoleCardIfNeeded()
        if dealerHand.isBlackjack {
            if hand.isBlackjack && !hand.fromSplit { return 0 }
            return -bet
        }
        if dealerHand.isBusted { return bet }
        if hand.bestValue > dealerHand.bestValue { return bet }
        if hand.bestValue < dealerHand.bestValue { return -bet }
        return 0
    }

    private func recordDecision(correct: Bool) {
        guard !testOutTerminated else { return }
        decisions += 1
        if correct {
            correctDecisions += 1
            currentStreak += 1
            longestStreak = max(longestStreak, currentStreak)
        } else {
            currentShoePerfect = false
            currentStreak = 0
        }
    }

    private func submitRunningCount() {
        let trimmedGuess = runningCountGuess.trimmingCharacters(in: .whitespacesAndNewlines)
        let guess = Int(trimmedGuess)
        let difference = guess.map { abs($0 - runningCount) } ?? Int.max
        if isTestOutMode && difference > 1 {
            dispatchFailure(.runningCount(expected: runningCount, guess: trimmedGuess.isEmpty ? "No answer" : trimmedGuess))
            return
        }
        let correct = guess == runningCount
        recordDecision(correct: correct)

        let message: String
        if correct {
            message = "Correct! Running count is \(runningCount)."
        } else {
            currentShoePerfect = false
            if let guess {
                message = "You answered \(guess). Running count is \(runningCount)."
            } else if trimmedGuess.isEmpty {
                message = "Running count is \(runningCount)."
            } else {
                message = "\"\(trimmedGuess)\" isn't a valid number. Running count is \(runningCount)."
            }
        }

        activeAlert = SimulationAlert(
            title: "Running Count",
            message: message,
            onDismiss: { showRunningCountPrompt = false }
        )
    }

    private func completeSession() {
        finalizeShoeIfNeeded()
        guard !sessionLogged else { return }
        if isTestOutMode {
            sessionLogged = true
            dismiss()
            return
        }
        let session = HandSimulationSession(
            date: Date(),
            correctDecisions: correctDecisions,
            totalDecisions: decisions,
            longestStreak: longestStreak,
            shoesPlayed: shoesPlayed,
            perfectShoes: perfectShoes,
            longestPerfectShoeStreak: longestPerfectStreak
        )
        sessionLogged = true
        onComplete(session)
        dismiss()
    }
}

// MARK: - Test Out

struct TestOutView: View {
    @State private var allowSurrender: Bool = true
    @State private var currentRunID: UUID = UUID()
    @State private var navigateToRun: Bool = false
    @State private var failureReason: TestOutFailureReason?

    private let betTable = BetSizingTable.testOutDefault

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Put everything together in one high-stakes drill. Any basic strategy mistake, off-target bet, or big counting miss will end the test.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                ruleSummary

                Toggle("Allow Surrender", isOn: $allowSurrender)
                    .toggleStyle(SwitchToggleStyle(tint: .accentColor))

                BetSizingTableView(betTable: betTable, isEditable: false, title: "True Count / Bet Spread")

                Button(action: startTestOut) {
                    Text("Start Test Out")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            .padding()
        }
        .navigationTitle("Test Out")
        .navigationBarTitleDisplayMode(.inline)
        .background(navigationLinks)
    }

    private var ruleSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Test Settings")
                .font(.headline)
            Label("6 decks, dealer hits soft 17", systemImage: "rectangle.stack.badge.person.crop")
            Label("Penetration set to 80%", systemImage: "slider.horizontal.3")
            Label("Re-splitting aces disabled", systemImage: "nosign")
            Label("Running count every 3 hands", systemImage: "number")
            Label("Random dealing speed each attempt", systemImage: "shuffle")
            Label("Bet spread: $25 at TC 0, then $100 per TC", systemImage: "dollarsign.arrow.circlepath")
        }
        .font(.subheadline)
        .foregroundColor(.secondary)
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(12)
    }

    private var navigationLinks: some View {
        Group {
            NavigationLink(isActive: $navigateToRun) {
                TestOutRunView(
                    surrenderAllowed: allowSurrender,
                    runID: currentRunID,
                    onFailure: handleFailure
                )
            } label: {
                EmptyView()
            }
            .hidden()

            NavigationLink(
                isActive: Binding(
                    get: { failureReason != nil },
                    set: { isActive in
                        if !isActive { failureReason = nil }
                    }
                )
            ) {
                if let reason = failureReason {
                    TestOutFailureView(
                        reason: reason,
                        onRetry: startTestOut,
                        onExit: resetToStart
                    )
                } else {
                    EmptyView()
                }
            } label: {
                EmptyView()
            }
            .hidden()
        }
    }

    private func startTestOut() {
        currentRunID = UUID()
        failureReason = nil
        navigateToRun = true
    }

    private func handleFailure(_ reason: TestOutFailureReason) {
        navigateToRun = false
        failureReason = reason
    }

    private func resetToStart() {
        currentRunID = UUID()
        failureReason = nil
        navigateToRun = false
    }
}

struct TestOutRunView: View {
    let surrenderAllowed: Bool
    let runID: UUID
    let onFailure: (TestOutFailureReason) -> Void

    @State private var sessionSettings: HandSimulationSettings?

    private var configuredSettings: HandSimulationSettings {
        var base = HandSimulationSettings()
        base.rules = GameRules(
            decks: 6,
            dealerHitsSoft17: true,
            doubleAfterSplit: true,
            surrenderAllowed: surrenderAllowed,
            blackjackPayout: 1.5,
            penetration: 0.8
        )
        base.resplitAces = false
        base.bettingEnabled = true
        base.askRunningCount = true
        base.runningCountCadence = 3
        base.betTable = .testOutDefault
        base.dealSpeed = Double.random(in: 0.25...0.9)
        return base
    }

    var body: some View {
        HandSimulationRunView(
            settings: sessionSettings ?? configuredSettings,
            onComplete: { _ in },
            navigationTitle: "Test Out",
            endActionLabel: "End Test",
            testOutConfig: TestOutConfiguration(onFailure: { reason in
                DispatchQueue.main.async {
                    onFailure(reason)
                }
            })
        )
        .id(runID)
        .navigationBarBackButtonHidden(false)
        .onAppear {
            if sessionSettings == nil {
                sessionSettings = configuredSettings
            }
        }
    }
}

struct TestOutFailureView: View {
    let reason: TestOutFailureReason
    let onRetry: () -> Void
    let onExit: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 56))
                .foregroundColor(.red)
            Text(reason.title)
                .font(.title2.weight(.semibold))
            Text(reason.message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            VStack(spacing: 12) {
                Button(action: onRetry) {
                    Text("Retry")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onExit) {
                    Text("Back to Training Suite")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            Spacer()
        }
        .padding()
        .navigationBarBackButtonHidden(true)
    }
}

struct TrainingCard: Identifiable, Equatable, Hashable {
    enum Rank: Int, CaseIterable {
        case ace = 1, two, three, four, five, six, seven, eight, nine, ten, jack, queen, king

        var label: String {
            switch self {
            case .ace: return "A"
            case .jack: return "J"
            case .queen: return "Q"
            case .king: return "K"
            default: return String(rawValue)
            }
        }
    }

    enum Suit: CaseIterable {
        case spades, hearts, clubs, diamonds

        var symbol: String {
            switch self {
            case .spades: return "♠︎"
            case .hearts: return "♥︎"
            case .clubs: return "♣︎"
            case .diamonds: return "♦︎"
            }
        }

        var assetName: String {
            switch self {
            case .spades: return "spades"
            case .hearts: return "hearts"
            case .clubs: return "clubs"
            case .diamonds: return "diamonds"
            }
        }
    }

    enum Category: String {
        case low = "Low (2-6)"
        case neutral = "Neutral (7-9)"
        case high = "High (10-A)"
    }

    let id = UUID()
    let rank: Rank
    let suit: Suit

    var display: String { "\(rank.label)\(suit.symbol)" }

    var category: Category {
        switch rank {
        case .two, .three, .four, .five, .six:
            return .low
        case .seven, .eight, .nine:
            return .neutral
        default:
            return .high
        }
    }

    static func fullDeck() -> [TrainingCard] {
        Suit.allCases.flatMap { suit in
            Rank.allCases.map { rank in
                TrainingCard(rank: rank, suit: suit)
            }
        }
    }
}


struct CardIconView: View {
    struct PipPlacement: Identifiable {
        let id = UUID()
        let x: CGFloat
        let y: CGFloat
        let flipped: Bool
    }

    struct Metrics {
        let cardSize: CGSize

        var base: CGFloat { min(cardSize.width, cardSize.height) }
        var cornerPadding: CGFloat { cardSize.width * 0.07 }
        var rankFontSize: CGFloat { cardSize.height * 0.18 }
        var suitFontSize: CGFloat { cardSize.height * 0.135 }
        var accentSuitSize: CGFloat { cardSize.height * 0.21 }
        var pipFontSize: CGFloat { cardSize.height * 0.155 }

        var interiorSize: CGSize { CGSize(width: cardSize.width * 0.82, height: cardSize.height * 0.74) }
        var cornerRadius: CGFloat { base * 0.16 }
    }

    let card: TrainingCard

    private var cardColor: Color {
        switch card.suit {
        case .hearts, .diamonds:
            return .red
        default:
            return .primary
        }
    }

    private var cardAssetName: String {
        "card_\(card.suit.assetName)_\(card.rank.label)"
    }

    private var cardAssetImage: Image? {
        #if canImport(UIKit)
        if UIImage(named: cardAssetName) != nil {
            return Image(cardAssetName)
        }
        #endif
        return nil
    }

    var body: some View {
        Group {
            if let assetImage = cardAssetImage {
                assetImage
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 4)
            } else {
                drawnCard
            }
        }
        .frame(minWidth: 88, minHeight: 125)
        .aspectRatio(2.5/3.5, contentMode: .fit)
    }

    private var drawnCard: some View {
        GeometryReader { proxy in
            let metrics = Metrics(cardSize: proxy.size)

            ZStack {
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 4)
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: proxy.size.height * 0.008) {
                    Text(card.rank.label)
                        .font(.system(size: metrics.rankFontSize, weight: .bold, design: .rounded))
                        .foregroundColor(cardColor)
                    Text(card.suit.symbol)
                        .font(.system(size: metrics.suitFontSize))
                        .foregroundColor(cardColor)
                        .rotationEffect(.degrees(180))
                }
                .padding([.top, .leading], metrics.cornerPadding)
            }
            .overlay(alignment: .bottomTrailing) {
                VStack(alignment: .trailing, spacing: proxy.size.height * 0.008) {
                    Text(card.rank.label)
                        .font(.system(size: metrics.rankFontSize, weight: .bold, design: .rounded))
                        .foregroundColor(cardColor)
                        .rotationEffect(.degrees(180))
                    Text(card.suit.symbol)
                        .font(.system(size: metrics.suitFontSize))
                        .foregroundColor(cardColor)
                        .rotationEffect(.degrees(180))
                }
                .padding([.trailing, .bottom], metrics.cornerPadding)
            }
            .overlay(alignment: .topTrailing) {
                Text(card.suit.symbol)
                    .font(.system(size: metrics.accentSuitSize))
                    .foregroundColor(cardColor)
                    .padding([.top, .trailing], metrics.cornerPadding)
            }
            .overlay(alignment: .bottomLeading) {
                Text(card.suit.symbol)
                    .font(.system(size: metrics.accentSuitSize))
                    .foregroundColor(cardColor)
                    .rotationEffect(.degrees(180))
                    .padding([.leading, .bottom], metrics.cornerPadding)
            }
            .overlay {
                ZStack {
                    if pipPlacements.isEmpty {
                        FaceCardArtworkView(rank: card.rank, suit: card.suit, color: cardColor)
                            .frame(width: metrics.interiorSize.width, height: metrics.interiorSize.height)
                    } else {
                        GeometryReader { pipProxy in
                            ForEach(pipPlacements) { placement in
                                Text(card.suit.symbol)
                                    .font(.system(size: metrics.pipFontSize, weight: .semibold))
                                    .foregroundColor(cardColor)
                                    .rotationEffect(placement.flipped ? .degrees(180) : .degrees(0))
                                    .position(
                                        x: placement.x * pipProxy.size.width,
                                        y: placement.y * pipProxy.size.height
                                    )
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        }
                        .frame(width: metrics.interiorSize.width, height: metrics.interiorSize.height)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var pipPlacements: [PipPlacement] {
        // Ratios mirror the referenced 2.5x3.5 layout so pips stay centered as the card scales
        let left: CGFloat = 0.24
        let right: CGFloat = 0.76
        let centerX: CGFloat = 0.5

        let top: CGFloat = 0.12
        let upper: CGFloat = 0.27
        let upperMid: CGFloat = 0.38
        let middle: CGFloat = 0.50
        let lowerMid: CGFloat = 0.62
        let lower: CGFloat = 0.73
        let bottom: CGFloat = 0.88

        func placement(_ x: CGFloat, _ y: CGFloat) -> PipPlacement {
            PipPlacement(x: x, y: y, flipped: y > middle)
        }

        switch card.rank {
        case .ace:
            return [placement(centerX, middle)]
        case .two:
            return [placement(centerX, top), placement(centerX, bottom)]
        case .three:
            return [placement(centerX, top), placement(centerX, middle), placement(centerX, bottom)]
        case .four:
            return [placement(left, top), placement(right, top), placement(left, bottom), placement(right, bottom)]
        case .five:
            return [placement(left, top), placement(right, top), placement(centerX, middle), placement(left, bottom), placement(right, bottom)]
        case .six:
            return [
                placement(left, top), placement(right, top),
                placement(left, lower), placement(right, lower),
                placement(left, bottom), placement(right, bottom)
            ]
        case .seven:
            return [
                placement(centerX, middle),
                placement(left, top), placement(right, top),
                placement(left, lower), placement(right, lower),
                placement(left, bottom), placement(right, bottom)
            ]
        case .eight:
            return [
                placement(centerX, upperMid), placement(centerX, lowerMid),
                placement(left, top), placement(right, top),
                placement(left, lower), placement(right, lower),
                placement(left, bottom), placement(right, bottom)
            ]
        case .nine:
            return [
                placement(centerX, middle),
                placement(centerX, upperMid), placement(centerX, lowerMid),
                placement(left, top), placement(right, top),
                placement(left, lower), placement(right, lower),
                placement(left, bottom), placement(right, bottom)
            ]
        case .ten:
            return [
                placement(left, top), placement(right, top),
                placement(left, upper), placement(right, upper),
                placement(left, middle), placement(right, middle),
                placement(left, lower), placement(right, lower),
                placement(left, bottom), placement(right, bottom)
            ]
        case .jack, .queen, .king:
            return []
        }
    }
}
struct FaceCardArtworkView: View {
    let rank: TrainingCard.Rank
    let suit: TrainingCard.Suit
    let color: Color

    private struct FaceCardMetrics {
        let edge: CGFloat
        let frameCorner: CGFloat
        let borderWidth: CGFloat
        let dividerHeight: CGFloat
        let portraitHeight: CGFloat
        let suitIconSize: CGFloat
        let labelFontSize: CGFloat
        let horizontalPadding: CGFloat
        let verticalStackSpacing: CGFloat
        let contentPadding: CGFloat

        init(proxy: GeometryProxy) {
            edge = min(proxy.size.width, proxy.size.height)
            frameCorner = edge * 0.08
            borderWidth = edge * 0.025
            dividerHeight = edge * 0.035
            portraitHeight = edge * 0.48
            suitIconSize = edge * 0.08
            labelFontSize = edge * 0.12
            horizontalPadding = edge * 0.1
            verticalStackSpacing = edge * 0.05
            contentPadding = edge * 0.08
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = FaceCardMetrics(proxy: proxy)

            ZStack {
                RoundedRectangle(cornerRadius: metrics.frameCorner, style: .continuous)
                    .fill(Color.white)
                RoundedRectangle(cornerRadius: metrics.frameCorner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: metrics.borderWidth)

                VStack(spacing: metrics.verticalStackSpacing) {
                    portraitArtwork(metrics: metrics)

                    Rectangle()
                        .fill(color.opacity(0.12))
                        .frame(height: metrics.dividerHeight)
                        .overlay(
                            HStack(spacing: metrics.edge * 0.06) {
                                  suitIcon(iconSize: metrics.suitIconSize)
                                Spacer()
                                Text(rank.label)
                                    .font(.system(size: metrics.labelFontSize, weight: .black, design: .rounded))
                                    .foregroundColor(color)
                                Spacer()
                                  suitIcon(iconSize: metrics.suitIconSize)
                            }
                            .padding(.horizontal, metrics.horizontalPadding)
                        )

                    portraitArtwork(metrics: metrics)
                        .rotationEffect(.degrees(180))
                }
                .padding(metrics.contentPadding)
            }
        }
    }

    @ViewBuilder
    private func portraitArtwork(metrics: FaceCardMetrics) -> some View {
        let height = metrics.portraitHeight
        let cornerRadius = height * 0.12
        let strokeWidth = height * 0.022
        let headSize = height * 0.3
        let torsoHeight = height * 0.22
        let shoulderWidth = height * 0.55

        let gradient = LinearGradient(
            colors: [color.opacity(0.2), color.opacity(0.05)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(gradient)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(color.opacity(0.4), lineWidth: strokeWidth)

            VStack(spacing: height * 0.06) {
                crownRow(height: height)

                ZStack {
                    Capsule()
                        .fill(color.opacity(0.18))
                        .frame(width: shoulderWidth, height: torsoHeight)
                        .overlay(
                            Capsule()
                                .strokeBorder(color.opacity(0.45), lineWidth: strokeWidth * 0.7)
                        )

                    VStack(spacing: height * 0.03) {
                        faceLayer(headSize: headSize)

                        HStack(spacing: height * 0.04) {
                            suitIcon(iconSize: height * 0.08)
                            decorativeBand(height: height * 0.05)
                            suitIcon(iconSize: height * 0.08)
                        }
                    }
                    .padding(.horizontal, height * 0.14)
                }

                bannerRow(height: height)
            }
            .padding(height * 0.1)
        }
        .frame(height: height)
    }

    private func suitIcon(iconSize: CGFloat) -> some View {
        Text(suit.symbol)
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundColor(color)
            .minimumScaleFactor(0.1)
    }

    private func faceLayer(headSize: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: headSize, height: headSize)
                .overlay(
                    Circle()
                        .stroke(color.opacity(0.4), lineWidth: headSize * 0.06)
                )

            VStack(spacing: headSize * 0.04) {
                HStack(spacing: headSize * 0.16) {
                    eye(diameter: headSize * 0.12)
                    eye(diameter: headSize * 0.12)
                }

                Rectangle()
                    .fill(color.opacity(0.6))
                    .frame(width: headSize * 0.32, height: headSize * 0.08)
                    .cornerRadius(headSize * 0.04)
            }

            if rank != .jack {
                Image(systemName: "crown.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: headSize * 0.8)
                    .foregroundStyle(color.opacity(0.9))
                    .offset(y: -headSize * 0.78)
                    .shadow(color: color.opacity(0.35), radius: headSize * 0.1, x: 0, y: headSize * 0.05)
            } else {
                Image(systemName: "figure.stand")
                    .resizable()
                    .scaledToFit()
                    .frame(height: headSize * 0.7)
                    .foregroundColor(color.opacity(0.85))
                    .offset(y: -headSize * 0.2)
            }
        }
    }

    private func eye(diameter: CGFloat) -> some View {
        Circle()
            .fill(color.opacity(0.8))
            .frame(width: diameter, height: diameter)
            .overlay(
                Circle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: diameter * 0.35, height: diameter * 0.35)
                    .offset(x: diameter * 0.12, y: diameter * 0.1)
            )
    }

    private func decorativeBand(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(color.opacity(0.45))
            .frame(width: height * 5, height: height)
            .overlay(
                HStack(spacing: height * 0.6) {
                    ForEach(0..<3, id: \.self) { _ in
                          suitIcon(iconSize: height * 0.8)
                    }
                }
            )
    }

    private func crownRow(height: CGFloat) -> some View {
        HStack(spacing: height * 0.14) {
            suitIcon(iconSize: height * 0.08)
            Image(systemName: rank == .jack ? "person.fill" : "crown.fill")
                .resizable()
                .scaledToFit()
                .frame(height: height * 0.18)
                .foregroundStyle(color)
            suitIcon(iconSize: height * 0.08)
        }
        .frame(height: height)
    }

    private func bannerRow(height: CGFloat) -> some View {
        HStack(spacing: height * 0.08) {
            suitIcon(iconSize: height * 0.09)

            VStack(spacing: height * 0.01) {
                Text(rank.label)
                    .font(.system(size: height * 0.16, weight: .black, design: .rounded))
                Text(suit.symbol)
                    .font(.system(size: height * 0.16, weight: .bold, design: .rounded))
            }
            .foregroundColor(color)

            suitIcon(iconSize: height * 0.09)
        }
    }

}

struct CardSortingAttemptEntry: Identifiable, Codable {
    let id: UUID
    let date: Date
    let correct: Bool
    let decisionTime: TimeInterval?

    init(date: Date, correct: Bool, decisionTime: TimeInterval?) {
        id = UUID()
        self.date = date
        self.correct = correct
        self.decisionTime = decisionTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        correct = try container.decode(Bool.self, forKey: .correct)
        decisionTime = try container.decodeIfPresent(TimeInterval.self, forKey: .decisionTime)
    }
}

struct CardSortingStats {
    let totalAttempts: Int
    let correctAttempts: Int
    let longestStreak: Int
    let averageDecisionTime: Double?

    var accuracy: Double? {
        guard totalAttempts > 0 else { return nil }
        return Double(correctAttempts) / Double(totalAttempts)
    }

    static func make(for attempts: [CardSortingAttemptEntry]) -> CardSortingStats {
        let ordered = attempts.sorted { $0.date < $1.date }
        var correctCount = 0
        var streak = 0
        var bestStreak = 0
        var decisionTimes: [Double] = []

        for attempt in ordered {
            if attempt.correct {
                correctCount += 1
                streak += 1
                bestStreak = max(bestStreak, streak)
            } else {
                streak = 0
            }

            if let duration = attempt.decisionTime {
                decisionTimes.append(duration)
            }
        }

        return CardSortingStats(
            totalAttempts: ordered.count,
            correctAttempts: correctCount,
            longestStreak: bestStreak,
            averageDecisionTime: decisionTimes.isEmpty ? nil : decisionTimes.reduce(0, +) / Double(decisionTimes.count)
        )
    }
}

struct CardSortingView: View {
    @AppStorage("cardSortingAttempts") private var storedAttempts: Data = Data()

    @State private var showIntro = true
    @State private var currentCard: TrainingCard = TrainingCard.fullDeck().randomElement() ?? TrainingCard(rank: .ace, suit: .spades)
    @State private var dragOffset: CGSize = .zero
    @State private var feedback: String?
    @State private var feedbackIsPositive: Bool = true
    @State private var currentStreak: Int = 0
    @State private var bestSessionStreak: Int = 0
    @State private var attemptsThisSession: Int = 0
    @State private var correctThisSession: Int = 0
    @State private var cardShownAt: Date = Date()

    private var attempts: [CardSortingAttemptEntry] {
        (try? JSONDecoder().decode([CardSortingAttemptEntry].self, from: storedAttempts)) ?? []
    }

    private var lastWeekAttempts: [CardSortingAttemptEntry] {
        guard let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return [] }
        return attempts.filter { $0.date >= weekAgo }
    }

    private var overallStats: CardSortingStats { .make(for: attempts) }
    private var weeklyStats: CardSortingStats { .make(for: lastWeekAttempts) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if showIntro {
                    introView
                } else {
                    gameView
                }

                CardSortingStatsSummary(overall: overallStats, weekly: weeklyStats)
            }
            .padding()
        }
        .navigationTitle("Card Sorting")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !showIntro {
                cardShownAt = Date()
            }
        }
    }

    private var introView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How it works")
                .font(.title3.weight(.semibold))
            Text("Swipe like Tinder: left for **Low (2–6)**, right for **High (10–A)**, and up for **Neutral (7–9)**. Build a long streak by tagging cards correctly.")
                .fixedSize(horizontal: false, vertical: true)
            Text("You can play as long as you like. Every swipe is saved so you can review accuracy and streaks over time.")
                .foregroundColor(.secondary)
            Button {
                withAnimation {
                    showIntro = false
                    cardShownAt = Date()
                }
            } label: {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var gameView: some View {
        VStack(spacing: 16) {
            Text("Swipe the card: left = Low, right = High, up = Neutral.")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundColor(.secondary)

            ZStack {
                CardIconView(card: currentCard)
                    .offset(dragOffset)
                    .rotationEffect(.degrees(Double(dragOffset.width / 12)))
                    .gesture(
                        DragGesture()
                            .onChanged { gesture in
                                dragOffset = gesture.translation
                            }
                            .onEnded { gesture in
                                handleSwipe(gesture.translation)
                            }
                    )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Streak: \(currentStreak)", systemImage: "flame.fill")
                    Spacer()
                    Label("Best: \(bestSessionStreak)", systemImage: "crown.fill")
                }
                .font(.headline)

                HStack {
                    Label("Session correct: \(correctThisSession)", systemImage: "checkmark.circle")
                    Spacer()
                    if attemptsThisSession > 0 {
                        let accuracy = Double(correctThisSession) / Double(attemptsThisSession)
                        Text("Session accuracy: \(String(format: "%.0f%%", accuracy * 100))")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    } else {
                        Text("Session accuracy: —")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
            }

            if let feedback {
                HStack {
                    Image(systemName: feedbackIsPositive ? "hand.thumbsup" : "xmark.circle")
                        .foregroundColor(feedbackIsPositive ? .green : .red)
                    Text(feedback)
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding()
                .background(feedbackIsPositive ? Color.green.opacity(0.12) : Color.red.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func handleSwipe(_ translation: CGSize) {
        let direction = swipeDirection(from: translation)
        withAnimation {
            dragOffset = .zero
        }

        guard let direction else { return }
        evaluateGuess(direction)
    }

    private func swipeDirection(from translation: CGSize) -> TrainingCard.Category? {
        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)
        let threshold: CGFloat = 60

        if horizontal > vertical {
            if translation.width > threshold {
                return .high
            } else if translation.width < -threshold {
                return .low
            }
        } else if translation.height < -threshold {
            return .neutral
        }

        return nil
    }

    private func evaluateGuess(_ guess: TrainingCard.Category) {
        let isCorrect = guess == currentCard.category
        let decisionDuration = Date().timeIntervalSince(cardShownAt)
        attemptsThisSession += 1
        if isCorrect {
            currentStreak += 1
            bestSessionStreak = max(bestSessionStreak, currentStreak)
            correctThisSession += 1
        } else {
            currentStreak = 0
        }

        feedbackIsPositive = isCorrect
        feedback = isCorrect
            ? "Correct! \(currentCard.display) is \(currentCard.category.rawValue)."
            : "Oops! \(currentCard.display) is \(currentCard.category.rawValue)."

        appendAttempt(correct: isCorrect, decisionTime: decisionDuration)
        currentCard = TrainingCard.fullDeck().randomElement() ?? currentCard
        cardShownAt = Date()
    }

    private func appendAttempt(correct: Bool, decisionTime: TimeInterval) {
        var updatedAttempts = attempts
        updatedAttempts.append(CardSortingAttemptEntry(date: Date(), correct: correct, decisionTime: decisionTime))
        if let data = try? JSONEncoder().encode(updatedAttempts) {
            storedAttempts = data
        }
    }
}

struct CardSortingStatsSummary: View {
    let overall: CardSortingStats
    let weekly: CardSortingStats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Card Sorting Progress")
                .font(.headline)
            statRow(
                title: "Correct Decisions",
                overall: countLabel(overall.correctAttempts, attempts: overall.totalAttempts),
                weekly: countLabel(weekly.correctAttempts, attempts: weekly.totalAttempts)
            )
            statRow(
                title: "Accuracy",
                overall: percentLabel(overall.accuracy),
                weekly: percentLabel(weekly.accuracy)
            )
            statRow(
                title: "Avg. Decision Time",
                overall: timeLabel(overall.averageDecisionTime),
                weekly: timeLabel(weekly.averageDecisionTime)
            )
            statRow(
                title: "Longest Streak",
                overall: streakLabel(overall.longestStreak, attempts: overall.totalAttempts),
                weekly: streakLabel(weekly.longestStreak, attempts: weekly.totalAttempts)
            )
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func statRow(title: String, overall: String, weekly: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            HStack {
                Text("All-time: \(overall)")
                Spacer()
                Text("Last 7 days: \(weekly)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func percentLabel(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }

    private func timeLabel(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1fs", value)
    }

    private func countLabel(_ count: Int, attempts: Int) -> String {
        attempts > 0 ? String(count) : "—"
    }

    private func streakLabel(_ streak: Int, attempts: Int) -> String {
        attempts > 0 ? String(streak) : "—"
    }
}

// MARK: - Speed Counter

struct SpeedCounterSettings {
    var dealSpeed: Double = 0.45
    var deckCount: Int = 6
    var askForNextHand: Bool = false
    var handsBetweenPrompts: Int = 2
}

struct SpeedCounterSession: Identifiable, Codable {
    let id: UUID
    let date: Date
    let correctEntries: Int
    let totalEntries: Int
    let completed: Bool

    init(date: Date, correctEntries: Int, totalEntries: Int, completed: Bool) {
        id = UUID()
        self.date = date
        self.correctEntries = correctEntries
        self.totalEntries = totalEntries
        self.completed = completed
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, correctEntries, totalEntries, completed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        correctEntries = try container.decode(Int.self, forKey: .correctEntries)
        totalEntries = try container.decode(Int.self, forKey: .totalEntries)
        completed = try container.decodeIfPresent(Bool.self, forKey: .completed) ?? false
    }

    var isPerfect: Bool { completed && totalEntries > 0 && correctEntries == totalEntries }
}

struct SpeedCounterStats {
    let correctEntries: Int
    let accuracy: Double?
    let perfectShoes: Int
    let perfectPercentage: Double?

    static func make(for sessions: [SpeedCounterSession]) -> SpeedCounterStats {
        let correct = sessions.reduce(0) { $0 + $1.correctEntries }
        let total = sessions.reduce(0) { $0 + $1.totalEntries }
        let completed = sessions.filter { $0.completed }
        let perfect = completed.filter { $0.isPerfect }.count
        let accuracy = total > 0 ? Double(correct) / Double(total) : nil
        let perfectPct = completed.isEmpty ? nil : Double(perfect) / Double(completed.count)

        return SpeedCounterStats(
            correctEntries: correct,
            accuracy: accuracy,
            perfectShoes: perfect,
            perfectPercentage: perfectPct
        )
    }
}

struct SpeedCounterCard: Identifiable {
    let id = UUID()
    let rank: Int
    let suit: TrainingCard.Suit

    var trainingCard: TrainingCard {
        TrainingCard(rank: TrainingCard.Rank(rawValue: rank) ?? .ace, suit: suit)
    }

    var hiLoValue: Int { Card(rank: rank).hiLoValue }

    static func shoe(decks: Int) -> [SpeedCounterCard] {
        var cards: [SpeedCounterCard] = []
        for _ in 0..<max(decks, 1) {
            for suit in TrainingCard.Suit.allCases {
                for rank in 1...13 {
                    cards.append(SpeedCounterCard(rank: rank, suit: suit))
                }
            }
        }
        return cards.shuffled()
    }
}

struct SpeedCounterDealtCard: Identifiable {
    let id = UUID()
    let card: SpeedCounterCard
    var isFaceDown: Bool = false
    var isPerpendicular: Bool = false
}

struct SpeedCounterHandState: Identifiable {
    let id = UUID()
    var cards: [SpeedCounterDealtCard]
    var doubleCard: SpeedCounterDealtCard?
    var isSplitAce: Bool
    var splitDepth: Int
}

struct SpeedCounterView: View {
    @AppStorage("speedCounterSessions") private var storedSessions: Data = Data()

    @State private var settings = SpeedCounterSettings()
    @State private var sessions: [SpeedCounterSession] = []
    @State private var startRun: Bool = false
    @State private var runID = UUID()

    private var lastWeekSessions: [SpeedCounterSession] {
        guard let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return [] }
        return sessions.filter { $0.date >= weekAgo }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Speed Counter")
                        .font(.title2.weight(.semibold))
                    Text("Simulate rapid-fire blackjack hands, keep the running count, and get quizzed at your chosen cadence.")
                        .foregroundColor(.secondary)
                }

                VStack(spacing: 14) {
                    HStack {
                        Text("Dealing Speed")
                        Spacer()
                        Text(String(format: "%.2fs", settings.dealSpeed))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $settings.dealSpeed, in: 0.2...1.2, step: 0.05) {
                        Text("Dealing Speed")
                    } minimumValueLabel: {
                        Text("Faster")
                    } maximumValueLabel: {
                        Text("Slower")
                    }

                    Stepper(value: $settings.deckCount, in: 1...8) {
                        Text("Number of Decks: \(settings.deckCount)")
                    }

                    Toggle("Ask for Next Hand", isOn: $settings.askForNextHand)

                    Stepper(value: $settings.handsBetweenPrompts, in: 1...10) {
                        Text("Hands Between Asking Count: \(settings.handsBetweenPrompts)")
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button(action: beginRun) {
                    HStack {
                        Image(systemName: "play.circle.fill")
                        Text("Start Drill")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                SpeedCounterStatsSummary(
                    overall: SpeedCounterStats.make(for: sessions),
                    weekly: SpeedCounterStats.make(for: lastWeekSessions)
                )
            }
            .padding()

            NavigationLink(isActive: $startRun) {
                SpeedCounterRunView(
                    settings: settings,
                    onComplete: { session in
                        sessions.insert(session, at: 0)
                        persistSessions()
                    }
                )
                .id(runID)
            } label: {
                EmptyView()
            }
            .hidden()
        }
        .onAppear(perform: loadSessions)
        .navigationTitle("Speed Counter")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func beginRun() {
        runID = UUID()
        startRun = true
    }

    private func loadSessions() {
        guard let decoded = try? JSONDecoder().decode([SpeedCounterSession].self, from: storedSessions) else { return }
        sessions = decoded
    }

    private func persistSessions() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        storedSessions = data
    }
}

struct SpeedCounterRunView: View {
    private let baseCardWidth: CGFloat = 80
    private let baseHandSpacing: CGFloat = 24
    private let baseCardOffsetX: CGFloat = 26
    private let baseCardOffsetY: CGFloat = 12

    private func layoutScale(for size: CGSize) -> CGFloat {
        let widthScale = size.width / 430
        let heightScale = size.height / 850
        return max(0.5, min(1.05, min(widthScale, heightScale)))
    }

    private func adjustedScale(from base: CGFloat, containerSize: CGSize) -> CGFloat {
        let capHeight = max(120, containerSize.height * 0.28)
        let currentHeight = maxHandHeight(scale: base)
        guard currentHeight > 0 else { return base }
        if currentHeight > capHeight {
            return max(0.45, base * capHeight / currentHeight)
        }
        return base
    }

    private func cardWidth(for scale: CGFloat) -> CGFloat { baseCardWidth * scale }
    private func cardHeight(for scale: CGFloat) -> CGFloat { cardWidth(for: scale) / (2.5/3.5) }
    private func handSpacing(for scale: CGFloat) -> CGFloat { baseHandSpacing * scale }
    private func cardOffsetX(for scale: CGFloat) -> CGFloat { baseCardOffsetX * scale }
    private func cardOffsetY(for scale: CGFloat) -> CGFloat { baseCardOffsetY * scale }

    let settings: SpeedCounterSettings
    let onComplete: (SpeedCounterSession) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var shoe: [SpeedCounterCard] = []
    @State private var dealerCards: [SpeedCounterDealtCard] = []
    @State private var playerHands: [SpeedCounterHandState] = []
    @State private var runningCount: Int = 0
    @State private var handsDealt: Int = 0
    @State private var promptCounter: Int = 0
    @State private var totalPrompts: Int = 0
    @State private var correctPrompts: Int = 0
    @State private var isAskingCount: Bool = false
    @State private var answerText: String = ""
    @State private var feedbackMessage: String?
    @State private var showFeedbackModal: Bool = false
    @State private var awaitingNextHand: Bool = false
    @State private var shoeFinished: Bool = false
    @State private var runningTask: Task<Void, Never>?
    @State private var totalShoeCards: Int = 0
    @State private var showRunningCount: Bool = false
    @State private var pendingAutoAdvanceAfterFeedback: Bool = false
    @State private var sessionLogged: Bool = false

    private var gameRules: GameRules {
        GameRules(
            decks: settings.deckCount,
            dealerHitsSoft17: false,
            doubleAfterSplit: true,
            surrenderAllowed: false,
            blackjackPayout: 1.5,
            penetration: 1.0
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = adjustedScale(from: layoutScale(for: proxy.size), containerSize: proxy.size)

            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                VStack(spacing: 16 * scale) {
                    VStack(spacing: 6 * scale) {
                        ProgressView(value: shoeProgress) {
                            Text("Shoe Progress")
                                .font(.system(size: 15 * scale, weight: .semibold))
                        } currentValueLabel: {
                            Text(shoeProgressLabel)
                                .font(.system(size: 12 * scale))
                                .foregroundColor(.secondary)
                        }
                        .progressViewStyle(.linear)
                    }

                    VStack(alignment: .leading, spacing: 6 * scale) {
                        Text("Dealing hands from a \(settings.deckCount)-deck shoe.")
                            .font(.system(size: 17 * scale, weight: .semibold))
                        Text("Hands dealt: \(handsDealt)")
                            .font(.system(size: 15 * scale))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ZStack(alignment: .bottom) {
                        VStack(spacing: 18 * scale) {
                            dealerArea(scale: scale)
                            Spacer(minLength: 12 * scale)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                        playerArea(scale: scale)
                            .padding(.bottom, 8 * scale)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.secondary.opacity(0.06))
                    )

                    HStack(spacing: 10 * scale) {
                        Text("Running Count:")
                            .font(.system(size: 17 * scale, weight: .semibold))
                        Text(showRunningCount ? "\(runningCount)" : "— —")
                            .font(.system(size: 20 * scale, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                        Button(action: { showRunningCount.toggle() }) {
                            Image(systemName: showRunningCount ? "eye.slash.fill" : "eye.fill")
                                .font(.system(size: 17 * scale))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showRunningCount ? "Hide running count" : "Show running count")
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    if shoeFinished {
                        VStack(spacing: 12 * scale) {
                            Text("Shoe complete")
                                .font(.system(size: 17 * scale, weight: .semibold))
                            HStack(spacing: 10 * scale) {
                                Button(action: dismiss.callAsFunction) {
                                    Text("Back to Start Screen")
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .background(Color.secondary.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                Button(action: restartShoe) {
                                    Text("Keep Going")
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .background(Color.accentColor)
                                        .foregroundColor(.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }
                        }
                    }

                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .navigationTitle("Speed Counter")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear(perform: startShoe)
                .onDisappear {
                    runningTask?.cancel()
                    runningTask = nil
                    Task { await logSessionIfNeeded() }
                }

                if isAskingCount {
                    modalOverlay { countPrompt(scale: scale) }
                } else if showFeedbackModal, let feedbackMessage {
                    modalOverlay {
                        feedbackPrompt(message: feedbackMessage, scale: scale)
                    }
                } else if awaitingNextHand && !shoeFinished {
                    modalOverlay { nextHandPrompt(scale: scale) }
                }
            }
        }
    }

    private func dealerArea(scale: CGFloat) -> some View {
        VStack(alignment: .center, spacing: 8 * scale) {
            Text("Dealer")
                .font(.system(size: 15 * scale, weight: .semibold))
            HStack(spacing: 12 * scale) {
                ForEach(dealerCards) { card in
                    SpeedCounterCardView(card: card)
                        .frame(width: cardWidth(for: scale))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func playerArea(scale: CGFloat) -> some View {
        VStack(alignment: .center, spacing: 8 * scale) {
            Text("Player")
                .font(.system(size: 15 * scale, weight: .semibold))
            GeometryReader { proxy in
                let contentWidth = totalHandsWidth(scale: scale)
                let horizontalPadding = max((proxy.size.width - contentWidth) / 2, 0) + 24 * scale

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: handSpacing(for: scale)) {
                        ForEach(playerHands) { hand in
                            playerHandView(hand, scale: scale)
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                    .frame(
                        maxWidth: max(proxy.size.width, contentWidth + (horizontalPadding * 2)),
                        alignment: .center
                    )
                    .frame(height: maxHandHeight(scale: scale) + 32 * scale, alignment: .bottom)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(height: maxHandHeight(scale: scale) + 44 * scale)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func playerHandView(_ hand: SpeedCounterHandState, scale: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(Array(hand.cards.enumerated()), id: \.offset) { index, card in
                SpeedCounterCardView(card: card)
                    .frame(width: cardWidth(for: scale))
                    .offset(
                        x: CGFloat(index) * cardOffsetX(for: scale),
                        y: CGFloat(-index) * cardOffsetY(for: scale)
                    )
            }

            if let doubleCard = hand.doubleCard {
                SpeedCounterCardView(card: doubleCard)
                    .rotationEffect(.degrees(90))
                    .offset(
                        x: CGFloat(hand.cards.count) * cardOffsetX(for: scale) + 10 * scale,
                        y: CGFloat(-hand.cards.count) * cardOffsetY(for: scale) - 6 * scale
                    )
            }
        }
    }

    private func totalHandsWidth(scale: CGFloat) -> CGFloat {
        guard !playerHands.isEmpty else { return cardWidth(for: scale) }
        let width = playerHands.reduce(0) { partial, hand in
            partial + handWidth(hand, scale: scale)
        }
        let spacingWidth = handSpacing(for: scale) * CGFloat(max(playerHands.count - 1, 0))
        return width + spacingWidth
    }

    private func handWidth(_ hand: SpeedCounterHandState, scale: CGFloat) -> CGFloat {
        let count = max(hand.cards.count, 1)
        var width = cardWidth(for: scale) + CGFloat(max(0, count - 1)) * cardOffsetX(for: scale)
        if hand.doubleCard != nil {
            width += cardWidth(for: scale) * 0.6
        }
        return width
    }

    private func maxHandHeight(scale: CGFloat) -> CGFloat {
        guard !playerHands.isEmpty else { return cardHeight(for: scale) }
        return playerHands.map { handHeight($0, scale: scale) }.max() ?? cardHeight(for: scale)
    }

    private func handHeight(_ hand: SpeedCounterHandState, scale: CGFloat) -> CGFloat {
        let count = max(hand.cards.count, 1)
        var height = cardHeight(for: scale) + CGFloat(max(0, count - 1)) * cardOffsetY(for: scale)
        if hand.doubleCard != nil {
            height = max(height, cardWidth(for: scale) + cardOffsetY(for: scale))
        }
        return height
    }

    private func countPrompt(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            Text("What's the count?")
                .font(.system(size: 17 * scale, weight: .semibold))
            TextField("Enter count", text: $answerText)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
            Button("Submit", action: submitCount)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12 * scale)
    }

    private func feedbackPrompt(message: String, scale: CGFloat) -> some View {
        VStack(spacing: 12 * scale) {
            Text(message)
                .font(.system(size: 17 * scale, weight: .semibold))
                .multilineTextAlignment(.center)
            Button("Close") {
                dismissFeedback()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12 * scale)
    }

    private func nextHandPrompt(scale: CGFloat) -> some View {
        VStack(spacing: 12 * scale) {
            Text("Ready for the next hand?")
                .font(.system(size: 17 * scale, weight: .semibold))
            Button(action: continueAfterPrompt) {
                Text("Next Hand")
                    .font(.system(size: 17 * scale, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10 * scale)
                    .padding(.horizontal, 12 * scale)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12 * scale, style: .continuous))
            }
        }
        .padding(12 * scale)
    }

    @ViewBuilder
    private func modalOverlay<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Color.black.opacity(0.35)
            .ignoresSafeArea()
            .overlay(
                content()
                    .frame(maxWidth: 360)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(radius: 14)
                    .padding()
            )
    }

    @MainActor
    private func startShoe() {
        runningTask?.cancel()
        runningTask = nil
        Task { @MainActor in
            sessionLogged = false
            runningCount = 0
            handsDealt = 0
            promptCounter = 0
            totalPrompts = 0
            correctPrompts = 0
            isAskingCount = false
            answerText = ""
            awaitingNextHand = false
            shoeFinished = false
            feedbackMessage = nil
            showFeedbackModal = false
            showRunningCount = false
            pendingAutoAdvanceAfterFeedback = false
            dealerCards = []
            playerHands = []
            shoe = SpeedCounterCard.shoe(decks: settings.deckCount)
            totalShoeCards = shoe.count
            scheduleNextHand()
        }
    }

    @MainActor
    private func restartShoe() {
        startShoe()
    }

    @MainActor
    private func scheduleNextHand(delay: Double = 0.5) {
        guard !shoeFinished else { return }
        runningTask = Task { @MainActor in
            awaitingNextHand = false
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await playHand()
        }
    }

    private func continueAfterPrompt() {
        Task { @MainActor in awaitingNextHand = false }
        scheduleNextHand(delay: 0.1)
    }

    @MainActor
    private func playHand() async {
        guard !Task.isCancelled else { return }
        guard shoe.count > 15 else {
            await finishShoe()
            return
        }

        dealerCards = []
        playerHands = [SpeedCounterHandState(cards: [], doubleCard: nil, isSplitAce: false, splitDepth: 0)]

        guard await dealCard(toPlayerHand: 0) != nil else { await finishShoe(); return }
        guard await dealDealerCard(faceDown: true) != nil else { await finishShoe(); return }
        guard await dealCard(toPlayerHand: 0) != nil else { await finishShoe(); return }
        guard let dealerUp = await dealDealerCard(faceDown: false) else { await finishShoe(); return }

        await playPlayerHands(dealerUp: dealerUp.card)
        await revealHoleCard()
        await dealerPlay()
        await clearTable()

        handsDealt += 1
        promptCounter += 1

        handlePostHand()
    }

    @MainActor
    private func handlePostHand() {
        if shouldAskForCount() {
            isAskingCount = true
            answerText = ""
            feedbackMessage = nil
            promptCounter = 0
            return
        }

        if settings.askForNextHand {
            awaitingNextHand = true
        } else {
            scheduleNextHand()
        }
    }

    private func shouldAskForCount() -> Bool {
        promptCounter >= settings.handsBetweenPrompts
    }

    @MainActor
    private func dealCard(toPlayerHand index: Int, perpendicular: Bool = false) async -> SpeedCounterDealtCard? {
        guard !Task.isCancelled else { return nil }
        guard index < playerHands.count else { return nil }
        guard let next = await drawCard(faceDown: false) else { return nil }
        withAnimation(.easeInOut(duration: settings.dealSpeed)) {
            if perpendicular {
                playerHands[index].doubleCard = SpeedCounterDealtCard(card: next.card, isFaceDown: false, isPerpendicular: true)
            } else {
                playerHands[index].cards.append(next)
            }
        }
        guard !Task.isCancelled else { return next }
        try? await Task.sleep(nanoseconds: UInt64(settings.dealSpeed * 1_000_000_000))
        return next
    }

    @MainActor
    private func dealDealerCard(faceDown: Bool) async -> SpeedCounterDealtCard? {
        guard !Task.isCancelled else { return nil }
        guard let next = await drawCard(faceDown: faceDown) else { return nil }
        withAnimation(.easeInOut(duration: settings.dealSpeed)) {
            dealerCards.append(next)
        }
        guard !Task.isCancelled else { return next }
        try? await Task.sleep(nanoseconds: UInt64(settings.dealSpeed * 1_000_000_000))
        return next
    }

    @MainActor
    private func drawCard(faceDown: Bool) async -> SpeedCounterDealtCard? {
        guard !Task.isCancelled else { return nil }
        guard !shoe.isEmpty else { return nil }
        let card = shoe.removeLast()
        if !faceDown {
            runningCount += card.hiLoValue
        }
        return SpeedCounterDealtCard(card: card, isFaceDown: faceDown, isPerpendicular: false)
    }

    @MainActor
    private func playPlayerHands(dealerUp: SpeedCounterCard) async {
        var handIndex = 0
        while handIndex < playerHands.count {
            guard !Task.isCancelled else { return }
            let splitDepth = await MainActor.run { playerHands[handIndex].splitDepth }
            await playSingleHand(at: handIndex, dealerUp: dealerUp, splitDepth: splitDepth)
            handIndex += 1
        }
    }

    @MainActor
    private func playSingleHand(at index: Int, dealerUp: SpeedCounterCard, splitDepth: Int) async {
        while true {
            guard !Task.isCancelled else { return }
            let handCount = await MainActor.run { playerHands.count }
            guard index < handCount else { return }
            let currentHand = await MainActor.run { playerHands[index] }
            let handModel = hand(from: currentHand)

            if currentHand.isSplitAce && currentHand.cards.count >= 2 { return }
            if handModel.isBlackjack || handModel.isBusted { return }

            let action = StrategyAdvisor.baseAction(for: handModel, dealerUp: Card(rank: dealerUp.rank), rules: gameRules)

            switch action {
            case .split where splitDepth < 3 && handModel.canSplit:
                guard !Task.isCancelled else { return }
                await performSplit(at: index, dealerUp: dealerUp, splitDepth: splitDepth)
                return
            case .double where currentHand.cards.count == 2:
                guard !Task.isCancelled else { return }
                _ = await dealCard(toPlayerHand: index, perpendicular: true)
                return
            case .hit:
                guard !Task.isCancelled else { return }
                _ = await dealCard(toPlayerHand: index)
            default:
                return
            }
        }
    }

    @MainActor
    private func performSplit(at index: Int, dealerUp: SpeedCounterCard, splitDepth: Int) async {
        let hand = await MainActor.run { () -> SpeedCounterHandState? in
            guard index < playerHands.count else { return nil }
            return playerHands[index]
        }
        guard let hand else { return }
        guard hand.cards.count == 2 else { return }

        let first = hand.cards[0]
        let second = hand.cards[1]

        playerHands.remove(at: index)
        let left = SpeedCounterHandState(cards: [first], doubleCard: nil, isSplitAce: first.card.rank == 1, splitDepth: splitDepth + 1)
        let right = SpeedCounterHandState(cards: [second], doubleCard: nil, isSplitAce: second.card.rank == 1, splitDepth: splitDepth + 1)
        playerHands.insert(right, at: index)
        playerHands.insert(left, at: index)

        guard !Task.isCancelled else { return }
        _ = await dealCard(toPlayerHand: index)
        guard !Task.isCancelled else { return }
        _ = await dealCard(toPlayerHand: index + 1)

        guard !Task.isCancelled else { return }
        await playSingleHand(at: index, dealerUp: dealerUp, splitDepth: splitDepth + 1)
        guard !Task.isCancelled else { return }
        await playSingleHand(at: index + 1, dealerUp: dealerUp, splitDepth: splitDepth + 1)
    }

    private func hand(from state: SpeedCounterHandState) -> Hand {
        var cards = state.cards.map { Card(rank: $0.card.rank) }
        if let doubleCard = state.doubleCard {
            cards.append(Card(rank: doubleCard.card.rank))
        }
        return Hand(cards: cards, isSplitAce: state.isSplitAce, fromSplit: state.splitDepth > 0)
    }

    @MainActor
    private func revealHoleCard() async {
        guard !Task.isCancelled else { return }
        if let index = dealerCards.firstIndex(where: { $0.isFaceDown }) {
            dealerCards[index].isFaceDown = false
            runningCount += dealerCards[index].card.hiLoValue
        }
        guard !Task.isCancelled else { return }
        try? await Task.sleep(nanoseconds: UInt64(settings.dealSpeed * 1_000_000_000))
    }

    @MainActor
    private func dealerPlay() async {
        var dealerHand = Hand(cards: dealerCards.map { Card(rank: $0.card.rank) })

        while true {
            guard !Task.isCancelled else { return }
            let value = dealerHand.bestValue
            let isSoft = dealerHand.isSoft
            if value < 17 || (value == 17 && gameRules.dealerHitsSoft17 && isSoft) {
                if let newCard = await drawCard(faceDown: false) {
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: settings.dealSpeed)) {
                            dealerCards.append(newCard)
                        }
                    }
                    dealerHand.cards.append(Card(rank: newCard.card.rank))
                    try? await Task.sleep(nanoseconds: UInt64(settings.dealSpeed * 1_000_000_000))
                } else {
                    break
                }
            } else {
                break
            }
        }
    }

    @MainActor
    private func clearTable() async {
        guard !Task.isCancelled else { return }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            dealerCards = []
            playerHands = []
        }
    }

    @MainActor
    private func finishShoe() async {
        guard !shoeFinished else { return }
        shoeFinished = true
        isAskingCount = false
        awaitingNextHand = false
        await logSessionIfNeeded(force: true, completed: true)
    }

    @MainActor
    private func logSessionIfNeeded(force: Bool = false, completed: Bool = false) async {
        let hasData = handsDealt > 0 || totalPrompts > 0 || force
        guard !sessionLogged, hasData else { return }

        let session = SpeedCounterSession(
            date: Date(),
            correctEntries: correctPrompts,
            totalEntries: totalPrompts,
            completed: completed || shoeFinished
        )

        sessionLogged = true
        onComplete(session)
    }

    private func submitCount() {
        totalPrompts += 1
        isAskingCount = false
        let guessed = Int(answerText.trimmingCharacters(in: .whitespacesAndNewlines))
        if guessed == runningCount {
            correctPrompts += 1
            feedbackMessage = "Correct! Running count is \(runningCount)."
        } else {
            feedbackMessage = "Incorrect. Running count is \(runningCount)."
        }

        showFeedbackModal = true

        pendingAutoAdvanceAfterFeedback = !settings.askForNextHand

        if settings.askForNextHand {
            awaitingNextHand = true
        }
    }

    private func dismissFeedback() {
        Task { @MainActor in
            showFeedbackModal = false
            feedbackMessage = nil
            if pendingAutoAdvanceAfterFeedback && !shoeFinished {
                pendingAutoAdvanceAfterFeedback = false
                scheduleNextHand()
            } else {
                pendingAutoAdvanceAfterFeedback = false
            }
        }
    }

    private var shoeProgress: Double {
        guard totalShoeCards > 0 else { return 0 }
        return 1 - (Double(shoe.count) / Double(totalShoeCards))
    }

    private var shoeProgressLabel: String {
        let percentage = Int(round(shoeProgress * 100))
        return "\(percentage)% of shoe played"
    }

}

struct SpeedCounterCardView: View {
    let card: SpeedCounterDealtCard

    var body: some View {
        ZStack {
            if card.isFaceDown {
                CardBackAssetView()
            } else {
                CardIconView(card: card.card.trainingCard)
            }
        }
        .frame(width: 80)
    }
}

struct CardBackAssetView: View {
    var body: some View {
        if let image = UIImage(named: "CardBackArt") {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
        } else {
            CardBackView()
        }
    }
}

struct CardBackView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.86, green: 0.09, blue: 0.23), Color(red: 0.57, green: 0.02, blue: 0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.8), lineWidth: 2)
            )
            .overlay(
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        cardBackPip
                        cardBackPip
                        cardBackPip
                    }
                    HStack(spacing: 6) {
                        cardBackPip
                        cardBackPip
                        cardBackPip
                    }
                    HStack(spacing: 6) {
                        cardBackPip
                        cardBackPip
                        cardBackPip
                    }
                }
            )
            .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
    }

    private var cardBackPip: some View {
        Circle()
            .fill(Color.white.opacity(0.9))
            .frame(width: 10, height: 10)
    }
}

struct SpeedCounterStatsSummary: View {
    let overall: SpeedCounterStats
    let weekly: SpeedCounterStats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speed Counter Stats")
                .font(.headline)
            statRow(
                title: "Correct Entries",
                overall: countLabel(overall.correctEntries),
                weekly: countLabel(weekly.correctEntries)
            )
            statRow(
                title: "Accuracy of Decision",
                overall: percentLabel(overall.accuracy),
                weekly: percentLabel(weekly.accuracy)
            )
            statRow(
                title: "Perfect Shoes",
                overall: countLabel(overall.perfectShoes),
                weekly: countLabel(weekly.perfectShoes)
            )
            statRow(
                title: "% Perfect Shoes",
                overall: percentLabel(overall.perfectPercentage),
                weekly: percentLabel(weekly.perfectPercentage)
            )
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func statRow(title: String, overall: String, weekly: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            HStack {
                Text("All-time: \(overall)")
                Spacer()
                Text("Last 7 days: \(weekly)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func percentLabel(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }

    private func countLabel(_ value: Int) -> String {
        value > 0 ? String(value) : "—"
    }
}

struct DeckCountThroughSession: Identifiable, Codable {
    let id: UUID
    let date: Date
    let durationSeconds: Double
    let correctGuess: Bool

    init(date: Date, durationSeconds: Double, correctGuess: Bool) {
        id = UUID()
        self.date = date
        self.durationSeconds = durationSeconds
        self.correctGuess = correctGuess
    }
}

struct DeckCountThroughStats {
    let averageTime: Double?
    let bestTime: Double?
    let accuracy: Double?

    static func make(for sessions: [DeckCountThroughSession]) -> DeckCountThroughStats {
        guard !sessions.isEmpty else { return DeckCountThroughStats(averageTime: nil, bestTime: nil, accuracy: nil) }
        let durations = sessions.map { $0.durationSeconds }
        let average = durations.reduce(0, +) / Double(durations.count)
        let successfulDurations = sessions.filter { $0.correctGuess }.map { $0.durationSeconds }
        let best = successfulDurations.min()
        let accuracy = Double(sessions.filter { $0.correctGuess }.count) / Double(sessions.count)
        return DeckCountThroughStats(averageTime: average, bestTime: best, accuracy: accuracy)
    }
}

struct DeckCountThroughView: View {
    @AppStorage("deckCountThroughSessions") private var storedSessions: Data = Data()

    @State private var sessions: [DeckCountThroughSession] = []
    @State private var selectedMinutes: Int = 0
    @State private var selectedSeconds: Int = 30
    @State private var navigateToRun: Bool = false
    @State private var runConfigID = UUID()

    private var totalDuration: TimeInterval {
        let seconds = (selectedMinutes * 60) + selectedSeconds
        return max(Double(seconds), 1)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Deck Count Through")
                        .font(.title2.weight(.semibold))
                    Text("A card counter should be able to count down a full deck in 30 seconds or less. This drill will shuffle a fresh deck, deal 51 cards within your chosen time, and ask you to guess whether the last card is Low, Neutral, or High.")
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Deal Time")
                        .font(.headline)
                    HStack {
                        Picker("Minutes", selection: $selectedMinutes) {
                            ForEach(0..<10) { Text("\($0) min").tag($0) }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)

                        Picker("Seconds", selection: $selectedSeconds) {
                            ForEach(0..<60) { Text("\($0) sec").tag($0) }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                    }
                    .frame(height: 140)
                    Text("Cards will be dealt evenly across \(Int(totalDuration)) seconds.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Button(action: beginRun) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Start Dealing")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                DeckCountThroughStatsSummary(
                    overall: DeckCountThroughStats.make(for: sessions),
                    weekly: DeckCountThroughStats.make(for: lastWeekSessions)
                )
                .padding(.top)
            }
            .padding()
            NavigationLink(isActive: $navigateToRun) {
                DeckCountThroughRunView(
                    minutes: selectedMinutes,
                    seconds: selectedSeconds,
                    onComplete: { session in
                        sessions.insert(session, at: 0)
                        persistSessions()
                    }
                )
                .id(runConfigID)
            } label: {
                EmptyView()
            }
            .hidden()
        }
        .onAppear(perform: loadSessions)
    }

    private var lastWeekSessions: [DeckCountThroughSession] {
        guard let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return [] }
        return sessions.filter { $0.date >= weekAgo }
    }

    private func beginRun() {
        runConfigID = UUID()
        navigateToRun = true
    }

    private func loadSessions() {
        guard let decoded = try? JSONDecoder().decode([DeckCountThroughSession].self, from: storedSessions) else { return }
        sessions = decoded
    }

    private func persistSessions() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        storedSessions = data
    }

    private func formatTime(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

struct DeckCountThroughRunView: View {
    let minutes: Int
    let seconds: Int
    let onComplete: (DeckCountThroughSession) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .countdown
    @State private var countdownValue: Int = 3
    @State private var deck: [TrainingCard] = TrainingCard.fullDeck().shuffled()
    @State private var currentCard: TrainingCard?
    @State private var dealtCount: Int = 0
    @State private var sessionStart: Date?
    @State private var pendingDuration: TimeInterval?
    @State private var remainingCard: TrainingCard?
    @State private var countdownTimer: Timer?
    @State private var dealingTimer: Timer?
    @State private var guessResult: String?
    @State private var cardAnimationToggle: Bool = false

    private let cardsToDeal = 51

    private var totalDuration: TimeInterval { max(Double(minutes * 60 + seconds), 1) }
    private var dealInterval: TimeInterval { max(totalDuration / Double(cardsToDeal), 0.05) }

    enum Phase {
        case countdown
        case dealing
        case guessing
        case finished
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Deck Count Through")
                    .font(.title3.weight(.semibold))
                Text("Get ready for a shuffled deck. After a brief countdown we'll deal 51 cards for you to track, then you'll guess whether the last card is Low, Neutral, or High.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Group {
                switch phase {
                case .countdown:
                    countdownView
                case .dealing:
                    dealingView
                case .guessing:
                    guessingPrompt
                case .finished:
                    resultView
                }
            }

            if phase == .guessing {
                guessButtons
            }

            if let guessResult {
                Text(guessResult)
                    .font(.headline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            if phase == .finished {
                Button(action: dismiss.callAsFunction) {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationBarBackButtonHidden(phase == .dealing || phase == .guessing)
        .navigationTitle("Deck Count Through")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: startRun)
        .onDisappear(perform: stopTimers)
        .toolbar {
            if phase != .finished {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: cancelRun)
                }
            }
        }
    }

    private var countdownView: some View {
        VStack(spacing: 16) {
            Text("Starting in")
                .font(.headline)
            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.2), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: CGFloat(countdownProgress))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.9), value: countdownValue)
                Text("\(countdownValue)")
                    .font(.system(size: 44, weight: .bold))
            }
            .frame(width: 140, height: 140)
            Text("Keep your eyes on the cards—dealing begins as soon as the countdown ends.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 4)
    }

    private var dealingView: some View {
        VStack(spacing: 12) {
            Text("Dealing...")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 8)
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                if let card = currentCard {
                    CardIconView(card: card)
                        .frame(width: 120)
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                        .id(card.id)
                        .animation(.easeInOut(duration: 0.25), value: cardAnimationToggle)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.stack.fill")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("Preparing cards")
                            .foregroundColor(.secondary)
                    }
                }
            }
            HStack {
                Label("\(dealtCount)/\(cardsToDeal) cards", systemImage: "clock")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Target time: \(Int(totalDuration))s")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var guessingPrompt: some View {
        VStack(spacing: 14) {
            Text("Make your call")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 8)
                    .frame(height: 220)
                VStack(spacing: 10) {
                    Image(systemName: "questionmark.square.dashed")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("What's the remaining card?")
                        .foregroundColor(.secondary)
                }
            }
            Text("Choose whether the last card is Low (2-6), Neutral (7-9), or High (10-A).")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var guessButtons: some View {
        HStack(spacing: 10) {
            guessButton(for: .low)
            guessButton(for: .neutral)
            guessButton(for: .high)
        }
    }

    private var resultView: some View {
        VStack(spacing: 14) {
            Text("Result")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let remainingCard {
                CardIconView(card: remainingCard)
                    .frame(width: 140)
            }
            Text(guessResult ?? "Session complete.")
                .font(.body.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func guessButton(for category: TrainingCard.Category) -> some View {
        Button(action: { submitGuess(category) }) {
            Text(category.rawValue)
                .multilineTextAlignment(.center)
                .font(.subheadline.weight(.semibold))
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Color.white)
                .foregroundColor(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 3)
        }
    }

    private func startRun() {
        stopTimers()
        deck = TrainingCard.fullDeck().shuffled()
        remainingCard = deck.last
        dealtCount = 0
        guessResult = nil
        phase = .countdown
        countdownValue = 3
        sessionStart = nil
        pendingDuration = nil
        startCountdown()
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            if countdownValue <= 0 {
                timer.invalidate()
                startDealing()
            } else {
                countdownValue -= 1
            }
        }
        if let countdownTimer {
            RunLoop.main.add(countdownTimer, forMode: .common)
        }
    }

    private func startDealing() {
        phase = .dealing
        sessionStart = Date()
        dealtCount = 0
        var index = 0
        dealingTimer?.invalidate()
        dealingTimer = Timer.scheduledTimer(withTimeInterval: dealInterval, repeats: true) { timer in
            guard index < min(cardsToDeal, deck.count) else {
                timer.invalidate()
                finishDealing()
                return
            }
            let card = deck[index]
            withAnimation(.easeInOut(duration: 0.25)) {
                currentCard = card
                cardAnimationToggle.toggle()
            }
            dealtCount = index + 1
            index += 1
        }
        if let dealingTimer {
            RunLoop.main.add(dealingTimer, forMode: .common)
        }
    }

    private func finishDealing() {
        phase = .guessing
        pendingDuration = Date().timeIntervalSince(sessionStart ?? Date())
        currentCard = nil
    }

    private func submitGuess(_ category: TrainingCard.Category) {
        guard phase == .guessing, let remainingCard else { return }
        stopTimers()
        let duration = pendingDuration ?? Date().timeIntervalSince(sessionStart ?? Date())
        let correct = remainingCard.category == category
        guessResult = correct ? "Correct! The last card was \(remainingCard.display)." : "Incorrect. The last card was \(remainingCard.display)."
        let session = DeckCountThroughSession(date: Date(), durationSeconds: duration, correctGuess: correct)
        onComplete(session)
        phase = .finished
    }

    private func stopTimers() {
        countdownTimer?.invalidate()
        dealingTimer?.invalidate()
        countdownTimer = nil
        dealingTimer = nil
    }

    private var countdownProgress: Double {
        let total = 3.0
        return max(0, min(1, (total - Double(countdownValue)) / total))
    }

    private func cancelRun() {
        stopTimers()
        dismiss()
    }
}

struct DeckCountThroughStatsSummary: View {
    let overall: DeckCountThroughStats
    let weekly: DeckCountThroughStats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Stats")
                .font(.headline)
            statRow(title: "Average Time", overall: formattedTime(overall.averageTime), weekly: formattedTime(weekly.averageTime))
            statRow(title: "Best Time", overall: formattedTime(overall.bestTime), weekly: formattedTime(weekly.bestTime))
            statRow(title: "Accuracy", overall: formattedPercent(overall.accuracy), weekly: formattedPercent(weekly.accuracy))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func statRow(title: String, overall: String, weekly: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            HStack {
                Label(overall, systemImage: "clock")
                Spacer()
                Text("Last 7 days: \(weekly)")
                    .foregroundColor(.secondary)
                    .font(.footnote)
            }
        }
    }

    private func formattedTime(_ time: Double?) -> String {
        guard let time else { return "—" }
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formattedPercent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }
}

struct TrainingStatsView: View {
    @AppStorage("deckCountThroughSessions") private var storedSessions: Data = Data()
    @AppStorage("cardSortingAttempts") private var storedCardSorting: Data = Data()
    @AppStorage("speedCounterSessions") private var storedSpeedCounter: Data = Data()
    @AppStorage("strategyQuizHardCompletions") private var quizHardCompletions: Int = 0
    @AppStorage("strategyQuizSoftCompletions") private var quizSoftCompletions: Int = 0
    @AppStorage("strategyQuizPairCompletions") private var quizPairCompletions: Int = 0
    @AppStorage("strategyQuizSurrenderCompletions") private var quizSurrenderCompletions: Int = 0
    @AppStorage("strategyQuizFullCompletions") private var quizFullCompletions: Int = 0
    @AppStorage("deckBetTrainingStats") private var deckBetStatsData: Data = Data()
    @AppStorage("handSimulationSessions") private var storedHandSimulation: Data = Data()

    private var sessions: [DeckCountThroughSession] {
        (try? JSONDecoder().decode([DeckCountThroughSession].self, from: storedSessions)) ?? []
    }

    private var lastWeekSessions: [DeckCountThroughSession] {
        guard let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return [] }
        return sessions.filter { $0.date >= weekAgo }
    }

    private var cardSortingAttempts: [CardSortingAttemptEntry] {
        (try? JSONDecoder().decode([CardSortingAttemptEntry].self, from: storedCardSorting)) ?? []
    }

    private var lastWeekCardSortingAttempts: [CardSortingAttemptEntry] {
        guard let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return [] }
        return cardSortingAttempts.filter { $0.date >= weekAgo }
    }

    private var speedCounterSessions: [SpeedCounterSession] {
        (try? JSONDecoder().decode([SpeedCounterSession].self, from: storedSpeedCounter)) ?? []
    }

    private var lastWeekSpeedCounterSessions: [SpeedCounterSession] {
        guard let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return [] }
        return speedCounterSessions.filter { $0.date >= weekAgo }
    }

    private var cardSortingOverall: CardSortingStats { .make(for: cardSortingAttempts) }
    private var cardSortingWeekly: CardSortingStats { .make(for: lastWeekCardSortingAttempts) }
    private var speedCounterOverall: SpeedCounterStats { .make(for: speedCounterSessions) }
    private var speedCounterWeekly: SpeedCounterStats { .make(for: lastWeekSpeedCounterSessions) }
    private var deckBetStats: DeckBetTrainingStats { DeckBetTrainingStats.decode(from: deckBetStatsData) }
    private var handSimulationSessions: [HandSimulationSession] {
        (try? JSONDecoder().decode([HandSimulationSession].self, from: storedHandSimulation)) ?? []
    }
    private var lastWeekHandSimulation: [HandSimulationSession] {
        guard let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return [] }
        return handSimulationSessions.filter { $0.date >= weekAgo }
    }
    private var handSimulationOverall: HandSimulationStats { .make(for: handSimulationSessions) }
    private var handSimulationWeekly: HandSimulationStats { .make(for: lastWeekHandSimulation) }

    var body: some View {
        List {
            Section("Card Sorting") {
                statRow(
                    title: "Correct Decisions",
                    overall: Double(cardSortingOverall.correctAttempts),
                    weekly: Double(cardSortingWeekly.correctAttempts),
                    formatter: countLabel
                )
                statRow(
                    title: "Accuracy",
                    overall: cardSortingOverall.accuracy,
                    weekly: cardSortingWeekly.accuracy,
                    formatter: percentLabel
                )
                statRow(
                    title: "Avg. Decision Time",
                    overall: cardSortingOverall.averageDecisionTime,
                    weekly: cardSortingWeekly.averageDecisionTime,
                    formatter: decisionTimeLabel
                )
                statRow(
                    title: "Longest Streak",
                    overall: Double(cardSortingOverall.longestStreak),
                    weekly: Double(cardSortingWeekly.longestStreak),
                    formatter: countLabel
                )
            }

            Section("Deck Count Through") {
                statRow(title: "Average Time", overall: DeckCountThroughStats.make(for: sessions).averageTime, weekly: DeckCountThroughStats.make(for: lastWeekSessions).averageTime, formatter: timeLabel)
                statRow(title: "Best Time", overall: DeckCountThroughStats.make(for: sessions).bestTime, weekly: DeckCountThroughStats.make(for: lastWeekSessions).bestTime, formatter: timeLabel)
                statRow(title: "Accuracy", overall: DeckCountThroughStats.make(for: sessions).accuracy, weekly: DeckCountThroughStats.make(for: lastWeekSessions).accuracy, formatter: percentLabel)
            }

            Section("Speed Counter") {
                statRow(title: "Correct Entries", overall: Double(speedCounterOverall.correctEntries), weekly: Double(speedCounterWeekly.correctEntries), formatter: countLabel)
                statRow(title: "Accuracy of Decision", overall: speedCounterOverall.accuracy, weekly: speedCounterWeekly.accuracy, formatter: percentLabel)
                statRow(title: "Perfect Shoes", overall: Double(speedCounterOverall.perfectShoes), weekly: Double(speedCounterWeekly.perfectShoes), formatter: countLabel)
                statRow(title: "% Perfect Shoes", overall: speedCounterOverall.perfectPercentage, weekly: speedCounterWeekly.perfectPercentage, formatter: percentLabel)
            }

            Section("Strategy Quiz") {
                statSummaryRow(title: "Hard completions", value: quizHardCompletions)
                statSummaryRow(title: "Soft completions", value: quizSoftCompletions)
                statSummaryRow(title: "Pair completions", value: quizPairCompletions)
                statSummaryRow(title: "Surrender completions", value: quizSurrenderCompletions)
                statSummaryRow(title: "Full chart completions", value: quizFullCompletions)
            }

            Section("Deck Estimation & Bet Sizing") {
                singleStatRow(title: "Deck Estimation Correctness", value: percentLabel(deckBetStats.deckEstimationAccuracy))
                singleStatRow(title: "Bet Sizing Correctness", value: percentLabel(deckBetStats.betSizingAccuracy))
                singleStatRow(title: "Combined Decision Correctness", value: percentLabel(deckBetStats.combinedAccuracy))
            }

            Section("Hand Simulation") {
                statRow(title: "Accurate Decisions", overall: handSimulationOverall.accuracy, weekly: handSimulationWeekly.accuracy, formatter: percentLabel)
                statRow(title: "Longest Correct Streak", overall: Double(handSimulationOverall.longestStreak), weekly: Double(handSimulationWeekly.longestStreak), formatter: countLabel)
                statRow(title: "Perfect Shoes", overall: Double(handSimulationOverall.perfectShoes), weekly: Double(handSimulationWeekly.perfectShoes), formatter: countLabel)
                statRow(title: "Longest Perfect Shoe Streak", overall: Double(handSimulationOverall.longestPerfectStreak), weekly: Double(handSimulationWeekly.longestPerfectStreak), formatter: countLabel)
            }

            Section("More Training Stats") {
                Text("Attempt the Test Out from the Training Suite. Performance tracking will appear here in a future update.")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
                    .padding(.vertical, 4)
            }
        }
        .navigationTitle("Training Stats")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func statRow(title: String, overall: Double?, weekly: Double?, formatter: (Double?) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text("All-time: \(formatter(overall))")
            Text("Last 7 days: \(formatter(weekly))")
                .foregroundColor(.secondary)
        }
    }

    private func statSummaryRow(title: String, value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)")
                .foregroundColor(.secondary)
        }
    }

    private func singleStatRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }

    private func timeLabel(_ value: Double?) -> String {
        guard let value else { return "—" }
        let minutes = Int(value) / 60
        let seconds = Int(value) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func decisionTimeLabel(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1fs", value)
    }

    private func percentLabel(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }

    private func countLabel(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(Int(value))
    }
}

struct HomeView: View {
    private let defaultRules = GameRules.defaultStrategyRules

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text("Card Counting App")
                        .font(.largeTitle.weight(.bold))
                        .padding(.top, 12)

                    NavigationLink {
                        PlaceholderFeatureView(title: "How to Count Cards")
                            .navigationTitle("How to Count Cards")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        menuButtonLabel(title: "How to Count Cards")
                    }

                    NavigationLink {
                        BasicStrategyChartView(rules: defaultRules)
                    } label: {
                        menuButtonLabel(title: "Basic Strategy Chart")
                    }

                    NavigationLink {
                        TrainingSuiteView()
                            .navigationTitle("Training Suite")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        menuButtonLabel(title: "Training Suite")
                    }

                    NavigationLink {
                        ContentView()
                    } label: {
                        menuButtonLabel(title: "Expected Value Simulator")
                    }

                    NavigationLink {
                        TripLoggerView()
                            .navigationTitle("Trip Logger")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        menuButtonLabel(title: "Trip Logger")
                    }

                    NavigationLink {
                        PlaceholderFeatureView(title: "Support This Project")
                            .navigationTitle("Support")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Text("If You Want to Support This Project")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor.opacity(0.08))
                            .cornerRadius(12)
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func menuButtonLabel(title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(12)
    }
}

@main
struct BlackJackAppV1App: App {
#if canImport(UIKit)
    @UIApplicationDelegateAdaptor(OrientationAppDelegate.self) var appDelegate
#endif

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
