import SwiftUI

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

struct SimulationInput: Codable {
    var rules: GameRules
    var betting: BettingModel
    var hoursToSimulate: Double
    var handsPerHour: Double
    var bankroll: Double
    var useBasicDeviations: Bool
    var simulations: Int
}

struct SimulationResult: Codable {
    var expectedValuePerHour: Double
    var standardDeviationPerHour: Double
    var riskOfRuin: Double
    var averageBet: Double
    var medianBet: Double
    var positiveOutcomePercentage: Double
    var bestEndingBankroll: Double
    var worstEndingBankroll: Double
    var worstBustHours: Double?
    var totalEv: Double
    var totalSd: Double
    // Legacy fields
    var finalBankroll: Double?
    var bustedHands: Int?
    var handsPlayed: Int?
    var hoursToPositive: Double?

    enum CodingKeys: String, CodingKey {
        case expectedValuePerHour
        case standardDeviationPerHour
        case riskOfRuin
        case averageBet
        case medianBet
        case positiveOutcomePercentage
        case bestEndingBankroll
        case worstEndingBankroll
        case worstBustHours
        case totalEv
        case totalSd
        case finalBankroll
        case bustedHands
        case handsPlayed
        case hoursToPositive
    }

    init(
        expectedValuePerHour: Double,
        standardDeviationPerHour: Double,
        riskOfRuin: Double,
        averageBet: Double,
        medianBet: Double,
        positiveOutcomePercentage: Double,
        bestEndingBankroll: Double,
        worstEndingBankroll: Double,
        worstBustHours: Double?,
        totalEv: Double,
        totalSd: Double,
        finalBankroll: Double? = nil,
        bustedHands: Int? = nil,
        handsPlayed: Int? = nil,
        hoursToPositive: Double? = nil
    ) {
        self.expectedValuePerHour = expectedValuePerHour
        self.standardDeviationPerHour = standardDeviationPerHour
        self.riskOfRuin = riskOfRuin
        self.averageBet = averageBet
        self.medianBet = medianBet
        self.positiveOutcomePercentage = positiveOutcomePercentage
        self.bestEndingBankroll = bestEndingBankroll
        self.worstEndingBankroll = worstEndingBankroll
        self.worstBustHours = worstBustHours
        self.totalEv = totalEv
        self.totalSd = totalSd
        self.finalBankroll = finalBankroll
        self.bustedHands = bustedHands
        self.handsPlayed = handsPlayed
        self.hoursToPositive = hoursToPositive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expectedValuePerHour = try container.decodeIfPresent(Double.self, forKey: .expectedValuePerHour) ?? 0
        standardDeviationPerHour = try container.decodeIfPresent(Double.self, forKey: .standardDeviationPerHour) ?? 0
        riskOfRuin = try container.decodeIfPresent(Double.self, forKey: .riskOfRuin) ?? 0
        averageBet = try container.decodeIfPresent(Double.self, forKey: .averageBet) ?? 0
        medianBet = try container.decodeIfPresent(Double.self, forKey: .medianBet) ?? 0
        positiveOutcomePercentage = try container.decodeIfPresent(Double.self, forKey: .positiveOutcomePercentage) ?? 0
        bestEndingBankroll = try container.decodeIfPresent(Double.self, forKey: .bestEndingBankroll) ?? 0
        worstEndingBankroll = try container.decodeIfPresent(Double.self, forKey: .worstEndingBankroll) ?? 0
        worstBustHours = try container.decodeIfPresent(Double.self, forKey: .worstBustHours)
        totalEv = try container.decodeIfPresent(Double.self, forKey: .totalEv) ?? 0
        totalSd = try container.decodeIfPresent(Double.self, forKey: .totalSd) ?? 0
        finalBankroll = try container.decodeIfPresent(Double.self, forKey: .finalBankroll)
        bustedHands = try container.decodeIfPresent(Int.self, forKey: .bustedHands)
        handsPlayed = try container.decodeIfPresent(Int.self, forKey: .handsPlayed)
        hoursToPositive = try container.decodeIfPresent(Double.self, forKey: .hoursToPositive)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(expectedValuePerHour, forKey: .expectedValuePerHour)
        try container.encode(standardDeviationPerHour, forKey: .standardDeviationPerHour)
        try container.encode(riskOfRuin, forKey: .riskOfRuin)
        try container.encode(averageBet, forKey: .averageBet)
        try container.encode(medianBet, forKey: .medianBet)
        try container.encode(positiveOutcomePercentage, forKey: .positiveOutcomePercentage)
        try container.encode(bestEndingBankroll, forKey: .bestEndingBankroll)
        try container.encode(worstEndingBankroll, forKey: .worstEndingBankroll)
        try container.encodeIfPresent(worstBustHours, forKey: .worstBustHours)
        try container.encode(totalEv, forKey: .totalEv)
        try container.encode(totalSd, forKey: .totalSd)
        try container.encodeIfPresent(finalBankroll, forKey: .finalBankroll)
        try container.encodeIfPresent(bustedHands, forKey: .bustedHands)
        try container.encodeIfPresent(handsPlayed, forKey: .handsPlayed)
        try container.encodeIfPresent(hoursToPositive, forKey: .hoursToPositive)
    }
}

struct SingleRealityResult {
    var expectedValuePerHour: Double
    var standardDeviationPerHour: Double
    var riskOfRuin: Double
    var averageBet: Double
    var medianBet: Double
    var totalEv: Double
    var totalSd: Double
    var finalBankroll: Double
    var bustedHands: Int?
    var handsPlayed: Int
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
            var newTotals: Set<Int> = []
            for total in totals {
                for candidate in cardValues {
                    newTotals.insert(total + candidate)
                }
            }
            totals = Array(newTotals)
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
        var dealerHand = hand
        while true {
            let value = dealerHand.bestValue
            let isSoft = dealerHand.values.contains(where: { $0 <= 21 && $0 + 10 == value }) && value <= 21
            if value < 17 || (value == 17 && rules.dealerHitsSoft17 && isSoft) {
                dealerHand.cards.append(drawCard())
            } else {
                break
            }
        }
        return dealerHand
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
        case 13, 14: return (5...6).contains(dealerUp.value) ? .double : .hit
        case 15, 16: return (4...6).contains(dealerUp.value) ? .double : .hit
        case 17: return (3...6).contains(dealerUp.value) ? .double : .hit
        case 18:
            if (3...6).contains(dealerUp.value) { return .double }
            if (2...8).contains(dealerUp.value) { return .stand }
            return .hit
        case 19:
            return dealerUp.value == 6 ? .double : .stand
        default:
            return .stand
        }
    }

    private func basicStrategy(for hand: Hand, dealerUp: Card) -> PlayerAction {
        if rules.surrenderAllowed && hand.cards.count == 2 {
            if hand.bestValue == 16 && [9, 10, 1].contains(dealerUp.value) { return .surrender }
            if hand.bestValue == 15 && dealerUp.value == 10 { return .surrender }
        }

        if hand.canSplit {
            let rank = hand.cards[0].rank
            switch rank {
            case 1: return .split
            case 10: return .stand
            case 9: return [2, 3, 4, 5, 6, 8, 9].contains(dealerUp.value) ? .split : .stand
            case 8: return .split
            case 7: return dealerUp.value <= 7 ? .split : .hit
            case 6: return dealerUp.value <= 6 ? .split : .hit
            case 5: return basicHardStrategy(total: 10, dealerUp: dealerUp)
            case 4: return (5...6).contains(dealerUp.value) ? .split : .hit
            case 3, 2: return dealerUp.value <= 7 ? .split : .hit
            default: break
            }
        }

        let total = hand.bestValue
        let containsAce = hand.values.contains(total - 10) && total <= 21
        var action: PlayerAction = containsAce ? basicSoftStrategy(total: total, dealerUp: dealerUp)
                                               : basicHardStrategy(total: total, dealerUp: dealerUp)
        if action == .double && hand.fromSplit && !rules.doubleAfterSplit {
            action = .hit
        }
        return action
    }

    private func applyDeviations(base: PlayerAction, hand: Hand, dealerUp: Card) -> PlayerAction {
        guard useDeviations else { return base }
        let tc = Int(floor(trueCount))
        let total = hand.bestValue

        if rules.surrenderAllowed && hand.cards.count == 2 {
            if total == 15 && dealerUp.value == 10 && tc >= 0 { return .surrender }
            if total == 15 && dealerUp.value == 9 && tc >= 2 { return .surrender }
            if total == 15 && dealerUp.rank == 1 && tc >= 1 { return .surrender }
            if total == 14 && dealerUp.value == 10 && tc >= 3 { return .surrender }
        }

        switch (total, dealerUp.value) {
        case (16, 10): return tc >= 0 ? .stand : base
        case (15, 10): return tc >= 4 ? .stand : base
        case (10, 10): return tc >= 4 ? .double : base
        case (12, 3): return tc >= 2 ? .stand : base
        case (12, 2): return tc >= 3 ? .stand : base
        case (11, 11): return tc >= 1 ? .double : base
        case (9, 2): return tc >= 1 ? .double : base
        case (9, 7): return tc >= 3 ? .double : base
        case (16, 9): return tc >= 5 ? .stand : base
        case (13, 2): return tc >= -1 ? .stand : base
        case (12, 4): return tc >= 0 ? .stand : base
        case (12, 5): return tc >= -2 ? .stand : base
        case (12, 6): return tc >= -1 ? .stand : base
        case (13, 3): return tc >= -2 ? .stand : base
        default: return base
        }
    }

    private func settle(hand: Hand, dealerHand: Hand, bet: Double, stood: Bool) -> Double {
        if hand.isBusted { return -bet }
        if dealerHand.isBlackjack {
            if hand.isBlackjack && !hand.fromSplit { return 0 }
            return -bet
        }
        if hand.isBlackjack && !hand.fromSplit {
            return bet * rules.blackjackPayout
        }

        var resolvedDealer = dealerHand
        if !stood {
            resolvedDealer = dealerPlay(dealerHand)
        }
        let dealerValue = resolvedDealer.bestValue
        let playerValue = hand.bestValue

        if dealerValue > 21 { return bet }
        if playerValue > dealerValue { return bet }
        if playerValue < dealerValue { return -bet }
        return 0
    }

    private func playHand(
        initialHand: Hand,
        dealerHand: Hand,
        bet: Double,
        availableBankroll: Double,
        splitDepth: Int = 0
    ) -> Double {
        var hand = initialHand
        var wager = min(bet, availableBankroll)
        let dealerUp = dealerHand.cards.first ?? Card(rank: 10)
        var action = applyDeviations(
            base: basicStrategy(for: hand, dealerUp: dealerUp),
            hand: hand,
            dealerUp: dealerUp
        )

        if action == .double && hand.cards.count != 2 {
            action = .hit
        }

        switch action {
        case .surrender:
            return -wager / 2.0

        case .split where splitDepth < 3 && hand.canSplit:
            let firstCard = hand.cards[0]
            let secondCard = hand.cards[1]
            var firstHand = Hand(cards: [firstCard], isSplitAce: firstCard.rank == 1, fromSplit: true)
            var secondHand = Hand(cards: [secondCard], isSplitAce: secondCard.rank == 1, fromSplit: true)
            firstHand.cards.append(drawCard())
            secondHand.cards.append(drawCard())

            let splitStakePerHand = min(wager, availableBankroll / 2)

            if firstHand.isSplitAce || secondHand.isSplitAce {
                let wagerPerAce = splitStakePerHand
                let win1 = settle(hand: firstHand, dealerHand: dealerHand, bet: wagerPerAce, stood: true)
                let win2 = settle(hand: secondHand, dealerHand: dealerHand, bet: wagerPerAce, stood: true)
                return win1 + win2
            }

            let win1 = playHand(
                initialHand: firstHand,
                dealerHand: dealerHand,
                bet: splitStakePerHand,
                availableBankroll: splitStakePerHand,
                splitDepth: splitDepth + 1
            )
            let win2 = playHand(
                initialHand: secondHand,
                dealerHand: dealerHand,
                bet: splitStakePerHand,
                availableBankroll: splitStakePerHand,
                splitDepth: splitDepth + 1
            )
            return win1 + win2

        case .double:
            let doubleWager = min(wager * 2, availableBankroll)
            wager = doubleWager
            hand.cards.append(drawCard())
            return settle(hand: hand, dealerHand: dealerHand, bet: wager, stood: true)

        default:
            var stood = false
            var currentAction = action
            while true {
                switch currentAction {
                case .hit:
                    hand.cards.append(drawCard())
                    if hand.isBusted { stood = true; break }
                    currentAction = applyDeviations(
                        base: basicStrategy(for: hand, dealerUp: dealerUp),
                        hand: hand,
                        dealerUp: dealerUp
                    )
                    if currentAction == .double && hand.cards.count != 2 {
                        currentAction = .hit
                    }
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

    private func simulateSingleReality(
        hands: Int,
        handsPerHour: Double,
        bankroll: Double
    ) -> SingleRealityResult {
        var currentBankroll = bankroll
        var bets: [Double] = []
        var profits: [Double] = []
        var bustedAtHand: Int?
        var handsPlayed = 0

        for handIndex in 0..<hands {
            if currentBankroll <= 0 {
                bustedAtHand = handIndex
                break
            }

            let wager = min(betting.bet(for: trueCount), currentBankroll)
            bets.append(wager)
            if wager <= 0 {
                break
            }

            var player = Hand(cards: [drawCard(), drawCard()])
            var dealer = Hand(cards: [drawCard(), drawCard()])

            // dealer blackjack peek
            let dealerHasBlackjack = dealer.isBlackjack
            if dealerHasBlackjack {
                let profit = settle(hand: player, dealerHand: dealer, bet: wager, stood: true)
                profits.append(profit)
                currentBankroll += profit
                handsPlayed += 1
                continue
            }

            let profit = playHand(
                initialHand: player,
                dealerHand: dealerPlay(dealer),
                bet: wager,
                availableBankroll: currentBankroll
            )
            profits.append(profit)
            currentBankroll += profit
            handsPlayed += 1
        }

        let avgProfitPerHand = profits.reduce(0, +) / Double(max(profits.count, 1))
        let variance = profits.reduce(0) { $0 + pow($1 - avgProfitPerHand, 2) } / Double(max(profits.count, 1))
        let sdPerHand = sqrt(variance)
        let hourlyEv = avgProfitPerHand * handsPerHour
        let hourlySd = sdPerHand * sqrt(handsPerHour)

        let sortedBets = bets.sorted()
        let medianBet: Double
        if sortedBets.isEmpty { medianBet = 0 }
        else if sortedBets.count % 2 == 0 {
            medianBet = (sortedBets[sortedBets.count / 2] + sortedBets[sortedBets.count / 2 - 1]) / 2
        } else {
            medianBet = sortedBets[sortedBets.count / 2]
        }

        let riskOfRuin: Double
        if hourlyEv <= 0 {
            riskOfRuin = 1.0
        } else {
            let variancePerHand = variance
            let riskExponent = -2 * bankroll * avgProfitPerHand / max(variancePerHand, 1)
            riskOfRuin = exp(riskExponent)
        }

        return SingleRealityResult(
            expectedValuePerHour: hourlyEv,
            standardDeviationPerHour: hourlySd,
            riskOfRuin: riskOfRuin,
            averageBet: bets.reduce(0, +) / Double(max(bets.count, 1)),
            medianBet: medianBet,
            totalEv: avgProfitPerHand,
            totalSd: sdPerHand,
            finalBankroll: currentBankroll,
            bustedHands: bustedAtHand,
            handsPlayed: handsPlayed
        )
    }

    func simulate(
        simulations: Int,
        hours: Double,
        handsPerHour: Double,
        bankroll: Double,
        progress: @escaping (Int) -> Void,
        shouldCancel: @escaping () -> Bool
    ) async -> SimulationResult? {
        guard simulations > 0 else { return nil }
        let hands = Int(hours * handsPerHour)
        guard hands > 0 else { return nil }

        var evPerHourSum: Double = 0
        var sdPerHourSum: Double = 0
        var riskSum: Double = 0
        var avgBetSum: Double = 0
        var medianBets: [Double] = []
        var evPerHandSum: Double = 0
        var sdPerHandSum: Double = 0
        var positiveOutcomes = 0
        var bestEndingBankroll: Double = -.infinity
        var worstEndingBankroll: Double = .infinity
        var worstBustHours: Double?

        for index in 0..<simulations {
            if shouldCancel() { return nil }
            let result = simulateSingleReality(hands: hands, handsPerHour: handsPerHour, bankroll: bankroll)
            evPerHourSum += result.expectedValuePerHour
            sdPerHourSum += result.standardDeviationPerHour
            riskSum += result.riskOfRuin
            avgBetSum += result.averageBet
            medianBets.append(result.medianBet)
            evPerHandSum += result.totalEv
            sdPerHandSum += result.totalSd

            if result.finalBankroll > bankroll { positiveOutcomes += 1 }
            if result.finalBankroll > bestEndingBankroll { bestEndingBankroll = result.finalBankroll }
            if result.finalBankroll < worstEndingBankroll {
                worstEndingBankroll = result.finalBankroll
                if let busted = result.bustedHands {
                    worstBustHours = Double(busted) / handsPerHour
                } else {
                    worstBustHours = nil
                }
            }

            await MainActor.run { progress(index + 1) }
        }

        let count = Double(simulations)
        let medianBet: Double
        let sortedMedian = medianBets.sorted()
        if sortedMedian.isEmpty { medianBet = 0 }
        else if sortedMedian.count % 2 == 0 {
            medianBet = (sortedMedian[sortedMedian.count / 2] + sortedMedian[sortedMedian.count / 2 - 1]) / 2
        } else {
            medianBet = sortedMedian[sortedMedian.count / 2]
        }

        return SimulationResult(
            expectedValuePerHour: evPerHourSum / count,
            standardDeviationPerHour: sdPerHourSum / count,
            riskOfRuin: riskSum / count,
            averageBet: avgBetSum / count,
            medianBet: medianBet,
            positiveOutcomePercentage: (Double(positiveOutcomes) / count) * 100,
            bestEndingBankroll: bestEndingBankroll,
            worstEndingBankroll: worstEndingBankroll,
            worstBustHours: worstBustHours,
            totalEv: evPerHandSum / count,
            totalSd: sdPerHandSum / count
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
    @State private var hoursToSimulate: Double = 100
    @State private var handsPerHour: Double = 100
    @State private var bankroll: Double = 10000
    @State private var useDeviations: Bool = true
    @State private var simulations: Int = 1000
    @State private var result: SimulationResult?
    @State private var isSimulating: Bool = false
    @State private var completedSimulations: Int = 0
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
                Text("Hours to simulate")
                TextField("100", value: $hoursToSimulate, format: .number)
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
                Text("Simulations")
                TextField("1000", value: $simulations, format: .number)
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
                    ProgressView(value: Double(completedSimulations), total: Double(max(simulations, 1)))
                    Text(
                        String(
                            format: "Simulations: %d / %d (%.1f%%)",
                            completedSimulations,
                            simulations,
                            (Double(completedSimulations) / Double(max(simulations, 1))) * 100
                        )
                    )
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
                    Text(String(format: "Positive outcomes: %.2f%%", result.positiveOutcomePercentage))
                    Text(String(format: "Best ending bankroll: $%.2f", result.bestEndingBankroll))
                    if let bustHours = result.worstBustHours {
                        Text(
                            String(
                                format: "Worst ending bankroll: $%.2f (bust at %.2f hours)",
                                result.worstEndingBankroll,
                                bustHours
                            )
                        )
                    } else {
                        Text(String(format: "Worst ending bankroll: $%.2f", result.worstEndingBankroll))
                    }
                    Text(String(format: "EV/hand: $%.4f", result.totalEv))
                    Text(String(format: "SD/hand: $%.4f", result.totalSd))
                }
            }
        }
    }

    private var savedRunsSection: some View {
        Section(header: Text("Saved runs").font(.headline)) {
            if savedRuns.isEmpty {
                Text("No saved runs yet")
                    .foregroundColor(.secondary)
            } else {
                ForEach(savedRuns) { run in
                    VStack(alignment: .leading) {
                        Text(run.timestamp, style: .date)
                        Text(String(format: "EV/hour: $%.2f", run.result.expectedValuePerHour))
                        Text(String(format: "Best BR: $%.2f", run.result.bestEndingBankroll))
                        Text(String(format: "Worst BR: $%.2f", run.result.worstEndingBankroll))
                        Button("Load") { load(run: run) }
                    }
                }
                .onDelete(perform: removeSavedRun)
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
        hoursToSimulate = run.input.hoursToSimulate
        handsPerHour = run.input.handsPerHour
        bankroll = run.input.bankroll
        useDeviations = run.input.useBasicDeviations
        simulations = run.input.simulations
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
        completedSimulations = 0
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
            hoursToSimulate: hoursToSimulate,
            handsPerHour: handsPerHour,
            bankroll: bankroll,
            useBasicDeviations: useDeviations,
            simulations: simulations
        )

        simulationTask = Task(priority: .userInitiated) {
            let simulator = BlackjackSimulator(input: input)
            let outcome = await simulator.simulate(
                simulations: input.simulations,
                hours: input.hoursToSimulate,
                handsPerHour: input.handsPerHour,
                bankroll: input.bankroll,
                progress: { count in
                    self.completedSimulations = count
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
