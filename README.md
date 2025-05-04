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
