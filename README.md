# Development Roadmap

## UUPS Proxy Pattern

* Familiarize yourself with [UUPS Proxy Pattern](https://docs.openzeppelin.com/contracts/4.x/api/proxy#UUPSUpgradeable).

You can upgrade your contract’s logic without losing data or changing the contract address.

## Adapt for Morpho Flash Loan Perp Loops

1. The v1 codebase is built for fixed-term, physically settled trades using Uniswap and Yield Protocol. Learn how this works, and what would need to be updated to move toward mPerps.
2. The UUPS proxy Contract is the main entry point for suers and interacts with the logic contracts.
3. Plan new logic:
   1. Integrate with Morpho Blue's flash loan interface.
   2. Handles the looping logic for leverage.
   3. Manages Collateral and position accounting.
4. You can deploy your new logic as an implementation, and point the proxy to it, if you'd like to keep the upgradeable pattern.

## 3.7 Advice

Key Components from Contango:

ContangoPositionNFT.sol:

* Tracks position ownership through NFTs
* Essential for position management

ExecutionProcessorLib.sol:

* Core logic for position management (increase, decrease, close, liquidate)
* Will be adapted for leveraged positions

Libraries (DataTypes.sol, CodecLib.sol, StorageLib.sol):

* Essential data structures and storage operations
* Adapted to include additional leverage-related fields

### New Components Added

MorphoFlashLoanHandler.sol:

* Handles flash loans from Morpho Blue
* Manages loan initiation and callback processing
* Provides utilities for calculating optimal leverage loops

PositionLeverager.sol:

* Core contract for creating and managing leveraged positions
* Implements the leverage loop logic for both long and short positions
* Uses Morpho for borrowing and Uniswap for swaps

PositionManager.sol:

* Provides position health monitoring
* Handles liquidation logic
* Allows users to manage collateral
* What to Keep/Remove:

Keep:

* Position NFT system for tracking ownership
* Storage patterns and libraries
* Position state management logic

Remove or Replace:

* All Yield Protocol specific code (commented out in DataTypes.sol)
* Fixed-rate market integrations
* Any expiry-based functionality not needed for perpetual positions

### Implementation Strategy

Leverage Loop Implementation:

* Uses flash loans to bootstrap the initial leverage
* For longs: Borrow USDT → Swap to BTC → Supply to Morpho → Borrow more USDT
* For shorts: Borrow BTC → Swap to USDT → Supply to Morpho → Borrow more BTC

Position Management:

* Track health factors using Chainlink price feeds
* Allow users to add/remove collateral
* Implement liquidation functionality

Integration with External Protocols:

* Morpho Blue for lending/borrowing
* Uniswap V3 for token swaps
* Chainlink for price oracles

The implemented contracts provide the foundation for a leveraged perpetual position system using Morpho Blue and Uniswap, which was your original goal. The system allows users to create leveraged long and short positions, manage their collateral, and provides liquidation mechanisms to ensure protocol safety.
