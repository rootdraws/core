// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "./ContangoPositionNFT.sol";
import "./PositionLeverager.sol";
import "./libraries/DataTypes.sol";
import "./libraries/CodecLib.sol";
import "./libraries/StorageLib.sol";

contract PositionManager is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;
    using CodecLib for uint256;
    
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    
    // Minimum health factor (scaled by 1e18)
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    // Liquidation threshold (scaled by 1e18)
    uint256 public constant LIQUIDATION_THRESHOLD = 1.05e18;
    // Liquidation bonus (scaled by 1e18, e.g., 1.1e18 = 10% bonus)
    uint256 public constant LIQUIDATION_BONUS = 1.1e18;
    
    ContangoPositionNFT public positionNFT;
    PositionLeverager public positionLeverager;
    
    // Oracle addresses for price feeds
    mapping(address => AggregatorV3Interface) public priceFeeds;
    
    event PositionHealthUpdated(
        PositionId indexed positionId,
        address indexed trader,
        uint256 healthFactor
    );
    
    event PositionLiquidated(
        PositionId indexed positionId,
        address indexed trader,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralLiquidated,
        uint256 liquidationBonus
    );
    
    constructor(
        address _positionNFT,
        address _positionLeverager
    ) {
        positionNFT = ContangoPositionNFT(_positionNFT);
        positionLeverager = PositionLeverager(_positionLeverager);
        
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(OPERATOR_ROLE, msg.sender);
        _setupRole(LIQUIDATOR_ROLE, msg.sender);
    }
    
    // Get current health factor of a position
    function getHealthFactor(PositionId positionId) public view returns (uint256) {
        // Get position details
        (uint256 openQuantity, uint256 openCost) = StorageLib.getPositionNotionals()[positionId].decodeU128();
        (int256 collateral,) = StorageLib.getPositionBalances()[positionId].decodeI128();
        
        if (openCost == 0) return type(uint256).max; // No debt means infinite health
        
        Symbol symbol = StorageLib.getPositionInstrument()[positionId];
        Position memory position = _getPositionDetails(symbol, positionId, openQuantity, openCost, collateral);
        
        // Get current prices for collateral and borrowed tokens
        uint256 collateralValue;
        uint256 debtValue;
        
        if (position.isLong) {
            // For longs, collateralValue is collateral token value
            collateralValue = getCurrentValue(position.collateralToken, openQuantity);
            debtValue = openCost; // Debt value is the borrowed amount
        } else {
            // For shorts, collateralValue is the borrow token collateral
            collateralValue = openQuantity; // Already in stable value
            debtValue = getCurrentValue(position.collateralToken, openCost);
        }
        
        // Calculate health factor: collateralValue / debtValue
        // Lower than 1.0 means underwater position
        return (collateralValue * 1e18) / debtValue;
    }
    
    // Liquidate an unhealthy position
    function liquidatePosition(PositionId positionId) external nonReentrant onlyRole(LIQUIDATOR_ROLE) {
        uint256 healthFactor = getHealthFactor(positionId);
        require(healthFactor < MIN_HEALTH_FACTOR, "Position is healthy");
        
        // Get position details
        (uint256 openQuantity, uint256 openCost) = StorageLib.getPositionNotionals()[positionId].decodeU128();
        (int256 collateral,) = StorageLib.getPositionBalances()[positionId].decodeI128();
        
        Symbol symbol = StorageLib.getPositionInstrument()[positionId];
        Position memory position = _getPositionDetails(symbol, positionId, openQuantity, openCost, collateral);
        
        address trader = positionNFT.positionOwner(positionId);
        
        // Calculate liquidation amounts
        uint256 debtRepaid;
        uint256 collateralLiquidated;
        uint256 liquidationBonus;
        
        if (position.isLong) {
            // For longs, we sell collateral to repay debt
            debtRepaid = openCost;
            collateralLiquidated = getCurrentValue(position.borrowToken, debtRepaid) * LIQUIDATION_BONUS / 1e18;
            liquidationBonus = collateralLiquidated - getCurrentValue(position.borrowToken, debtRepaid);
        } else {
            // For shorts, we use the stable collateral to repay the borrowed collateral token
            collateralLiquidated = openCost;
            debtRepaid = getCurrentValue(position.collateralToken, collateralLiquidated) * LIQUIDATION_BONUS / 1e18;
            liquidationBonus = debtRepaid - getCurrentValue(position.collateralToken, collateralLiquidated);
        }
        
        // Execute the liquidation through the leverager contract
        // This is a placeholder - the actual implementation would:
        // 1. Withdraw collateral from Morpho
        // 2. Repay debt
        // 3. Send liquidation bonus to liquidator
        // 4. Send remaining funds to the trader if any
        
        // For now, we'll just clear the position data
        delete StorageLib.getPositionNotionals()[positionId];
        delete StorageLib.getPositionBalances()[positionId];
        delete StorageLib.getPositionInstrument()[positionId];
        
        // Burn the position NFT
        positionNFT.burn(positionId);
        
        emit PositionLiquidated(
            positionId,
            trader,
            msg.sender,
            debtRepaid,
            collateralLiquidated,
            liquidationBonus
        );
    }
    
    // Add collateral to a position
    function addCollateral(PositionId positionId, uint256 amount) external nonReentrant {
        require(positionNFT.positionOwner(positionId) == msg.sender, "Not position owner");
        
        Symbol symbol = StorageLib.getPositionInstrument()[positionId];
        (uint256 openQuantity, uint256 openCost) = StorageLib.getPositionNotionals()[positionId].decodeU128();
        (int256 collateral,) = StorageLib.getPositionBalances()[positionId].decodeI128();
        
        Position memory position = _getPositionDetails(symbol, positionId, openQuantity, openCost, collateral);
        
        // Transfer tokens from user
        IERC20 token = IERC20(position.isLong ? position.collateralToken : position.borrowToken);
        token.safeTransferFrom(msg.sender, address(this), amount);
        
        // Update the position balance
        StorageLib.getPositionBalances()[positionId] = CodecLib.encodeI128(
            collateral + int256(amount),
            0 // No change in protocol fees
        );
        
        // Update health factor
        uint256 healthFactor = getHealthFactor(positionId);
        emit PositionHealthUpdated(positionId, msg.sender, healthFactor);
    }
    
    // Remove collateral from a position
    function removeCollateral(PositionId positionId, uint256 amount) external nonReentrant {
        require(positionNFT.positionOwner(positionId) == msg.sender, "Not position owner");
        
        Symbol symbol = StorageLib.getPositionInstrument()[positionId];
        (uint256 openQuantity, uint256 openCost) = StorageLib.getPositionNotionals()[positionId].decodeU128();
        (int256 collateral,) = StorageLib.getPositionBalances()[positionId].decodeI128();
        
        Position memory position = _getPositionDetails(symbol, positionId, openQuantity, openCost, collateral);
        
        // Make sure there's enough collateral to remove
        require(collateral >= int256(amount), "Insufficient collateral");
        
        // Update the position balance
        StorageLib.getPositionBalances()[positionId] = CodecLib.encodeI128(
            collateral - int256(amount),
            0 // No change in protocol fees
        );
        
        // Check if health factor is still good
        uint256 healthFactor = getHealthFactor(positionId);
        require(healthFactor >= LIQUIDATION_THRESHOLD, "Withdrawal would make position liquidatable");
        
        // Transfer tokens to user
        IERC20 token = IERC20(position.isLong ? position.collateralToken : position.borrowToken);
        token.safeTransfer(msg.sender, amount);
        
        emit PositionHealthUpdated(positionId, msg.sender, healthFactor);
    }
    
    // Internal function to get current value using price feed
    function getCurrentValue(address token, uint256 amount) internal view returns (uint256) {
        AggregatorV3Interface priceFeed = priceFeeds[token];
        require(address(priceFeed) != address(0), "No price feed for token");
        
        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price");
        
        uint8 decimals = priceFeed.decimals();
        
        // Return value in USD (normalized to 18 decimals)
        return (amount * uint256(price)) / (10 ** decimals);
    }
    
    // Internal function to get position details
    function _getPositionDetails(
        Symbol symbol,
        PositionId positionId,
        uint256 openQuantity,
        uint256 openCost,
        int256 collateral
    ) internal view returns (Position memory) {
        Position memory position;
        position.symbol = symbol;
        position.openQuantity = openQuantity;
        position.openCost = openCost;
        position.collateral = collateral;
        
        // Extract position details from the symbol
        // In a real implementation, you'd decode this from storage
        // This is a placeholder for how you might extract the tokens and position type
        position.isLong = uint8(bytes32(symbol)[0]) > 128;
        position.collateralToken = address(uint160(uint256(symbol) >> 96));
        position.borrowToken = address(uint160(uint256(symbol) >> 64));
        
        return position;
    }
    
    // Admin functions
    
    function setPriceFeed(address token, address priceFeed) external onlyRole(OPERATOR_ROLE) {
        priceFeeds[token] = AggregatorV3Interface(priceFeed);
    }
    
    function addLiquidator(address liquidator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(LIQUIDATOR_ROLE, liquidator);
    }
    
    function removeLiquidator(address liquidator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(LIQUIDATOR_ROLE, liquidator);
    }
} 