// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./libraries/DataTypes.sol";

interface IMorpho {
    function supply(
        address market,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256);
    
    function borrow(
        address market,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver,
        bytes calldata data
    ) external returns (uint256, uint256);
    
    function repay(
        address market,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256);
    
    function withdraw(
        address market,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver,
        bytes calldata data
    ) external returns (uint256, uint256);
    
    function flashLoan(
        address receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external;
}

interface IMorphoFlashLoanReceiver {
    function onMorphoFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32);
}

library MorphoFlashLoanHandler {
    using Address for address;
    using SafeERC20 for IERC20;

    struct LeveragedPosition {
        Symbol symbol;
        PositionId positionId;
        address trader;
        address collateralToken;
        address borrowToken;
        uint256 initialCollateral;
        uint256 totalCollateral;
        uint256 totalBorrowed;
        uint256 leverageTarget;
        uint256 liquidationThreshold;
        bool isLong;
    }

    struct FlashLoanCallback {
        LeveragedPosition position;
        uint256 currentLoop;
        uint256 totalLoops;
        bytes extraData;
    }

    // Using properly checksummed address
    address public constant MORPHO = 0x64c7d40C07EFabC7E93507C4936a869072CAFB45; // Replace with actual Morpho Blue address

    event LeverageLoopInitiated(
        Symbol indexed symbol,
        PositionId indexed positionId,
        address indexed trader,
        uint256 initialCollateral,
        uint256 targetLeverage,
        bool isLong
    );

    event LeverageLoopCompleted(
        Symbol indexed symbol,
        PositionId indexed positionId,
        address indexed trader,
        uint256 totalCollateral,
        uint256 totalBorrowed,
        uint256 actualLeverage,
        bool isLong
    );

    function initiateFlashLoan(
        LeveragedPosition memory position,
        uint256 flashLoanAmount,
        bytes memory extraData
    ) internal {
        FlashLoanCallback memory callback = FlashLoanCallback({
            position: position,
            currentLoop: 0,
            totalLoops: calculateOptimalLoops(position.leverageTarget),
            extraData: extraData
        });

        // Emit event for leverage loop initiation
        emit LeverageLoopInitiated(
            position.symbol,
            position.positionId,
            position.trader,
            position.initialCollateral,
            position.leverageTarget,
            position.isLong
        );

        // Initiate flash loan from Morpho
        IMorpho(MORPHO).flashLoan(
            address(this),
            position.isLong ? position.borrowToken : position.collateralToken,
            flashLoanAmount,
            abi.encode(callback)
        );
    }

    function calculateOptimalLoops(uint256 targetLeverage) internal pure returns (uint256) {
        // Higher leverage requires more loops
        // This is a simple heuristic - can be optimized based on gas costs vs. precision
        if (targetLeverage <= 2) return 1;
        if (targetLeverage <= 5) return 2;
        if (targetLeverage <= 10) return 3;
        return 4; // Cap at 4 loops for very high leverage
    }

    // Calculate how much can be borrowed safely given collateral and liquidation threshold
    function calculateSafeBorrowAmount(
        uint256 collateralValue,
        uint256 liquidationThreshold
    ) internal pure returns (uint256) {
        // Add a safety buffer (e.g., 95% of theoretical max)
        return (collateralValue * liquidationThreshold * 95) / (100 * 100);
    }
} 