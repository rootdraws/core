// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import "./MorphoFlashLoanHandler.sol";
import "./ContangoPositionNFT.sol";
import "./libraries/DataTypes.sol";
import "./libraries/CodecLib.sol";
import "./libraries/StorageLib.sol";

contract PositionLeverager is ReentrancyGuard, AccessControl, IMorphoFlashLoanReceiver {
    using SafeERC20 for IERC20;
    using CodecLib for uint256;
    
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    
    ContangoPositionNFT public positionNFT;
    address public treasury;
    IMorpho public morpho;
    ISwapRouter public uniswapRouter;
    
    // Markets for different assets in Morpho
    mapping(address => address) public morphoMarkets;
    
    // Fee percentage in basis points (e.g., 30 = 0.3%)
    uint256 public protocolFeeBps = 30;
    
    // Liquidation threshold by token (in percentage, e.g., 80 = 80%)
    mapping(address => uint256) public liquidationThresholds;
    
    event PositionCreated(
        PositionId indexed positionId,
        address indexed trader,
        address collateralToken,
        address borrowToken,
        uint256 initialCollateral,
        uint256 targetLeverage,
        bool isLong
    );
    
    event PositionClosed(
        PositionId indexed positionId,
        address indexed trader,
        uint256 returnedAmount,
        int256 pnl
    );
    
    event PositionLiquidated(
        PositionId indexed positionId,
        address indexed trader,
        address liquidator,
        uint256 debtRepaid,
        uint256 collateralLiquidated
    );

    constructor(
        address _morpho,
        address _uniswapRouter,
        address _positionNFT,
        address _treasury
    ) {
        morpho = IMorpho(_morpho);
        uniswapRouter = ISwapRouter(_uniswapRouter);
        positionNFT = ContangoPositionNFT(_positionNFT);
        treasury = _treasury;
        
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(OPERATOR_ROLE, msg.sender);
    }
    
    // Create a new leveraged position
    function createLeveragedPosition(
        address collateralToken,
        address borrowToken,
        uint256 collateralAmount,
        uint256 targetLeverage,
        uint24 uniswapFee,
        bool isLong
    ) external nonReentrant returns (PositionId positionId) {
        require(collateralAmount > 0, "Collateral must be greater than 0");
        require(targetLeverage > 1, "Leverage must be greater than 1");
        require(targetLeverage <= 20, "Leverage too high");
        require(morphoMarkets[borrowToken] != address(0), "Borrow market not supported");
        require(liquidationThresholds[collateralToken] > 0, "Collateral not supported");
        
        // Transfer collateral from user
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);
        
        // Mint position NFT to track ownership
        positionId = positionNFT.mint(msg.sender);
        
        // Create a symbol for the position
        Symbol symbol = Symbol.wrap(keccak256(abi.encodePacked(
            collateralToken,
            borrowToken,
            targetLeverage,
            isLong,
            block.timestamp
        )));
        
        // Store position details
        StorageLib.getPositionInstrument()[positionId] = symbol;
        
        // Calculate optimal flash loan amount based on leverage target
        uint256 flashLoanAmount;
        if (isLong) {
            // For longs, we flash loan the borrow token to leverage up collateral
            flashLoanAmount = collateralAmount * (targetLeverage - 1);
        } else {
            // For shorts, we flash loan the collateral token to short it
            flashLoanAmount = collateralAmount * targetLeverage;
        }
        
        // Create leveraged position struct
        MorphoFlashLoanHandler.LeveragedPosition memory position = MorphoFlashLoanHandler.LeveragedPosition({
            symbol: symbol,
            positionId: positionId,
            trader: msg.sender,
            collateralToken: collateralToken,
            borrowToken: borrowToken,
            initialCollateral: collateralAmount,
            totalCollateral: collateralAmount,
            totalBorrowed: 0,
            leverageTarget: targetLeverage,
            liquidationThreshold: liquidationThresholds[collateralToken],
            isLong: isLong
        });
        
        // Extra data for the flash loan callback
        bytes memory extraData = abi.encode(uniswapFee);
        
        // Initiate the leverage loop via flash loan
        MorphoFlashLoanHandler.initiateFlashLoan(position, flashLoanAmount, extraData);
        
        emit PositionCreated(
            positionId,
            msg.sender,
            collateralToken,
            borrowToken,
            collateralAmount,
            targetLeverage,
            isLong
        );
        
        return positionId;
    }
    
    // Morpho Flash Loan callback
    function onMorphoFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        require(msg.sender == address(morpho), "Unauthorized flashloan callback");
        require(initiator == address(this), "Unauthorized flashloan initiator");
        
        MorphoFlashLoanHandler.FlashLoanCallback memory callback = abi.decode(data, (MorphoFlashLoanHandler.FlashLoanCallback));
        uint24 uniswapFee = abi.decode(callback.extraData, (uint24));
        
        if (callback.position.isLong) {
            executeLongPosition(callback, token, amount, fee, uniswapFee);
        } else {
            executeShortPosition(callback, token, amount, fee, uniswapFee);
        }
        
        return keccak256("MorphoFlashLoanHandler.onMorphoFlashLoan");
    }
    
    // Execute a leveraged long position
    function executeLongPosition(
        MorphoFlashLoanHandler.FlashLoanCallback memory callback,
        address token,
        uint256 amount,
        uint256 fee,
        uint24 uniswapFee
    ) internal {
        MorphoFlashLoanHandler.LeveragedPosition memory position = callback.position;
        
        // Step 1: Swap borrowed tokens for collateral token via Uniswap
        IERC20(token).approve(address(uniswapRouter), amount);
        
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: token,
            tokenOut: position.collateralToken,
            fee: uniswapFee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amount,
            amountOutMinimum: 0, // Can add slippage protection here
            sqrtPriceLimitX96: 0
        });
        
        uint256 amountOut = uniswapRouter.exactInputSingle(params);
        
        // Step 2: Supply collateral to Morpho
        uint256 totalCollateral = position.initialCollateral + amountOut;
        IERC20(position.collateralToken).approve(address(morpho), totalCollateral);
        
        morpho.supply(
            morphoMarkets[position.collateralToken],
            totalCollateral,
            0, // Min shares 
            address(this),
            bytes("")
        );
        
        // Step 3: Borrow enough to repay flash loan + fee
        uint256 borrowAmount = amount + fee;
        morpho.borrow(
            morphoMarkets[token],
            borrowAmount,
            0, // Min shares
            address(this),
            address(this),
            bytes("")
        );
        
        // Step 4: Repay flash loan + fee
        IERC20(token).approve(address(morpho), borrowAmount);
        
        // Update position data
        StorageLib.getPositionNotionals()[position.positionId] = CodecLib.encodeU128(
            totalCollateral, // openQuantity represents total collateral
            borrowAmount     // openCost represents total debt
        );
        
        // Collateral is the trader's equity: totalCollateral - borrowAmount
        int256 equity = int256(totalCollateral) - int256(borrowAmount);
        StorageLib.getPositionBalances()[position.positionId] = CodecLib.encodeI128(
            equity,
            0 // No protocol fees stored yet
        );
    }
    
    // Execute a leveraged short position
    function executeShortPosition(
        MorphoFlashLoanHandler.FlashLoanCallback memory callback,
        address token,
        uint256 amount,
        uint256 fee,
        uint24 uniswapFee
    ) internal {
        MorphoFlashLoanHandler.LeveragedPosition memory position = callback.position;
        
        // Step 1: Swap flash loaned collateral for borrow token
        IERC20(token).approve(address(uniswapRouter), amount);
        
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: token,
            tokenOut: position.borrowToken,
            fee: uniswapFee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amount,
            amountOutMinimum: 0, // Can add slippage protection here
            sqrtPriceLimitX96: 0
        });
        
        uint256 amountOut = uniswapRouter.exactInputSingle(params);
        
        // Step 2: Supply borrow token (USDT0) to Morpho as collateral 
        uint256 borrowTokenCollateral = amountOut + position.initialCollateral;
        IERC20(position.borrowToken).approve(address(morpho), borrowTokenCollateral);
        
        morpho.supply(
            morphoMarkets[position.borrowToken],
            borrowTokenCollateral,
            0, // Min shares
            address(this),
            bytes("")
        );
        
        // Step 3: Borrow collateral token to repay flash loan
        uint256 borrowAmount = amount + fee;
        morpho.borrow(
            morphoMarkets[token],
            borrowAmount,
            0, // Min shares
            address(this),
            address(this),
            bytes("")
        );
        
        // Step 4: Repay flash loan + fee
        IERC20(token).approve(address(morpho), borrowAmount);
        
        // Update position data
        StorageLib.getPositionNotionals()[position.positionId] = CodecLib.encodeU128(
            borrowTokenCollateral, // openQuantity represents total borrow token collateral
            borrowAmount           // openCost represents total borrowed collateral token
        );
        
        // Calculate position equity
        // For a short, we need to convert borrowAmount to borrowToken value for comparison
        // This is simplified - in reality you'd use an oracle price
        int256 equity = int256(borrowTokenCollateral) - int256(borrowAmount);
        StorageLib.getPositionBalances()[position.positionId] = CodecLib.encodeI128(
            equity,
            0 // No protocol fees stored yet
        );
    }
    
    // Close a leveraged position and return funds to user
    function closePosition(PositionId positionId) external nonReentrant {
        require(positionNFT.positionOwner(positionId) == msg.sender, "Not position owner");
        
        // Implement position closing logic:
        // 1. Withdraw collateral from Morpho
        // 2. Swap to repay debt
        // 3. Repay debt
        // 4. Send remaining funds to user
        // 5. Burn position NFT
        
        // This is a placeholder for the actual implementation
        positionNFT.burn(positionId);
    }
    
    // Admin functions
    
    function setMorphoMarket(address token, address market) external onlyRole(OPERATOR_ROLE) {
        morphoMarkets[token] = market;
    }
    
    function setLiquidationThreshold(address token, uint256 threshold) external onlyRole(OPERATOR_ROLE) {
        require(threshold > 0 && threshold <= 95, "Invalid threshold");
        liquidationThresholds[token] = threshold;
    }
    
    function setProtocolFee(uint256 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFeeBps <= 100, "Fee too high"); // Max 1%
        protocolFeeBps = newFeeBps;
    }
    
    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTreasury != address(0), "Zero address");
        treasury = newTreasury;
    }
} 