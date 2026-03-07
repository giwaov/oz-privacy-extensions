// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title CommitRevealAuction
 * @author Victor Giwa (@0xgiwa)
 * @notice Sealed-bid auction using commit-reveal scheme to prevent front-running
 * @dev Abstract contract - inherit and implement _handleSettlement()
 * 
 * The auction proceeds in three phases:
 * 1. COMMIT: Bidders submit hash(bidAmount, secret) with deposit
 * 2. REVEAL: Bidders reveal their bids, contract verifies hash
 * 3. SETTLED: Winner determined, losers can withdraw deposits
 */
abstract contract CommitRevealAuction is Ownable, ReentrancyGuard {
    
    // ============ Types ============
    
    enum AuctionPhase { 
        Inactive,   // Auction not started
        Commit,     // Accepting sealed bids
        Reveal,     // Bidders revealing their bids
        Settled     // Auction complete
    }
    
    struct Commitment {
        bytes32 hash;       // keccak256(bidAmount, secret)
        uint256 deposit;    // ETH deposited with commitment
        bool revealed;      // Whether bid has been revealed
    }
    
    // ============ State Variables ============
    
    AuctionPhase public phase;
    
    uint256 public commitDeadline;
    uint256 public revealDeadline;
    uint256 public reservePrice;
    
    address public highestBidder;
    uint256 public highestBid;
    uint256 public totalCommitments;
    
    mapping(address => Commitment) public commitments;
    
    // ============ Events ============
    
    event AuctionStarted(uint256 commitDeadline, uint256 revealDeadline, uint256 reservePrice);
    event BidCommitted(address indexed bidder, bytes32 commitment, uint256 deposit);
    event BidRevealed(address indexed bidder, uint256 amount);
    event AuctionSettled(address indexed winner, uint256 amount);
    event DepositWithdrawn(address indexed bidder, uint256 amount);
    
    // ============ Errors ============
    
    error InvalidPhase(AuctionPhase expected, AuctionPhase actual);
    error DeadlinePassed();
    error DeadlineNotPassed();
    error DepositBelowReserve();
    error AlreadyCommitted();
    error NoCommitmentFound();
    error AlreadyRevealed();
    error InvalidReveal();
    error BidExceedsDeposit();
    error NotEligibleForWithdraw();
    error NothingToWithdraw();
    
    // ============ Constructor ============
    
    /**
     * @notice Initialize auction parameters
     * @param _commitDuration Duration of commit phase in seconds
     * @param _revealDuration Duration of reveal phase in seconds
     * @param _reservePrice Minimum deposit required (should be >= expected max bid)
     */
    constructor(
        uint256 _commitDuration,
        uint256 _revealDuration,
        uint256 _reservePrice
    ) Ownable(msg.sender) {
        require(_commitDuration > 0, "Commit duration must be > 0");
        require(_revealDuration > 0, "Reveal duration must be > 0");
        
        commitDeadline = block.timestamp + _commitDuration;
        revealDeadline = commitDeadline + _revealDuration;
        reservePrice = _reservePrice;
        phase = AuctionPhase.Commit;
        
        emit AuctionStarted(commitDeadline, revealDeadline, _reservePrice);
    }
    
    // ============ External Functions ============
    
    /**
     * @notice Submit a sealed bid commitment
     * @param _commitment Hash of (bidAmount, secret) - use keccak256(abi.encodePacked(amount, secret))
     * @dev Deposit must be >= reservePrice. Actual bid can be <= deposit.
     */
    function commitBid(bytes32 _commitment) external payable {
        if (phase != AuctionPhase.Commit) {
            revert InvalidPhase(AuctionPhase.Commit, phase);
        }
        if (block.timestamp >= commitDeadline) {
            revert DeadlinePassed();
        }
        if (msg.value < reservePrice) {
            revert DepositBelowReserve();
        }
        if (commitments[msg.sender].hash != bytes32(0)) {
            revert AlreadyCommitted();
        }
        
        commitments[msg.sender] = Commitment({
            hash: _commitment,
            deposit: msg.value,
            revealed: false
        });
        
        totalCommitments++;
        
        emit BidCommitted(msg.sender, _commitment, msg.value);
    }
    
    /**
     * @notice Transition from commit to reveal phase
     * @dev Anyone can call this after commit deadline
     */
    function startRevealPhase() external {
        if (phase != AuctionPhase.Commit) {
            revert InvalidPhase(AuctionPhase.Commit, phase);
        }
        if (block.timestamp < commitDeadline) {
            revert DeadlineNotPassed();
        }
        
        phase = AuctionPhase.Reveal;
    }
    
    /**
     * @notice Reveal a previously committed bid
     * @param _amount The actual bid amount
     * @param _secret The secret used in commitment
     */
    function revealBid(uint256 _amount, bytes32 _secret) external {
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
        
        // Update highest bid if this one wins
        if (_amount > highestBid) {
            highestBid = _amount;
            highestBidder = msg.sender;
        }
        
        emit BidRevealed(msg.sender, _amount);
    }
    
    /**
     * @notice Settle the auction after reveal phase ends
     * @dev Anyone can call this after reveal deadline
     */
    function settle() external nonReentrant {
        // Auto-transition if needed
        if (phase == AuctionPhase.Commit && block.timestamp >= commitDeadline) {
            phase = AuctionPhase.Reveal;
        }
        
        if (phase != AuctionPhase.Reveal) {
            revert InvalidPhase(AuctionPhase.Reveal, phase);
        }
        if (block.timestamp < revealDeadline) {
            revert DeadlineNotPassed();
        }
        
        phase = AuctionPhase.Settled;
        
        if (highestBidder != address(0)) {
            _handleSettlement(highestBidder, highestBid);
        }
        
        emit AuctionSettled(highestBidder, highestBid);
    }
    
    /**
     * @notice Withdraw deposit after auction settles
     * @dev Winners cannot withdraw (their deposit pays for the item)
     */
    function withdraw() external nonReentrant {
        if (phase != AuctionPhase.Settled) {
            revert InvalidPhase(AuctionPhase.Settled, phase);
        }
        if (msg.sender == highestBidder) {
            revert NotEligibleForWithdraw();
        }
        
        Commitment storage c = commitments[msg.sender];
        uint256 amount = c.deposit;
        
        if (amount == 0) {
            revert NothingToWithdraw();
        }
        
        c.deposit = 0;
        
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
        
        emit DepositWithdrawn(msg.sender, amount);
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get current auction phase with auto-detection
     */
    function getCurrentPhase() external view returns (AuctionPhase) {
        if (phase == AuctionPhase.Commit && block.timestamp >= commitDeadline) {
            return AuctionPhase.Reveal;
        }
        if (phase == AuctionPhase.Reveal && block.timestamp >= revealDeadline) {
            // Still in Reveal until settle() is called, but reveal window closed
            return AuctionPhase.Reveal;
        }
        return phase;
    }
    
    /**
     * @notice Check if an address has committed
     */
    function hasCommitted(address _bidder) external view returns (bool) {
        return commitments[_bidder].hash != bytes32(0);
    }
    
    /**
     * @notice Check if an address has revealed
     */
    function hasRevealed(address _bidder) external view returns (bool) {
        return commitments[_bidder].revealed;
    }
    
    /**
     * @notice Get time remaining in current phase
     */
    function timeRemaining() external view returns (uint256) {
        if (phase == AuctionPhase.Commit || (phase == AuctionPhase.Inactive && block.timestamp < commitDeadline)) {
            return block.timestamp < commitDeadline ? commitDeadline - block.timestamp : 0;
        }
        if (phase == AuctionPhase.Reveal) {
            return block.timestamp < revealDeadline ? revealDeadline - block.timestamp : 0;
        }
        return 0;
    }
    
    // ============ Internal Functions ============
    
    /**
     * @notice Handle auction settlement - override in derived contracts
     * @param winner Address of the winning bidder
     * @param amount Winning bid amount
     * @dev Transfer the auctioned item to winner, handle payment to seller
     */
    function _handleSettlement(address winner, uint256 amount) internal virtual;
}
