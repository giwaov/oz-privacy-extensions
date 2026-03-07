// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/CommitRevealAuction.sol";

/**
 * @title SimpleAuction
 * @dev Concrete implementation of CommitRevealAuction for testing
 */
contract SimpleAuction is CommitRevealAuction {
    address public beneficiary;
    
    constructor(
        uint256 _commitDuration,
        uint256 _revealDuration,
        uint256 _reservePrice,
        address _beneficiary
    ) CommitRevealAuction(_commitDuration, _revealDuration, _reservePrice) {
        beneficiary = _beneficiary;
    }
    
    function _handleSettlement(address winner, uint256 amount) internal override {
        // Simple implementation: transfer winning bid to beneficiary
        commitments[winner].deposit = 0;
        (bool success, ) = payable(beneficiary).call{value: amount}("");
        require(success, "Transfer failed");
    }
}

/**
 * @title CommitRevealAuctionTest
 * @dev Test suite for CommitRevealAuction
 */
contract CommitRevealAuctionTest is Test {
    SimpleAuction public auction;
    
    address public seller = makeAddr("seller");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    
    uint256 constant COMMIT_DURATION = 1 hours;
    uint256 constant REVEAL_DURATION = 1 hours;
    uint256 constant RESERVE_PRICE = 1 ether;
    
    bytes32 constant ALICE_SECRET = keccak256("alice_secret");
    bytes32 constant BOB_SECRET = keccak256("bob_secret");
    bytes32 constant CAROL_SECRET = keccak256("carol_secret");
    
    function setUp() public {
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        
        auction = new SimpleAuction(
            COMMIT_DURATION,
            REVEAL_DURATION,
            RESERVE_PRICE,
            seller
        );
    }
    
    // ============ Commit Phase Tests ============
    
    function test_CommitBid() public {
        uint256 bidAmount = 5 ether;
        bytes32 commitment = keccak256(abi.encodePacked(bidAmount, ALICE_SECRET));
        
        vm.prank(alice);
        auction.commitBid{value: 5 ether}(commitment);
        
        assertTrue(auction.hasCommitted(alice));
        assertEq(auction.totalCommitments(), 1);
    }
    
    function test_CommitBid_RevertsBelowReserve() public {
        bytes32 commitment = keccak256(abi.encodePacked(uint256(1 ether), ALICE_SECRET));
        
        vm.prank(alice);
        vm.expectRevert(CommitRevealAuction.DepositBelowReserve.selector);
        auction.commitBid{value: 0.5 ether}(commitment);
    }
    
    function test_CommitBid_RevertsDoubleCommit() public {
        bytes32 commitment = keccak256(abi.encodePacked(uint256(5 ether), ALICE_SECRET));
        
        vm.startPrank(alice);
        auction.commitBid{value: 5 ether}(commitment);
        
        vm.expectRevert(CommitRevealAuction.AlreadyCommitted.selector);
        auction.commitBid{value: 5 ether}(commitment);
        vm.stopPrank();
    }
    
    function test_CommitBid_RevertsAfterDeadline() public {
        bytes32 commitment = keccak256(abi.encodePacked(uint256(5 ether), ALICE_SECRET));
        
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        
        vm.prank(alice);
        vm.expectRevert(CommitRevealAuction.DeadlinePassed.selector);
        auction.commitBid{value: 5 ether}(commitment);
    }
    
    // ============ Reveal Phase Tests ============
    
    function test_RevealBid() public {
        uint256 bidAmount = 5 ether;
        bytes32 commitment = keccak256(abi.encodePacked(bidAmount, ALICE_SECRET));
        
        // Commit
        vm.prank(alice);
        auction.commitBid{value: 5 ether}(commitment);
        
        // Move to reveal phase
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        
        // Reveal
        vm.prank(alice);
        auction.revealBid(bidAmount, ALICE_SECRET);
        
        assertTrue(auction.hasRevealed(alice));
        assertEq(auction.highestBidder(), alice);
        assertEq(auction.highestBid(), bidAmount);
    }
    
    function test_RevealBid_InvalidSecret() public {
        uint256 bidAmount = 5 ether;
        bytes32 commitment = keccak256(abi.encodePacked(bidAmount, ALICE_SECRET));
        
        vm.prank(alice);
        auction.commitBid{value: 5 ether}(commitment);
        
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        
        vm.prank(alice);
        vm.expectRevert(CommitRevealAuction.InvalidReveal.selector);
        auction.revealBid(bidAmount, keccak256("wrong_secret"));
    }
    
    function test_RevealBid_InvalidAmount() public {
        uint256 bidAmount = 5 ether;
        bytes32 commitment = keccak256(abi.encodePacked(bidAmount, ALICE_SECRET));
        
        vm.prank(alice);
        auction.commitBid{value: 5 ether}(commitment);
        
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        
        vm.prank(alice);
        vm.expectRevert(CommitRevealAuction.InvalidReveal.selector);
        auction.revealBid(6 ether, ALICE_SECRET); // Wrong amount
    }
    
    function test_RevealBid_BidExceedsDeposit() public {
        uint256 bidAmount = 10 ether; // Bid higher than deposit
        bytes32 commitment = keccak256(abi.encodePacked(bidAmount, ALICE_SECRET));
        
        vm.prank(alice);
        auction.commitBid{value: 5 ether}(commitment); // Deposit only 5 ETH
        
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        
        vm.prank(alice);
        vm.expectRevert(CommitRevealAuction.BidExceedsDeposit.selector);
        auction.revealBid(bidAmount, ALICE_SECRET);
    }
    
    // ============ Multiple Bidders Tests ============
    
    function test_MultipleBidders_HighestWins() public {
        // Alice bids 5 ETH
        bytes32 aliceCommitment = keccak256(abi.encodePacked(uint256(5 ether), ALICE_SECRET));
        vm.prank(alice);
        auction.commitBid{value: 5 ether}(aliceCommitment);
        
        // Bob bids 8 ETH
        bytes32 bobCommitment = keccak256(abi.encodePacked(uint256(8 ether), BOB_SECRET));
        vm.prank(bob);
        auction.commitBid{value: 8 ether}(bobCommitment);
        
        // Carol bids 3 ETH
        bytes32 carolCommitment = keccak256(abi.encodePacked(uint256(3 ether), CAROL_SECRET));
        vm.prank(carol);
        auction.commitBid{value: 3 ether}(carolCommitment);
        
        // Move to reveal phase
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        
        // Reveal all bids
        vm.prank(alice);
        auction.revealBid(5 ether, ALICE_SECRET);
        
        vm.prank(bob);
        auction.revealBid(8 ether, BOB_SECRET);
        
        vm.prank(carol);
        auction.revealBid(3 ether, CAROL_SECRET);
        
        // Bob should be winning
        assertEq(auction.highestBidder(), bob);
        assertEq(auction.highestBid(), 8 ether);
    }
    
    // ============ Settlement Tests ============
    
    function test_Settle() public {
        uint256 bidAmount = 5 ether;
        bytes32 commitment = keccak256(abi.encodePacked(bidAmount, ALICE_SECRET));
        
        vm.prank(alice);
        auction.commitBid{value: 5 ether}(commitment);
        
        // Reveal
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(alice);
        auction.revealBid(bidAmount, ALICE_SECRET);
        
        // Settle
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        
        uint256 sellerBalanceBefore = seller.balance;
        auction.settle();
        
        assertEq(seller.balance, sellerBalanceBefore + bidAmount);
        assertEq(uint256(auction.phase()), uint256(CommitRevealAuction.AuctionPhase.Settled));
    }
    
    // ============ Withdrawal Tests ============
    
    function test_Withdraw_Loser() public {
        // Alice and Bob both bid
        bytes32 aliceCommitment = keccak256(abi.encodePacked(uint256(5 ether), ALICE_SECRET));
        vm.prank(alice);
        auction.commitBid{value: 5 ether}(aliceCommitment);
        
        bytes32 bobCommitment = keccak256(abi.encodePacked(uint256(8 ether), BOB_SECRET));
        vm.prank(bob);
        auction.commitBid{value: 8 ether}(bobCommitment);
        
        // Reveal
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(alice);
        auction.revealBid(5 ether, ALICE_SECRET);
        vm.prank(bob);
        auction.revealBid(8 ether, BOB_SECRET);
        
        // Settle
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        auction.settle();
        
        // Alice (loser) withdraws
        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        auction.withdraw();
        
        assertEq(alice.balance, aliceBalanceBefore + 5 ether);
    }
    
    function test_Withdraw_WinnerReverts() public {
        bytes32 commitment = keccak256(abi.encodePacked(uint256(5 ether), ALICE_SECRET));
        
        vm.prank(alice);
        auction.commitBid{value: 5 ether}(commitment);
        
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(alice);
        auction.revealBid(5 ether, ALICE_SECRET);
        
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        auction.settle();
        
        vm.prank(alice);
        vm.expectRevert(CommitRevealAuction.NotEligibleForWithdraw.selector);
        auction.withdraw();
    }
    
    // ============ Edge Cases ============
    
    function test_NoReveals_SettlesWithNoWinner() public {
        bytes32 commitment = keccak256(abi.encodePacked(uint256(5 ether), ALICE_SECRET));
        
        vm.prank(alice);
        auction.commitBid{value: 5 ether}(commitment);
        
        // Skip reveal phase entirely
        vm.warp(block.timestamp + COMMIT_DURATION + REVEAL_DURATION + 1);
        
        auction.settle();
        
        assertEq(auction.highestBidder(), address(0));
        assertEq(auction.highestBid(), 0);
    }
    
    function test_SingleBidder() public {
        bytes32 commitment = keccak256(abi.encodePacked(uint256(5 ether), ALICE_SECRET));
        
        vm.prank(alice);
        auction.commitBid{value: 5 ether}(commitment);
        
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(alice);
        auction.revealBid(5 ether, ALICE_SECRET);
        
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        auction.settle();
        
        assertEq(auction.highestBidder(), alice);
    }
}
