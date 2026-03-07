// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CommitRevealAuction.sol";

/**
 * @title VickreyAuction
 * @author Victor Giwa (@0xgiwa)
 * @notice Second-price sealed-bid auction (Vickrey auction)
 * @dev Winner pays the SECOND highest bid price, not their own bid
 * 
 * Why Vickrey?
 * - Incentive-compatible: Bidding your true value is the dominant strategy
 * - No winner's curse: You never overpay relative to other valuations
 * - Nobel Prize-winning mechanism design (William Vickrey, 1996)
 * 
 * Example:
 * - Alice bids 100 ETH
 * - Bob bids 80 ETH
 * - Carol bids 60 ETH
 * - Alice wins but pays only 80 ETH (Bob's bid)
 */
contract VickreyAuction is CommitRevealAuction {
    
    // ============ State Variables ============
    
    uint256 public secondHighestBid;
    address public beneficiary;
    
    // ============ Events ============
    
    event SecondPriceUpdated(uint256 amount);
    
    // ============ Constructor ============
    
    /**
     * @notice Initialize Vickrey auction
     * @param _commitDuration Duration of commit phase in seconds
     * @param _revealDuration Duration of reveal phase in seconds  
     * @param _reservePrice Minimum deposit required
     * @param _beneficiary Address to receive winning payment
     */
    constructor(
        uint256 _commitDuration,
        uint256 _revealDuration,
        uint256 _reservePrice,
        address _beneficiary
    ) CommitRevealAuction(_commitDuration, _revealDuration, _reservePrice) {
        require(_beneficiary != address(0), "Invalid beneficiary");
        beneficiary = _beneficiary;
    }
    
    // ============ Override Functions ============
    
    /**
     * @notice Reveal bid with second-price tracking
     * @param _amount The actual bid amount
     * @param _secret The secret used in commitment
     */
    function revealBid(uint256 _amount, bytes32 _secret) external override {
        // Auto-transition to reveal phase if needed
        if (phase == AuctionPhase.Commit && block.timestamp >= commitDeadline) {
            phase = AuctionPhase.Reveal;
        }
        
        if (phase != AuctionPhase.Reveal) {
            revert InvalidPhase(AuctionPhase.Reveal, phase);
        }
        if (block.timestamp >= revealDeadline) {
            revert DeadlinePassed();
        }
        
        Commitment storage c = commitments[msg.sender];
        
        if (c.hash == bytes32(0)) {
            revert NoCommitmentFound();
        }
        if (c.revealed) {
            revert AlreadyRevealed();
        }
        
        // Verify commitment
        bytes32 expectedHash = keccak256(abi.encodePacked(_amount, _secret));
        if (c.hash != expectedHash) {
            revert InvalidReveal();
        }
        if (_amount > c.deposit) {
            revert BidExceedsDeposit();
        }
        
        c.revealed = true;
        
        // Update highest and second-highest bids
        if (_amount > highestBid) {
            // New highest - old highest becomes second
            secondHighestBid = highestBid;
            highestBid = _amount;
            highestBidder = msg.sender;
            
            if (secondHighestBid > 0) {
                emit SecondPriceUpdated(secondHighestBid);
            }
        } else if (_amount > secondHighestBid) {
            // New second highest
            secondHighestBid = _amount;
            emit SecondPriceUpdated(secondHighestBid);
        }
        
        emit BidRevealed(msg.sender, _amount);
    }
    
    /**
     * @notice Handle settlement - winner pays second-highest price
     * @param winner Address of the winning bidder
     */
    function _handleSettlement(address winner, uint256) internal override {
        // Winner pays second-highest bid (or reserve if only one bidder)
        uint256 payment = secondHighestBid > 0 ? secondHighestBid : reservePrice;
        
        Commitment storage winnerCommitment = commitments[winner];
        
        // Refund excess deposit to winner
        uint256 refund = winnerCommitment.deposit - payment;
        winnerCommitment.deposit = 0; // Prevent double withdrawal
        
        // Transfer payment to beneficiary
        (bool successBeneficiary, ) = payable(beneficiary).call{value: payment}("");
        require(successBeneficiary, "Beneficiary transfer failed");
        
        // Refund excess to winner
        if (refund > 0) {
            (bool successRefund, ) = payable(winner).call{value: refund}("");
            require(successRefund, "Refund transfer failed");
        }
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get the price winner will pay (second-highest or reserve)
     */
    function getWinnerPrice() external view returns (uint256) {
        return secondHighestBid > 0 ? secondHighestBid : reservePrice;
    }
}
