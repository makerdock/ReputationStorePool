// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IVerificationsV4Reader {
    function getFid(address verifier) external view returns (uint256 fid);
}

contract FidScoreStore is Ownable {
    IVerificationsV4Reader public immutable verifications;
    
    // Constants for score calculation
    uint256 public constant SCORE_PRECISION = 1e18;
    uint256 public baselineFid = 100_000; // FIDs above this get minimum score
    uint256 public eliteFid = 1000;      // FIDs below this get maximum score
    
    // Score range
    uint256 public minScore = SCORE_PRECISION / 10;  // 0.1
    uint256 public maxScore = SCORE_PRECISION;       // 1.0
    
    // Optional score boosts/penalties
    mapping(address => int256) public scoreAdjustments; // Adjustments in basis points (+-10000 = +-100%)
    
    event BaselineUpdated(uint256 newBaseline);
    event EliteFidUpdated(uint256 newEliteFid);
    event ScoreRangeUpdated(uint256 newMin, uint256 newMax);
    event ScoreAdjustmentSet(address indexed user, int256 adjustment);
    
    error InvalidScoreRange();
    error InvalidFidRange();
    error InvalidAdjustment();
    
    constructor(
        IVerificationsV4Reader _verifications,
        uint256 _baselineFid,
        uint256 _eliteFid
    ) Ownable(msg.sender) {
        if (_eliteFid >= _baselineFid) revert InvalidFidRange();
        
        verifications = _verifications;
        baselineFid = _baselineFid;
        eliteFid = _eliteFid;
    }
    
    /// @notice Get the raw score for a user based on their FID
    /// @param user Address to check
    /// @return score between 0 and SCORE_PRECISION
    function getRawScore(address user) public view returns (uint256) {
        uint256 fid = verifications.getFid(user);
        
        // No FID = minimum score
        if (fid == 0) {
            return minScore;
        }
        
        // Elite FID = maximum score
        if (fid <= eliteFid) {
            return maxScore;
        }
        
        // Above baseline = minimum score
        if (fid >= baselineFid) {
            return minScore;
        }
        
        // Linear interpolation between elite and baseline
        uint256 fidRange = baselineFid - eliteFid;
        uint256 fidPosition = fid - eliteFid;
        uint256 scoreRange = maxScore - minScore;
        
        return maxScore - (scoreRange * fidPosition / fidRange);
    }
    
    /// @notice Get the final score for a user, including any adjustments
    /// @param user Address to check
    /// @return score between 0 and SCORE_PRECISION
    function getScore(address user) external view returns (uint256) {
        uint256 rawScore = getRawScore(user);
        int256 adjustment = scoreAdjustments[user];
        
        if (adjustment == 0) {
            return rawScore;
        }
        
        // Apply adjustment (can be positive or negative)
        int256 adjustedScore = int256(rawScore) * (10000 + adjustment) / 10000;
        
        // Ensure score stays within bounds
        if (adjustedScore < int256(minScore)) {
            return minScore;
        }
        if (adjustedScore > int256(maxScore)) {
            return maxScore;
        }
        
        return uint256(adjustedScore);
    }
    
    // Admin functions
    
    /// @notice Update the baseline FID (maximum FID for score calculation)
    function setBaselineFid(uint256 _baselineFid) external onlyOwner {
        if (_baselineFid <= eliteFid) revert InvalidFidRange();
        baselineFid = _baselineFid;
        emit BaselineUpdated(_baselineFid);
    }
    
    /// @notice Update the elite FID threshold (minimum FID for maximum score)
    function setEliteFid(uint256 _eliteFid) external onlyOwner {
        if (_eliteFid >= baselineFid) revert InvalidFidRange();
        eliteFid = _eliteFid;
        emit EliteFidUpdated(_eliteFid);
    }
    
    /// @notice Update the score range
    function setScoreRange(uint256 _minScore, uint256 _maxScore) external onlyOwner {
        if (_minScore >= _maxScore || _maxScore > SCORE_PRECISION) revert InvalidScoreRange();
        minScore = _minScore;
        maxScore = _maxScore;
        emit ScoreRangeUpdated(_minScore, _maxScore);
    }
    
    /// @notice Set a score adjustment for a specific address
    /// @param user Address to adjust
    /// @param adjustmentBps Adjustment in basis points (+-10000 = +-100%)
    function setScoreAdjustment(address user, int256 adjustmentBps) external onlyOwner {
        if (adjustmentBps < -10000 || adjustmentBps > 10000) revert InvalidAdjustment();
        scoreAdjustments[user] = adjustmentBps;
        emit ScoreAdjustmentSet(user, adjustmentBps);
    }
    
    /// @notice Batch set score adjustments
    function batchSetScoreAdjustments(
        address[] calldata users,
        int256[] calldata adjustmentsBps
    ) external onlyOwner {
        if (users.length != adjustmentsBps.length) revert InvalidAdjustment();
        
        for (uint256 i = 0; i < users.length; i++) {
            if (adjustmentsBps[i] < -10000 || adjustmentsBps[i] > 10000) revert InvalidAdjustment();
            scoreAdjustments[users[i]] = adjustmentsBps[i];
            emit ScoreAdjustmentSet(users[i], adjustmentsBps[i]);
        }
    }
}