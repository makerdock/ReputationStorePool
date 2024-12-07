// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "@uniswap/v4-core/contracts/libraries/FullMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IScoreStore {
    function getScore(address user) external view returns (uint256);
}

contract BaseFeeHook is BaseHook, Ownable {
    using SafeERC20 for IERC20;

    IScoreStore public immutable scoreStore;
    address public feeCollector;
    
    // Fee configuration
    uint24 public minFee = 10;   // 0.1%
    uint24 public maxFee = 100;  // 1%
    uint256 public constant FEE_PRECISION = 10000;
    uint256 public constant SCORE_PRECISION = 1e18; // For handling decimals in score

    mapping(address => bool) public whitelistedAddresses;
    
    event FeeCollected(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 score,
        uint24 appliedFee
    );
    
    event FeeCollectorUpdated(address oldCollector, address newCollector);
    event FeeRangeUpdated(uint24 newMinFee, uint24 newMaxFee);
    event AddressWhitelisted(address indexed account);
    event AddressRemovedFromWhitelist(address indexed account);
    
    error InvalidFeeAmount();
    error FeeCollectionFailed();
    error TokenTransferFailed();
    error InvalidFeeCollector();
    error InvalidFeeRange();
    
    constructor(
        IPoolManager _poolManager,
        IScoreStore _scoreStore,
        address _feeCollector,
        uint24 _minFee,
        uint24 _maxFee
    ) BaseHook(_poolManager) Ownable(msg.sender) {
        if (_feeCollector == address(0)) revert InvalidFeeCollector();
        if (_minFee >= _maxFee) revert InvalidFeeRange();
        
        scoreStore = _scoreStore;
        feeCollector = _feeCollector;
        minFee = _minFee;
        maxFee = _maxFee;
    }

    function getHookPermissions() public pure override returns (Permissions) {
        return Permissions({
            beforeSwap: true,
            afterSwap: false,
            beforeModifyPosition: false,
            afterModifyPosition: false
        });
    }

    function getFeeForUser(address user) public view returns (uint24) {
        if (whitelistedAddresses[user]) {
            return 0;
        }
        
        uint256 score = scoreStore.getScore(user);
        
        // If score is 0 or no score, return max fee
        if (score == 0) {
            return maxFee;
        }
        
        // Calculate fee based on score (inverted - higher score means lower fee)
        // score is between 0 and SCORE_PRECISION (1e18)
        uint256 feeRange = maxFee - minFee;
        uint256 feeDelta = (feeRange * (SCORE_PRECISION - score)) / SCORE_PRECISION;
        
        return minFee + uint24(feeDelta);
    }

    function calculateFeeAmount(
        uint256 amount,
        uint24 fee,
        uint8 decimals
    ) internal pure returns (uint256) {
        uint256 scaledAmount = FullMath.mulDiv(
            amount,
            10**decimals,
            10**decimals
        );
        
        return FullMath.mulDiv(
            scaledAmount,
            fee,
            FEE_PRECISION
        );
    }

    function collectFee(
        address token,
        address user,
        uint256 amount,
        bool isPositive
    ) external returns (uint256 feeAmount) {
        require(msg.sender == address(this), "Only self-call");
        
        uint24 userFee = getFeeForUser(user);
        if (userFee == 0) return 0;
        
        uint8 decimals = IERC20(token).decimals();
        feeAmount = calculateFeeAmount(amount, userFee, decimals);
        
        if (feeAmount == 0) return 0;
        
        uint256 actualFeeAmount = isPositive ? feeAmount : amount - feeAmount;
        
        try IERC20(token).safeTransferFrom(
            user,
            feeCollector,
            actualFeeAmount
        ) {
            emit FeeCollected(
                user,
                token,
                actualFeeAmount,
                scoreStore.getScore(user),
                userFee
            );
        } catch {
            revert FeeCollectionFailed();
        }
        
        return feeAmount;
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override returns (bytes4) {
        address feeToken = params.zeroForOne ? key.currency0 : key.currency1;
        
        bool isPositive = params.amountSpecified > 0;
        uint256 absAmount = isPositive ? 
            uint256(params.amountSpecified) : 
            uint256(-params.amountSpecified);
            
        try this.collectFee(
            feeToken,
            sender,
            absAmount,
            isPositive
        ) returns (uint256 feeAmount) {
            if (feeAmount > absAmount) revert InvalidFeeAmount();
        } catch (bytes memory) {
            revert FeeCollectionFailed();
        }
        
        return BaseHook.beforeSwap.selector;
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4) {
        return BaseHook.afterSwap.selector;
    }

    function beforeModifyPosition(
        address,
        PoolKey calldata,
        IPoolManager.ModifyPositionParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        return BaseHook.beforeModifyPosition.selector;
    }

    function afterModifyPosition(
        address,
        PoolKey calldata,
        IPoolManager.ModifyPositionParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4) {
        return BaseHook.afterModifyPosition.selector;
    }

    // Admin functions
    function setFeeCollector(address _newCollector) external onlyOwner {
        if (_newCollector == address(0)) revert InvalidFeeCollector();
        
        address oldCollector = feeCollector;
        feeCollector = _newCollector;
        emit FeeCollectorUpdated(oldCollector, _newCollector);
    }

    function setFeeRange(uint24 _minFee, uint24 _maxFee) external onlyOwner {
        if (_minFee >= _maxFee) revert InvalidFeeRange();
        
        minFee = _minFee;
        maxFee = _maxFee;
        emit FeeRangeUpdated(_minFee, _maxFee);
    }

    function addToWhitelist(address account) external onlyOwner {
        whitelistedAddresses[account] = true;
        emit AddressWhitelisted(account);
    }

    function removeFromWhitelist(address account) external onlyOwner {
        whitelistedAddresses[account] = false;
        emit AddressRemovedFromWhitelist(account);
    }

    // Emergency functions
    function rescueTokens(address token, uint256 amount) external {
        require(msg.sender == feeCollector, "Only fee collector");
        IERC20(token).safeTransfer(feeCollector, amount);
    }
}