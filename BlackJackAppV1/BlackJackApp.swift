import SwiftUI
#if canImport(UIKit)
import UIKit
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
    var useBasicDeviations: Bool
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

enum PlayerAction {
    case hit, stand, double, split, surrender
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
    private let useDeviations: Bool
    private let debugEnabled: Bool

    // Exposed debug log
    var debugLog: [DebugRecord] = []

    init(input: SimulationInput, debugEnabled: Bool = false) {
        self.rules = input.rules
        self.betting = input.betting
        self.useDeviations = input.useBasicDeviations
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

    private func basicHardStrategy(total: Int, dealerUp: Card) -> PlayerAction {
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

    private func basicSoftStrategy(total: Int, dealerUp: Card) -> PlayerAction {
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
        // Only on original hand and only vs Ace
        guard splitDepth == 0, dealerUp.rank == 1 else { return 0 }
        let tc = trueCount
        return tc >= 3 ? bet / 2.0 : 0.0
    }

    // Deviations: Fab 4 + Illustrious hard + soft H17/S17
    private func applyDeviations(base: PlayerAction, hand: Hand, dealerUp: Card) -> PlayerAction {
        guard useDeviations else { return base }

        let tc = Int(floor(trueCount))
        let total = hand.bestValue
        let dealerVal = dealerUp.value
        let isSoft = hand.isSoft

        // --- Surrender deviations (Fab 4) ---
        if rules.surrenderAllowed && hand.cards.count == 2 {
            if total == 15 && dealerVal == 10 && tc >= 0 { return .surrender }
            if total == 15 && dealerVal == 9 && tc >= 2 { return .surrender }
            if total == 15 && dealerUp.rank == 1 && tc >= 1 { return .surrender }
            if total == 14 && dealerVal == 10 && tc >= 3 { return .surrender }
        }

        // --- Soft deviations (2-card soft hands only) ---
        if hand.cards.count == 2 && isSoft {
            // Soft 17 (A,6): both H17 & S17 -> double vs 2 at TC >= +1
            if total == 17 && dealerVal == 2 && tc >= 1 { return .double }

            // Soft 19 (A,8) deviations
            if total == 19 {
                if rules.dealerHitsSoft17 {
                    // H17: A,8 vs 4: 3+, vs 5: 1+, vs 6: 0-
                    switch dealerVal {
                    case 4:
                        if tc >= 3 { return .double }
                    case 5:
                        if tc >= 1 { return .double }
                    case 6:
                        if tc < 0 { return .stand } // base is double; stand for negative counts
                    default:
                        break
                    }
                } else {
                    // S17: A,8 vs 4: 3+, vs 5: 1+, vs 6: 1+
                    switch dealerVal {
                    case 4:
                        return tc >= 3 ? .double : .stand
                    case 5, 6:
                        return tc >= 1 ? .double : .stand
                    default:
                        break
                    }
                }
            }
        }

        // --- Hard deviations: H17 vs S17 ---
        if rules.dealerHitsSoft17 {
            // ===== H17 deviations =====
            switch (total, dealerVal) {
            case (16, 10): return tc >= 0 ? .stand : base
            case (16, 9):  return tc >= 4 ? .stand : base
            case (16, 11): return tc >= 3 ? .stand : base
            case (15, 10): return tc >= 4 ? .stand : base
            case (15, 11): return tc >= 5 ? .stand : base
            case (10, 10): return tc >= 4 ? .double : base
            case (10, 11): return tc >= 3 ? .double : base
            case (12, 3):  return tc >= 2 ? .stand : base
            case (12, 2):  return tc >= 3 ? .stand : base
            case (11, 11): return tc >= 1 ? .double : base
            case (9, 2):   return tc >= 1 ? .double : base
            case (9, 7):   return tc >= 3 ? .double : base
            case (13, 2):  return tc >= -1 ? .stand : base
            case (12, 4):  return tc >= 0 ? .stand : base
            case (12, 5):  return tc >= -2 ? .stand : base
            case (12, 6):  return tc >= -1 ? .stand : base
            case (13, 3):  return tc >= -2 ? .stand : base
            case (8, 6):   return tc >= 2 ? .double : base
            default: break
            }
        } else {
            // ===== S17 deviations =====
            switch (total, dealerVal) {
            case (16, 10): return tc >= 0 ? .stand : base
            case (16, 9):  return tc >= 4 ? .stand : base
            case (15, 10): return tc >= 4 ? .stand : base
            case (10, 10): return tc >= 4 ? .double : base
            case (10, 11): return tc >= 4 ? .double : base
            case (12, 3):  return tc >= 2 ? .stand : base
            case (12, 2):  return tc >= 3 ? .stand : base
            case (11, 11): return tc >= 1 ? .double : base
            case (9, 2):   return tc >= 1 ? .double : base
            case (9, 7):   return tc >= 3 ? .double : base
            case (13, 2):  return tc >= -1 ? .stand : base
            case (12, 4):  return tc >= 0 ? .stand : base
            case (12, 5):  return tc >= -2 ? .stand : base
            case (12, 6):  return tc >= -1 ? .stand : base
            case (13, 3):  return tc >= -2 ? .stand : base
            case (8, 6):   return tc >= 2 ? .double : base
            default: break
            }
        }

        return base
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
        let insuranceBet = insuranceBetAmount(for: wager, dealerUp: dealerUp, splitDepth: splitDepth)

        // Dealer peek for blackjack
        if dealerHand.isBlackjack {
            let insurancePayout = insuranceBet > 0 ? insuranceBet * 2.0 : 0.0

            if hand.isBlackjack && !hand.fromSplit {
                // Push main bet; you just keep your stake and win insurance if any
                return insurancePayout
            } else {
                // Lose main bet
                return insurancePayout - wager
            }
        }

        // No dealer blackjack; insurance (if taken) is lost
        let insuranceLoss = -insuranceBet

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
            var currentAction = firstAction

            handLoop: while true {
                switch currentAction {
                case .hit:
                    hand.cards.append(drawCard())
                    actions.append(.hit)
                    if hand.isBusted {
                        stood = true
                        break handLoop
                    }
                    let nextBase = basicStrategy(for: hand, dealerUp: dealerUp)
                    var nextAction = applyDeviations(base: nextBase, hand: hand, dealerUp: dealerUp)
                    // Double is not allowed after taking an extra card; treat as a hit
                    if hand.cards.count > 2 && nextAction == .double {
                        nextAction = .hit
                    }
                    currentAction = nextAction

                case .stand:
                    stood = true
                    actions.append(.stand)
                    break handLoop

                default:
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
}

// MARK: - UI

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

    @State private var hoursToSimulate: Double = 5
    @State private var handsPerHour: Double = 100
    @State private var numRealities: Int = 500
    @State private var bankroll: Double = 10000
    @State private var useDeviations: Bool = true
    @State private var debugEnabled: Bool = false

    @State private var result: SimulationResult?
    @State private var isSimulating: Bool = false
    @State private var completedSimulations: Int = 0
    @State private var startTime: Date?
    @State private var simulationTask: Task<Void, Never>?
    @State private var userCancelled: Bool = false

    @AppStorage("savedRuns") private var savedRunsData: Data = Data()
    @State private var savedRuns: [SavedRun] = []

    @State private var debugRecords: [DebugRecord] = []
    @State private var debugCSV: String = ""
    @State private var copyStatus: String?

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
                    debugSection
                }
                .padding()
            }
            .navigationTitle("Blackjack EV Lab")
            .onAppear(perform: loadSavedRuns)
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
            Toggle("Use basic deviations", isOn: $useDeviations)
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
                        Text(
                            String(
                                format: "EV/hr $%.2f | Sims %d | Hours/sim %.1f | Min bet $%.0f | RoR %.1f%%",
                                run.result.expectedValuePerHour,
                                run.input.numRealities,
                                run.input.hoursToSimulate,
                                run.input.betting.minBet,
                                run.result.riskOfRuin * 100
                            )
                        )
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
        guard !savedRunsData.isEmpty,
              let decoded = try? JSONDecoder().decode([SavedRun].self, from: savedRunsData)
        else {
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
        numRealities = run.input.numRealities
        bankroll = run.input.bankroll
        useDeviations = run.input.useBasicDeviations

        result = run.result
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

    private func removeSavedRun(at offsets: IndexSet) {
        savedRuns.remove(atOffsets: offsets)
        persistSavedRuns()
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
            "reality,handIndex,splitDepth,trueCount,playerCards,dealerUp,dealerHole,total,isSoft,action,wager,insuranceBet,bankrollStart,payout,bankrollEnd,result,playerFinal,dealerFinal"
        ]
        for r in records {
            let cards = r.playerCards.map(String.init).joined(separator: "-")
            let line = String(
                format: "%d,%d,%d,%.2f,%@,%d,%d,%d,%@,%@,%.2f,%.2f,%.2f,%.2f,%.2f,%@,%d,%d",
                r.realityIndex,
                r.handIndex,
                r.splitDepth,
                r.trueCount,
                cards,
                r.dealerUp,
                r.dealerHole,
                r.total,
                r.isSoft ? "1" : "0",
                r.action,
                r.wager,
                r.insuranceBet,
                r.bankrollStart,
                r.payout,
                r.bankrollEnd,
                r.result,
                r.playerFinal,
                r.dealerFinal
            )
            lines.append(line)
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
            hoursToSimulate: max(hoursToSimulate, 0.01),
            handsPerHour: max(handsPerHour, 1),
            numRealities: max(numRealities, 1),
            bankroll: bankroll,
            useBasicDeviations: useDeviations
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
                        self.savedRuns.append(saved)
                        self.persistSavedRuns()

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

@main
struct BlackJackAppV1App: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
