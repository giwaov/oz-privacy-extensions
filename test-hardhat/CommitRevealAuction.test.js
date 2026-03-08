const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("CommitRevealAuction", function () {
    let auction;
    let owner;
    let bidder1;
    let bidder2;
    let bidder3;

    const RESERVE_PRICE = ethers.parseEther("1");
    const COMMIT_DURATION = 3600; // 1 hour
    const REVEAL_DURATION = 1800; // 30 minutes

    // Helper function to create commitment hash
    function createCommitmentHash(bidAmount, secret) {
        return ethers.keccak256(
            ethers.AbiCoder.defaultAbiCoder().encode(
                ["uint256", "bytes32"],
                [bidAmount, ethers.id(secret)]
            )
        );
    }

    beforeEach(async function () {
        [owner, bidder1, bidder2, bidder3] = await ethers.getSigners();

        // Deploy the Vickrey Auction (concrete implementation)
        const VickreyAuction = await ethers.getContractFactory("VickreyAuction");
        auction = await VickreyAuction.deploy(owner.address);
    });

    describe("Deployment", function () {
        it("Should set the correct owner", async function () {
            expect(await auction.owner()).to.equal(owner.address);
        });

        it("Should start in Inactive phase", async function () {
            expect(await auction.phase()).to.equal(0); // Inactive
        });
    });

    describe("Starting Auction", function () {
        it("Should allow owner to start auction", async function () {
            await auction.connect(owner).startAuction(RESERVE_PRICE, COMMIT_DURATION, REVEAL_DURATION);
            expect(await auction.phase()).to.equal(1); // Commit phase
        });

        it("Should reject non-owner starting auction", async function () {
            await expect(
                auction.connect(bidder1).startAuction(RESERVE_PRICE, COMMIT_DURATION, REVEAL_DURATION)
            ).to.be.revertedWithCustomError(auction, "OwnableUnauthorizedAccount");
        });

        it("Should set correct commit and reveal deadlines", async function () {
            const tx = await auction.connect(owner).startAuction(RESERVE_PRICE, COMMIT_DURATION, REVEAL_DURATION);
            const block = await ethers.provider.getBlock(tx.blockNumber);
            
            expect(await auction.commitDeadline()).to.equal(BigInt(block.timestamp) + BigInt(COMMIT_DURATION));
            expect(await auction.revealDeadline()).to.equal(BigInt(block.timestamp) + BigInt(COMMIT_DURATION) + BigInt(REVEAL_DURATION));
        });
    });

    describe("Commit Phase", function () {
        beforeEach(async function () {
            await auction.connect(owner).startAuction(RESERVE_PRICE, COMMIT_DURATION, REVEAL_DURATION);
        });

        it("Should accept valid commitments with sufficient deposit", async function () {
            const bidAmount = ethers.parseEther("2");
            const secret = "mysecret1";
            const hash = createCommitmentHash(bidAmount, secret);
            
            await auction.connect(bidder1).commit(hash, { value: bidAmount });
            
            const commitment = await auction.commitments(bidder1.address);
            expect(commitment.hash).to.equal(hash);
            expect(commitment.deposit).to.equal(bidAmount);
            expect(commitment.revealed).to.equal(false);
        });

        it("Should increment totalCommitments", async function () {
            const hash = createCommitmentHash(ethers.parseEther("2"), "secret");
            await auction.connect(bidder1).commit(hash, { value: ethers.parseEther("2") });
            
            expect(await auction.totalCommitments()).to.equal(1);
            
            const hash2 = createCommitmentHash(ethers.parseEther("3"), "secret2");
            await auction.connect(bidder2).commit(hash2, { value: ethers.parseEther("3") });
            
            expect(await auction.totalCommitments()).to.equal(2);
        });

        it("Should reject commitments with zero deposit", async function () {
            const hash = createCommitmentHash(ethers.parseEther("2"), "secret");
            await expect(
                auction.connect(bidder1).commit(hash, { value: 0 })
            ).to.be.revertedWithCustomError(auction, "DepositRequired");
        });

        it("Should reject duplicate commitments from same address", async function () {
            const hash = createCommitmentHash(ethers.parseEther("2"), "secret");
            await auction.connect(bidder1).commit(hash, { value: ethers.parseEther("2") });
            
            await expect(
                auction.connect(bidder1).commit(hash, { value: ethers.parseEther("2") })
            ).to.be.revertedWithCustomError(auction, "AlreadyCommitted");
        });

        it("Should reject commitments after commit deadline", async function () {
            await time.increase(COMMIT_DURATION + 1);
            
            const hash = createCommitmentHash(ethers.parseEther("2"), "secret");
            await expect(
                auction.connect(bidder1).commit(hash, { value: ethers.parseEther("2") })
            ).to.be.revertedWithCustomError(auction, "NotInCommitPhase");
        });
    });

    describe("Reveal Phase", function () {
        beforeEach(async function () {
            await auction.connect(owner).startAuction(RESERVE_PRICE, COMMIT_DURATION, REVEAL_DURATION);
            
            // Setup commitments
            const hash1 = createCommitmentHash(ethers.parseEther("3"), "secret1");
            const hash2 = createCommitmentHash(ethers.parseEther("5"), "secret2");
            
            await auction.connect(bidder1).commit(hash1, { value: ethers.parseEther("3") });
            await auction.connect(bidder2).commit(hash2, { value: ethers.parseEther("5") });
            
            // Advance to reveal phase
            await time.increase(COMMIT_DURATION + 1);
        });

        it("Should accept valid reveals", async function () {
            await auction.connect(bidder1).reveal(ethers.parseEther("3"), ethers.id("secret1"));
            
            const commitment = await auction.commitments(bidder1.address);
            expect(commitment.revealed).to.equal(true);
        });

        it("Should track highest bid correctly", async function () {
            await auction.connect(bidder1).reveal(ethers.parseEther("3"), ethers.id("secret1"));
            expect(await auction.highestBid()).to.equal(ethers.parseEther("3"));
            expect(await auction.highestBidder()).to.equal(bidder1.address);
            
            await auction.connect(bidder2).reveal(ethers.parseEther("5"), ethers.id("secret2"));
            expect(await auction.highestBid()).to.equal(ethers.parseEther("5"));
            expect(await auction.highestBidder()).to.equal(bidder2.address);
        });

        it("Should reject reveal with wrong secret", async function () {
            await expect(
                auction.connect(bidder1).reveal(ethers.parseEther("3"), ethers.id("wrongsecret"))
            ).to.be.revertedWithCustomError(auction, "InvalidReveal");
        });

        it("Should reject reveal with wrong amount", async function () {
            await expect(
                auction.connect(bidder1).reveal(ethers.parseEther("4"), ethers.id("secret1"))
            ).to.be.revertedWithCustomError(auction, "InvalidReveal");
        });

        it("Should reject reveal below reserve price", async function () {
            const hashLow = createCommitmentHash(ethers.parseEther("0.5"), "lowsecret");
            
            // Reset and create low bid scenario
            const VickreyAuction = await ethers.getContractFactory("VickreyAuction");
            const newAuction = await VickreyAuction.deploy(owner.address);
            await newAuction.connect(owner).startAuction(RESERVE_PRICE, COMMIT_DURATION, REVEAL_DURATION);
            await newAuction.connect(bidder3).commit(hashLow, { value: ethers.parseEther("0.5") });
            await time.increase(COMMIT_DURATION + 1);
            
            await expect(
                newAuction.connect(bidder3).reveal(ethers.parseEther("0.5"), ethers.id("lowsecret"))
            ).to.be.revertedWithCustomError(newAuction, "BidBelowReserve");
        });

        it("Should reject double reveals", async function () {
            await auction.connect(bidder1).reveal(ethers.parseEther("3"), ethers.id("secret1"));
            
            await expect(
                auction.connect(bidder1).reveal(ethers.parseEther("3"), ethers.id("secret1"))
            ).to.be.revertedWithCustomError(auction, "AlreadyRevealed");
        });
    });

    describe("Settlement", function () {
        beforeEach(async function () {
            await auction.connect(owner).startAuction(RESERVE_PRICE, COMMIT_DURATION, REVEAL_DURATION);
            
            // Setup commitments
            const hash1 = createCommitmentHash(ethers.parseEther("3"), "secret1");
            const hash2 = createCommitmentHash(ethers.parseEther("5"), "secret2");
            
            await auction.connect(bidder1).commit(hash1, { value: ethers.parseEther("3") });
            await auction.connect(bidder2).commit(hash2, { value: ethers.parseEther("5") });
            
            // Move to reveal phase and reveal
            await time.increase(COMMIT_DURATION + 1);
            await auction.connect(bidder1).reveal(ethers.parseEther("3"), ethers.id("secret1"));
            await auction.connect(bidder2).reveal(ethers.parseEther("5"), ethers.id("secret2"));
        });

        it("Should not allow settlement before reveal deadline", async function () {
            await expect(
                auction.connect(owner).settleAuction()
            ).to.be.revertedWithCustomError(auction, "RevealPhaseNotEnded");
        });

        it("Should allow settlement after reveal deadline", async function () {
            await time.increase(REVEAL_DURATION + 1);
            await auction.connect(owner).settleAuction();
            
            expect(await auction.phase()).to.equal(3); // Settled
        });

        it("Vickrey: Winner pays second-highest bid", async function () {
            await time.increase(REVEAL_DURATION + 1);
            
            // Track owner's balance before settlement
            const ownerBalanceBefore = await ethers.provider.getBalance(owner.address);
            
            await auction.connect(owner).settleAuction();
            
            // In Vickrey auction, winner pays second-highest bid (3 ETH, not 5 ETH)
            expect(await auction.secondHighestBid()).to.equal(ethers.parseEther("3"));
        });
    });

    describe("Withdrawal", function () {
        beforeEach(async function () {
            await auction.connect(owner).startAuction(RESERVE_PRICE, COMMIT_DURATION, REVEAL_DURATION);
            
            const hash1 = createCommitmentHash(ethers.parseEther("3"), "secret1");
            const hash2 = createCommitmentHash(ethers.parseEther("5"), "secret2");
            
            await auction.connect(bidder1).commit(hash1, { value: ethers.parseEther("3") });
            await auction.connect(bidder2).commit(hash2, { value: ethers.parseEther("5") });
            
            await time.increase(COMMIT_DURATION + 1);
            await auction.connect(bidder1).reveal(ethers.parseEther("3"), ethers.id("secret1"));
            await auction.connect(bidder2).reveal(ethers.parseEther("5"), ethers.id("secret2"));
            
            await time.increase(REVEAL_DURATION + 1);
            await auction.connect(owner).settleAuction();
        });

        it("Should allow losing bidder to withdraw", async function () {
            const balanceBefore = await ethers.provider.getBalance(bidder1.address);
            await auction.connect(bidder1).withdraw();
            const balanceAfter = await ethers.provider.getBalance(bidder1.address);
            
            // Should have received back their 3 ETH deposit (minus gas)
            expect(balanceAfter).to.be.gt(balanceBefore);
        });

        it("Should not allow winner to withdraw full deposit", async function () {
            // Winner is bidder2 with 5 ETH deposit, but pays second price (3 ETH)
            // So they should get back 2 ETH
            await expect(auction.connect(bidder2).withdraw()).to.not.be.reverted;
        });

        it("Should not allow double withdrawal", async function () {
            await auction.connect(bidder1).withdraw();
            
            await expect(
                auction.connect(bidder1).withdraw()
            ).to.be.revertedWithCustomError(auction, "AlreadyWithdrawn");
        });

        it("Should not allow withdrawal before settlement", async function () {
            // Deploy fresh instance
            const VickreyAuction = await ethers.getContractFactory("VickreyAuction");
            const newAuction = await VickreyAuction.deploy(owner.address);
            await newAuction.connect(owner).startAuction(RESERVE_PRICE, COMMIT_DURATION, REVEAL_DURATION);
            
            const hash = createCommitmentHash(ethers.parseEther("3"), "secret");
            await newAuction.connect(bidder1).commit(hash, { value: ethers.parseEther("3") });
            
            await expect(
                newAuction.connect(bidder1).withdraw()
            ).to.be.revertedWithCustomError(newAuction, "NotSettled");
        });
    });
});
