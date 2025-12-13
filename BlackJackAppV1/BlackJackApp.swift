import SwiftUI
import Combine
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
                notesByKey[key] = LocationNote(
                    location: session.location,
                    city: session.city,
                    notes: trimmed
                )
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
        let trimmed = note.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No comments yet" }
        return trimmed.components(separatedBy: .newlines).first ?? "No comments yet"
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
            comments: comments
        )

        newSession.location = location
        newSession.city = city
        newSession.earnings = earnings
        newSession.durationHours = duration
        newSession.evPerHour = evValue
        newSession.evRunID = evRunID
        newSession.evSourceName = evSourceName
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

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
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
                deviations: deviationEntries
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
                deviations: []
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
            return dealerUp.rank == 1 ? .hit : .double
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

// MARK: - Training Suite

struct TrainingOption: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let destination: AnyView
}

struct TrainingSuiteView: View {
    private let options: [TrainingOption] = [
        TrainingOption(
            title: "Card Sorting",
            icon: "square.grid.2x2",
            destination: AnyView(CardSortingView())
        ),
        TrainingOption(
            title: "Speed Counter",
            icon: "speedometer",
            destination: AnyView(PlaceholderFeatureView(title: "Speed Counter"))
        ),
        TrainingOption(
            title: "Deck Count Through",
            icon: "rectangle.stack",
            destination: AnyView(DeckCountThroughView())
        ),
        TrainingOption(
            title: "Strategy Quiz",
            icon: "questionmark.square.dashed",
            destination: AnyView(PlaceholderFeatureView(title: "Strategy Quiz"))
        ),
        TrainingOption(
            title: "Hand Simulation",
            icon: "hands.clap",
            destination: AnyView(PlaceholderFeatureView(title: "Hand Simulation"))
        ),
        TrainingOption(
            title: "Deck Estimation and Bet Sizing",
            icon: "scalemass",
            destination: AnyView(PlaceholderFeatureView(title: "Deck Estimation and Bet Sizing"))
        ),
        TrainingOption(
            title: "Test Out",
            icon: "checkmark.seal",
            destination: AnyView(PlaceholderFeatureView(title: "Test Out"))
        ),
        TrainingOption(
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
    let card: TrainingCard

    private var cardColor: Color {
        switch card.suit {
        case .hearts, .diamonds:
            return .red
        default:
            return .primary
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 4)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.rank.label)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundColor(cardColor)
                        Text(card.suit.symbol)
                            .font(.system(size: 18))
                            .foregroundColor(cardColor)
                    }
                    Spacer()
                    Text(card.suit.symbol)
                        .font(.system(size: 32))
                        .foregroundColor(cardColor)
                }

                Spacer()

                centerContent

                Spacer()

                Text(card.display)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .foregroundColor(cardColor)
            }
            .padding(12)
        }
        .frame(minWidth: 80, minHeight: 112)
        .aspectRatio(2/3, contentMode: .fit)
    }

    private var centerContent: some View {
        Group {
            if pipRows.isEmpty {
                VStack(spacing: 6) {
                    Text(card.rank.label)
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundColor(cardColor)
                    Text(card.suit.symbol)
                        .font(.system(size: 28))
                        .foregroundColor(cardColor)
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(pipRows.enumerated()), id: \.offset) { index, count in
                        HStack(spacing: 6) {
                            Spacer(minLength: 0)
                            ForEach(0..<count, id: \.self) { _ in
                                Text(card.suit.symbol)
                                    .font(.system(size: 22))
                                    .foregroundColor(cardColor)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Row \(index + 1) pips")
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var pipRows: [Int] {
        switch card.rank {
        case .ace:
            return [1]
        case .two:
            return [1, 1]
        case .three:
            return [1, 1, 1]
        case .four:
            return [2, 2]
        case .five:
            return [2, 1, 2]
        case .six:
            return [2, 2, 2]
        case .seven:
            return [2, 1, 2, 2]
        case .eight:
            return [2, 2, 2, 2]
        case .nine:
            return [2, 2, 1, 2, 2]
        case .ten:
            return [2, 2, 2, 2, 2]
        case .jack, .queen, .king:
            return []
        }
    }
}

struct CardSortingAttempt: Identifiable, Codable {
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

    static func make(for attempts: [CardSortingAttempt]) -> CardSortingStats {
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

    private var attempts: [CardSortingAttempt] {
        (try? JSONDecoder().decode([CardSortingAttempt].self, from: storedAttempts)) ?? []
    }

    private var lastWeekAttempts: [CardSortingAttempt] {
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
        updatedAttempts.append(CardSortingAttempt(date: Date(), correct: correct, decisionTime: decisionTime))
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

    private var sessions: [DeckCountThroughSession] {
        (try? JSONDecoder().decode([DeckCountThroughSession].self, from: storedSessions)) ?? []
    }

    private var lastWeekSessions: [DeckCountThroughSession] {
        guard let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return [] }
        return sessions.filter { $0.date >= weekAgo }
    }

    private var cardSortingAttempts: [CardSortingAttempt] {
        (try? JSONDecoder().decode([CardSortingAttempt].self, from: storedCardSorting)) ?? []
    }

    private var lastWeekCardSortingAttempts: [CardSortingAttempt] {
        guard let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return [] }
        return cardSortingAttempts.filter { $0.date >= weekAgo }
    }

    private var cardSortingOverall: CardSortingStats { .make(for: cardSortingAttempts) }
    private var cardSortingWeekly: CardSortingStats { .make(for: lastWeekCardSortingAttempts) }

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

            Section("More Training Stats") {
                Text("Card Sorting, Speed Counter, Strategy Quiz, Hand Simulation, Deck Estimation and Bet Sizing, and Test Out stats will appear here once those drills are available.")
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
    private let defaultRules = GameRules(
        decks: 6,
        dealerHitsSoft17: true,
        doubleAfterSplit: true,
        surrenderAllowed: true,
        blackjackPayout: 1.5,
        penetration: 0.75
    )

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
