import SwiftUI

struct GameRules: Codable {
    var decks: Int
    var dealerHitsSoft17: Bool
    var doubleAfterSplit: Bool
    var surrenderAllowed: Bool
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

struct SimulationInput: Codable {
    var rules: GameRules
    var betting: BettingModel
    var handsToSimulate: Int
    var handsPerHour: Double
    var bankroll: Double
    var useBasicDeviations: Bool
}

struct SimulationResult: Codable {
    var expectedValuePerHour: Double
    var standardDeviationPerHour: Double
    var riskOfRuin: Double
    var averageBet: Double
    var medianBet: Double
    var hoursToPositive: [Double]
    var totalEv: Double
    var totalSd: Double
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

    var isSoft: Bool {
        values.contains(11 + (bestValue - 11)) && bestValue <= 21
    }

    var canSplit: Bool {
        cards.count == 2 && cards[0].rank == cards[1].rank
    }
}

enum PlayerAction {
    case hit, stand, double, split, surrender
}

class BlackjackSimulator {
    private var shoe: [Card] = []
    private var runningCount: Int = 0
    private let rules: GameRules
    private let betting: BettingModel
    private let useDeviations: Bool

    init(input: SimulationInput) {
        self.rules = input.rules
        self.betting = input.betting
        self.useDeviations = input.useBasicDeviations
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
    }

    private func drawCard() -> Card {
        if Double(shoe.count) / Double(rules.decks * 52) < (1 - rules.penetration) {
            reshuffle()
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
        if rules.surrenderAllowed && hand.cards.count == 2 {
            if hand.bestValue == 16 && [9,10,1].contains(dealerUp.value) { return .surrender }
            if hand.bestValue == 15 && dealerUp.value == 10 { return .surrender }
        }

        if hand.canSplit {
            let rank = hand.cards[0].rank
            switch rank {
            case 1: return .split
            case 10: return .stand
            case 9: return [2,3,4,5,6,8,9].contains(dealerUp.value) ? .split : .stand
            case 8: return .split
            case 7: return dealerUp.value <= 7 ? .split : .hit
            case 6: return dealerUp.value <= 6 ? .split : .hit
            case 5: return basicHardStrategy(total: 10, dealerUp: dealerUp)
            case 4: return (5...6).contains(dealerUp.value) ? .split : .hit
            case 3,2: return dealerUp.value <= 7 ? .split : .hit
            default: break
            }
        }

        let total = hand.bestValue
        let containsAce = hand.values.contains( total - 10 ) && total <= 21
        var action: PlayerAction
        if containsAce && total <= 21 {
            action = basicSoftStrategy(total: total, dealerUp: dealerUp)
        } else {
            action = basicHardStrategy(total: total, dealerUp: dealerUp)
        }

        if action == .double && hand.fromSplit && !rules.doubleAfterSplit {
            action = .hit
        }
        return action
    }

    private func basicHardStrategy(total: Int, dealerUp: Card) -> PlayerAction {
        switch total {
        case ..<9: return .hit
        case 9: return (3...6).contains(dealerUp.value) ? .double : .hit
        case 10: return (2...9).contains(dealerUp.value) ? .double : .hit
        case 11: return dealerUp.rank == 1 ? .hit : .double
        case 12: return (4...6).contains(dealerUp.value) ? .stand : .hit
        case 13...16: return (2...6).contains(dealerUp.value) ? .stand : .hit
        default: return .stand
        }
    }

    private func basicSoftStrategy(total: Int, dealerUp: Card) -> PlayerAction {
        switch total {
        case 13,14: return (5...6).contains(dealerUp.value) ? .double : .hit
        case 15,16: return (4...6).contains(dealerUp.value) ? .double : .hit
        case 17: return (3...6).contains(dealerUp.value) ? .double : .hit
        case 18:
            if (3...6).contains(dealerUp.value) { return .double }
            if (2...8).contains(dealerUp.value) { return .stand }
            return .hit
        case 19:
            if dealerUp.value == 6 { return .double }
            return .stand
        default:
            return .stand
        }
    }

    private func applyDeviations(base: PlayerAction, hand: Hand, dealerUp: Card) -> PlayerAction {
        guard useDeviations else { return base }
        let tc = Int(floor(trueCount))
        let total = hand.bestValue

        // Surrender deviations (Fab 4)
        if rules.surrenderAllowed && hand.cards.count == 2 {
            if total == 15 && dealerUp.value == 10 && tc >= 0 { return .surrender }
            if total == 15 && dealerUp.value == 9 && tc >= 2 { return .surrender }
            if total == 15 && dealerUp.rank == 1 && tc >= 1 { return .surrender }
            if total == 14 && dealerUp.value == 10 && tc >= 3 { return .surrender }
        }

        // Illustrious 18 style deviations
        switch (total, dealerUp.value) {
        case (16, 10):
            return tc >= 0 ? .stand : base
        case (15, 10):
            return tc >= 4 ? .stand : base
        case (10, 10):
            return tc >= 4 ? .double : base
        case (12, 3):
            return tc >= 2 ? .stand : base
        case (12, 2):
            return tc >= 3 ? .stand : base
        case (11, 11):
            return tc >= 1 ? .double : base
        case (9, 2):
            return tc >= 1 ? .double : base
        case (9, 7):
            return tc >= 3 ? .double : base
        case (16, 9):
            return tc >= 5 ? .stand : base
        case (13, 2):
            return tc >= -1 ? .stand : base
        case (12, 4):
            return tc >= 0 ? .stand : base
        case (12, 5):
            return tc >= -2 ? .stand : base
        case (12, 6):
            return tc >= -1 ? .stand : base
        case (13, 3):
            return tc >= -2 ? .stand : base
        default:
            break
        }

        return base
    }

    private func playHand(initialHand: Hand, dealerHand: Hand, bet: Double, splitDepth: Int = 0) -> Double {
        var hand = initialHand
        var wager = bet
        let dealerUp = dealerHand.cards.first ?? Card(rank: 10)
        let action = applyDeviations(base: basicStrategy(for: hand, dealerUp: dealerUp), hand: hand, dealerUp: dealerUp)

        switch action {
        case .surrender:
            return -wager / 2.0
        case .split where splitDepth < 3 && hand.canSplit && (!hand.isSplitAce):
            let firstCard = hand.cards[0]
            let secondCard = hand.cards[1]
            var firstHand = Hand(cards: [firstCard], isSplitAce: firstCard.rank == 1, fromSplit: true)
            var secondHand = Hand(cards: [secondCard], isSplitAce: secondCard.rank == 1, fromSplit: true)
            firstHand.cards.append(drawCard())
            secondHand.cards.append(drawCard())
            if firstHand.isSplitAce { return settle(hand: firstHand, dealerHand: dealerHand, bet: wager, stood: true) + settle(hand: secondHand, dealerHand: dealerHand, bet: wager, stood: true) }
            let win1 = playHand(initialHand: firstHand, dealerHand: dealerHand, bet: wager, splitDepth: splitDepth + 1)
            let win2 = playHand(initialHand: secondHand, dealerHand: dealerHand, bet: wager, splitDepth: splitDepth + 1)
            return win1 + win2
        case .double:
            if hand.cards.count == 2 {
                wager *= 2
                hand.cards.append(drawCard())
                return settle(hand: hand, dealerHand: dealerHand, bet: wager, stood: true)
            } else {
                return settle(hand: hand, dealerHand: dealerHand, bet: wager, stood: false)
            }
        default:
            var stood = false
            var currentAction = action
            while true {
                switch currentAction {
                case .hit:
                    hand.cards.append(drawCard())
                    if hand.isBusted {
                        stood = true
                        break
                    }
                    currentAction = applyDeviations(base: basicStrategy(for: hand, dealerUp: dealerUp), hand: hand, dealerUp: dealerUp)
                case .stand:
                    stood = true
                    break
                default:
                    stood = true
                    break
                }
            }
            return settle(hand: hand, dealerHand: dealerHand, bet: wager, stood: stood)
        }
    }

    private func settle(hand: Hand, dealerHand: Hand, bet: Double, stood: Bool) -> Double {
        if hand.isBusted { return -bet }
        if hand.cards.count == 2 && hand.isBlackjack {
            // No blackjack after split aces in many rules; handle in caller by passing isSplitAce flag
        }
        var dealerHand = dealerHand
        if dealerHand.isBlackjack {
            if hand.isBlackjack && !hand.fromSplit { return 0 }
            return -bet
        }

        if hand.isBlackjack && !hand.fromSplit {
            return bet * (rules.blackjackPayout - 1)
        }

        dealerHand = dealerPlay(dealerHand)
        if dealerHand.isBusted { return bet }

        let playerTotal = hand.bestValue
        let dealerTotal = dealerHand.bestValue
        if playerTotal > dealerTotal { return bet }
        if playerTotal < dealerTotal { return -bet }
        return 0
    }

    func simulate(hands: Int, handsPerHour: Double, bankroll: Double, progress: @escaping (Int) -> Void, shouldCancel: @escaping () -> Bool) async -> SimulationResult? {
        var totalProfit: Double = 0
        var profits: [Double] = []
        var bets: [Double] = []

        for handIndex in 0..<hands {
            if shouldCancel() { return nil }
            if handIndex % 500 == 0 { await Task.yield() }
            let wager = betting.bet(for: trueCount)
            bets.append(wager)
            let playerHand = Hand(cards: [drawCard(), drawCard()])
            let dealerUp = drawCard()
            let dealerHole = drawCard()
            let dealerHand = Hand(cards: [dealerUp, dealerHole])
            let handProfit = playHand(initialHand: playerHand, dealerHand: dealerHand, bet: wager)
            totalProfit += handProfit
            profits.append(handProfit)
            if handIndex % 50 == 0 || handIndex == hands - 1 {
                await MainActor.run {
                    progress(handIndex + 1)
                }
            }
        }

        let avgProfitPerHand = totalProfit / Double(hands)
        let variance = profits.reduce(0.0) { $0 + pow($1 - avgProfitPerHand, 2) } / Double(max(hands - 1, 1))
        let sdPerHand = sqrt(variance)

        let hourlyEv = avgProfitPerHand * handsPerHour
        let hourlySd = sdPerHand * sqrt(handsPerHour)

        let sortedBets = bets.sorted()
        let medianBet = sortedBets.count % 2 == 0 ? (sortedBets[sortedBets.count/2] + sortedBets[sortedBets.count/2 - 1]) / 2 : sortedBets[sortedBets.count/2]

        let riskOfRuin: Double
        if hourlyEv <= 0 {
            riskOfRuin = 1.0
        } else {
            let variancePerHand = variance
            let riskExponent = -2 * bankroll * avgProfitPerHand / max(variancePerHand, 1)
            riskOfRuin = exp(riskExponent)
        }

        func hoursFor(z: Double) -> Double {
            guard hourlyEv > 0 else { return .infinity }
            let numerator = z * hourlySd
            let denom = hourlyEv
            return pow(numerator / denom, 2)
        }

        let hours50 = max(0, hoursFor(z: 0))
        let hours90 = hoursFor(z: 1.2816)
        let hours99 = hoursFor(z: 2.3263)

        return SimulationResult(
            expectedValuePerHour: hourlyEv,
            standardDeviationPerHour: hourlySd,
            riskOfRuin: riskOfRuin,
            averageBet: bets.reduce(0, +) / Double(bets.count),
            medianBet: medianBet,
            hoursToPositive: [hours50, hours90, hours99],
            totalEv: avgProfitPerHand,
            totalSd: sdPerHand
        )
    }
}

struct SavedRun: Identifiable, Codable {
    var id: UUID = .init()
    var timestamp: Date
    var input: SimulationInput
    var result: SimulationResult
}

struct ContentView: View {
    @State private var decks: Int = 6
    @State private var dealerHitsSoft17: Bool = true
    @State private var dasAllowed: Bool = true
    @State private var surrenderAllowed: Bool = true
    @State private var blackjackPayout: Double = 1.5
    @State private var penetration: Double = 0.75
    @State private var minBet: Double = 10
    @State private var spreads: [BetRampEntry] = [
        BetRampEntry(trueCount: 1, bet: 20),
        BetRampEntry(trueCount: 2, bet: 40),
        BetRampEntry(trueCount: 3, bet: 80),
        BetRampEntry(trueCount: 4, bet: 100)
    ]
    @State private var handsToSimulate: Int = 10000
    @State private var handsPerHour: Double = 100
    @State private var bankroll: Double = 10000
    @State private var useDeviations: Bool = true
    @State private var result: SimulationResult?
    @State private var isSimulating: Bool = false
    @State private var completedHands: Int = 0
    @State private var startTime: Date?
    @State private var simulationTask: Task<Void, Never>?
    @State private var userCancelled: Bool = false
    @AppStorage("savedRuns") private var savedRunsData: Data = Data()
    @State private var savedRuns: [SavedRun] = []

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    rulesSection
                    bettingSection
                    simSection
                    progressSection
                    resultSection
                    savedRunsSection
                }
                .padding()
            }
            .navigationTitle("Blackjack EV Lab")
            .onAppear(perform: loadSavedRuns)
        }
    }

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
                        Stepper("True count: \(binding.trueCount.wrappedValue)", value: binding.trueCount, in: 1...12)
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

    private var simSection: some View {
        Section(header: Text("Simulation").font(.headline)) {
            HStack {
                Text("Hands to simulate")
                TextField("10000", value: $handsToSimulate, format: .number)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Hands per hour")
                TextField("100", value: $handsPerHour, format: .number)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Bankroll")
                TextField("10000", value: $bankroll, format: .number)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Use basic deviations", isOn: $useDeviations)
            HStack {
                Button(action: runSimulation) {
                    HStack {
                        if isSimulating { ProgressView() }
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
                    ProgressView(value: Double(completedHands), total: Double(max(handsToSimulate, 1)))
                    Text(String(format: "Hands: %d / %d (%.1f%%)", completedHands, handsToSimulate, (Double(completedHands) / Double(max(handsToSimulate, 1))) * 100))
                    if let startTime {
                        let elapsed = Date().timeIntervalSince(startTime)
                        Text(String(format: "Elapsed: %.1f seconds", elapsed))
                    }
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
                    Text(String(format: "Risk of ruin: %.4f", result.riskOfRuin))
                    Text(String(format: "Average bet: $%.2f", result.averageBet))
                    Text(String(format: "Median bet: $%.2f", result.medianBet))
                    Text(String(format: "Hours to be ahead (50%%): %.2f", result.hoursToPositive[0]))
                    Text(String(format: "Hours to be ahead (90%%): %.2f", result.hoursToPositive[1]))
                    Text(String(format: "Hours to be ahead (99%%): %.2f", result.hoursToPositive[2]))
                    Text(String(format: "EV/hand: $%.4f", result.totalEv))
                    Text(String(format: "SD/hand: $%.4f", result.totalSd))
                }
            }
        }
    }

    private var savedRunsSection: some View {
        Section(header: Text("Saved runs").font(.headline)) {
            if savedRuns.isEmpty {
                Text("No saved runs yet. Completed simulations are stored here for reuse.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(savedRuns.indices, id: \.self) { index in
                    let run = savedRuns[index]
                    VStack(alignment: .leading) {
                        Text(run.timestamp, style: .date)
                            .font(.subheadline)
                        Text(String(format: "EV/hr $%.2f | Hands %d | Min bet $%.0f", run.result.expectedValuePerHour, run.input.handsToSimulate, run.input.betting.minBet))
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

    private func loadSavedRuns() {
        guard !savedRunsData.isEmpty,
              let decoded = try? JSONDecoder().decode([SavedRun].self, from: savedRunsData) else {
            savedRuns = []
            return
        }
        savedRuns = decoded
    }

    private func persistSavedRuns() {
        if let data = try? JSONEncoder().encode(savedRuns) {
            savedRunsData = data
        }
    }

    private func load(run: SavedRun) {
        decks = run.input.rules.decks
        dealerHitsSoft17 = run.input.rules.dealerHitsSoft17
        dasAllowed = run.input.rules.doubleAfterSplit
        surrenderAllowed = run.input.rules.surrenderAllowed
        blackjackPayout = run.input.rules.blackjackPayout
        penetration = run.input.rules.penetration
        minBet = run.input.betting.minBet
        spreads = run.input.betting.spreads
        handsToSimulate = run.input.handsToSimulate
        handsPerHour = run.input.handsPerHour
        bankroll = run.input.bankroll
        useDeviations = run.input.useBasicDeviations
        result = run.result
    }

    private func addSpread() {
        guard spreads.count < 12 else { return }
        let nextTC = min((spreads.map { $0.trueCount }.max() ?? 0) + 1, 12)
        spreads.append(BetRampEntry(trueCount: nextTC, bet: max(minBet, spreads.last?.bet ?? minBet)))
    }

    private func removeSpread(at offsets: IndexSet) {
        spreads.remove(atOffsets: offsets)
    }

    private func removeSavedRun(at offsets: IndexSet) {
        savedRuns.remove(atOffsets: offsets)
        persistSavedRuns()
    }

    private func cancelSimulation() {
        userCancelled = true
        simulationTask?.cancel()
        isSimulating = false
    }

    private func runSimulation() {
        guard !isSimulating else { return }
        isSimulating = true
        userCancelled = false
        completedHands = 0
        startTime = Date()
        result = nil
        let input = SimulationInput(
            rules: GameRules(
                decks: decks,
                dealerHitsSoft17: dealerHitsSoft17,
                doubleAfterSplit: dasAllowed,
                surrenderAllowed: surrenderAllowed,
                blackjackPayout: blackjackPayout,
                penetration: penetration
            ),
            betting: BettingModel(
                minBet: minBet,
                spreads: spreads
            ),
            handsToSimulate: handsToSimulate,
            handsPerHour: handsPerHour,
            bankroll: bankroll,
            useBasicDeviations: useDeviations
        )

        simulationTask = Task(priority: .userInitiated) {
            let simulator = BlackjackSimulator(input: input)
            let outcome = await simulator.simulate(
                hands: input.handsToSimulate,
                handsPerHour: input.handsPerHour,
                bankroll: input.bankroll,
                progress: { count in
                    self.completedHands = count
                },
                shouldCancel: { Task.isCancelled || self.userCancelled }
            )

            await MainActor.run {
                withAnimation {
                    self.isSimulating = false
                    if let outcome {
                        self.result = outcome
                        let saved = SavedRun(timestamp: Date(), input: input, result: outcome)
                        self.savedRuns.append(saved)
                        self.persistSavedRuns()
                    }
                }
            }
        }
    }
}

@main
struct BlackJackAppV1App: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
