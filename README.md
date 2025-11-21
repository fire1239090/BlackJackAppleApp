# Blackjack EV Simulator (Hi-Lo)

This project is a SwiftUI iOS app that estimates the expected hourly value for a card counter using the Hi-Lo system. You can configure table rules, bet spread, bankroll, and simulation volume to see EV/hour, standard deviation, risk of ruin, and time-to-profit milestones.

## Prerequisites
- Xcode 15 or newer on macOS.
- iOS 17 simulator or device target.

## How to build and run
1. Clone or download this repository.
2. Open `BlackJackAppV1.xcodeproj` in Xcode.
3. Select an iOS Simulator (e.g., iPhone 15) or a connected device.
4. Press **Run** (⌘R) to build and launch the app.

## Using the simulator UI
1. On launch, fill out the form:
   - **Rules**: decks, dealer hits/stands on soft 17, double after split, surrender, blackjack payout, and shoe penetration.
   - **Bet Spread**: minimum bet, maximum bet, and the true-count at which the max bet is placed (linear ramp is used between min and max).
   - **Simulation Settings**: hands to simulate, hands per hour, bankroll, and toggle for **Basic Deviations** (enables common index-based departures from basic strategy).
2. Tap **Run Simulation**. The app will run an asynchronous Monte Carlo simulation with a shuffled shoe, count tracking, betting ramp, and basic strategy plus deviations when enabled.
3. When finished, the results screen shows:
   - Expected value and standard deviation per hour.
   - Risk of ruin for the given bankroll.
   - Average and median bet size.
   - Estimated hours to reach 50%, 90%, and 99% probability of being profitable ("in the green").

## Tips for first-time users
- Start with a moderate number of simulated hands (e.g., 50,000) to get a quick result, then increase for stability.
- Use realistic hands-per-hour values for your table speed (e.g., ~100 for full tables, ~200 heads-up).
- Adjust penetration to match the cut-card placement (e.g., 0.75 for dealing 75% of the shoe).
- Enable Basic Deviations if you want common index plays applied; disable to see pure basic strategy.

## Troubleshooting
- If you see negative EV, revisit the bet spread or rules—tight penetration, low max bet, or harsh rules can outweigh the counting edge.
- Ensure blackjack payout is 3:2 for traditional games; 6:5 payouts will usually produce negative EV even with counting.
- For fastest results, run on a physical device; simulators may take longer for large simulations.
