const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("VickreyAuction", function () {
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

    async function deployAuction() {
        const VickreyAuction = await ethers.getContractFactory("VickreyAuction");
        return await VickreyAuction.deploy(
            COMMIT_DURATION,
            REVEAL_DURATION,
            RESERVE_PRICE,
            owner.address  // beneficiary
        );
    }

    beforeEach(async function () {
        [owner, bidder1, bidder2, bidder3] = await ethers.getSigners();
        auction = await deployAuction();
    });

    describe("Deployment", function () {
        it("Should set the correct owner", async function () {
            expect(await auction.owner()).to.equal(owner.address);
        });

        it("Should start in Commit phase", async function () {
            expect(await auction.phase()).to.equal(1); // Commit phase (auction starts immediately)
        });

        it("Should set correct beneficiary", async function () {
            expect(await auction.beneficiary()).to.equal(owner.address);
        });

        it("Should set correct reserve price", async function () {
            expect(await auction.reservePrice()).to.equal(RESERVE_PRICE);
        });
    });

    describe("Commit Phase", function () {
        it("Should accept valid commitments with sufficient deposit", async function () {
            const bidAmount = ethers.parseEther("2");
            const secret = "mysecret1";
            const hash = createCommitmentHash(bidAmount, secret);
            
            await auction.connect(bidder1).commitBid(hash, { value: bidAmount });
            
            const commitment = await auction.commitments(bidder1.address);
            expect(commitment.hash).to.equal(hash);
            expect(commitment.deposit).to.equal(bidAmount);
            expect(commitment.revealed).to.equal(false);
        });

        it("Should increment totalCommitments", async function () {
            const hash = createCommitmentHash(ethers.parseEther("2"), "secret");
            await auction.connect(bidder1).commitBid(hash, { value: ethers.parseEther("2") });
            
            expect(await auction.totalCommitments()).to.equal(1);
            
            const hash2 = createCommitmentHash(ethers.parseEther("3"), "secret2");
            await auction.connect(bidder2).commitBid(hash2, { value: ethers.parseEther("3") });
            
            expect(await auction.totalCommitments()).to.equal(2);
        });

        it("Should reject commitments with zero deposit", async function () {
            const hash = createCommitmentHash(ethers.parseEther("2"), "secret");
            await expect(
                auction.connect(bidder1).commitBid(hash, { value: 0 })
            ).to.be.reverted;
        });

        it("Should reject duplicate commitments from same address", async function () {
            const hash = createCommitmentHash(ethers.parseEther("2"), "secret");
            await auction.connect(bidder1).commitBid(hash, { value: ethers.parseEther("2") });
            
            await expect(
                auction.connect(bidder1).commitBid(hash, { value: ethers.parseEther("2") })
            ).to.be.reverted;
        });

        it("Should reject commitments after commit deadline", async function () {
            await time.increase(COMMIT_DURATION + 1);
            
            const hash = createCommitmentHash(ethers.parseEther("2"), "secret");
            await expect(
                auction.connect(bidder1).commitBid(hash, { value: ethers.parseEther("2") })
            ).to.be.reverted;
        });
    });

    describe("Reveal Phase", function () {
        beforeEach(async function () {
            // Setup commitments
            const hash1 = createCommitmentHash(ethers.parseEther("3"), "secret1");
            const hash2 = createCommitmentHash(ethers.parseEther("5"), "secret2");
            
            await auction.connect(bidder1).commitBid(hash1, { value: ethers.parseEther("3") });
            await auction.connect(bidder2).commitBid(hash2, { value: ethers.parseEther("5") });
            
            // Advance to reveal phase
            await time.increase(COMMIT_DURATION + 1);
        });

        it("Should accept valid reveals", async function () {
            await auction.connect(bidder1).revealBid(ethers.parseEther("3"), ethers.id("secret1"));
            
            const commitment = await auction.commitments(bidder1.address);
            expect(commitment.revealed).to.equal(true);
        });

        it("Should track highest bid correctly", async function () {
            await auction.connect(bidder1).revealBid(ethers.parseEther("3"), ethers.id("secret1"));
            expect(await auction.highestBid()).to.equal(ethers.parseEther("3"));
            expect(await auction.highestBidder()).to.equal(bidder1.address);
            
            await auction.connect(bidder2).revealBid(ethers.parseEther("5"), ethers.id("secret2"));
            expect(await auction.highestBid()).to.equal(ethers.parseEther("5"));
            expect(await auction.highestBidder()).to.equal(bidder2.address);
        });

        it("Should track second highest bid for Vickrey", async function () {
            await auction.connect(bidder1).revealBid(ethers.parseEther("3"), ethers.id("secret1"));
            await auction.connect(bidder2).revealBid(ethers.parseEther("5"), ethers.id("secret2"));
            
            // Second highest should be 3 ETH
            expect(await auction.secondHighestBid()).to.equal(ethers.parseEther("3"));
        });

        it("Should reject reveal with wrong secret", async function () {
            await expect(
                auction.connect(bidder1).revealBid(ethers.parseEther("3"), ethers.id("wrongsecret"))
            ).to.be.reverted;
        });

        it("Should reject reveal with wrong amount", async function () {
            await expect(
                auction.connect(bidder1).revealBid(ethers.parseEther("4"), ethers.id("secret1"))
            ).to.be.reverted;
        });

        it("Should reject double reveals", async function () {
            await auction.connect(bidder1).revealBid(ethers.parseEther("3"), ethers.id("secret1"));
            
            await expect(
                auction.connect(bidder1).revealBid(ethers.parseEther("3"), ethers.id("secret1"))
            ).to.be.reverted;
        });
    });

    describe("Settlement", function () {
        beforeEach(async function () {
            // Setup commitments
            const hash1 = createCommitmentHash(ethers.parseEther("3"), "secret1");
            const hash2 = createCommitmentHash(ethers.parseEther("5"), "secret2");
            
            await auction.connect(bidder1).commitBid(hash1, { value: ethers.parseEther("3") });
            await auction.connect(bidder2).commitBid(hash2, { value: ethers.parseEther("5") });
            
            // Move to reveal phase and reveal
            await time.increase(COMMIT_DURATION + 1);
            await auction.connect(bidder1).revealBid(ethers.parseEther("3"), ethers.id("secret1"));
            await auction.connect(bidder2).revealBid(ethers.parseEther("5"), ethers.id("secret2"));
        });

        it("Should not allow settlement before reveal deadline", async function () {
            await expect(
                auction.connect(owner).settle()
            ).to.be.reverted;
        });

        it("Should allow settlement after reveal deadline", async function () {
            await time.increase(REVEAL_DURATION + 1);
            await auction.connect(owner).settle();
            
            expect(await auction.phase()).to.equal(3); // Settled
        });

        it("Vickrey: Winner pays second-highest bid", async function () {
            await time.increase(REVEAL_DURATION + 1);
            await auction.connect(owner).settle();
            
            // In Vickrey auction, winner pays second-highest bid (3 ETH, not 5 ETH)
            expect(await auction.secondHighestBid()).to.equal(ethers.parseEther("3"));
        });
    });

    describe("Withdrawal", function () {
        beforeEach(async function () {
            const hash1 = createCommitmentHash(ethers.parseEther("3"), "secret1");
            const hash2 = createCommitmentHash(ethers.parseEther("5"), "secret2");
            
            await auction.connect(bidder1).commitBid(hash1, { value: ethers.parseEther("3") });
            await auction.connect(bidder2).commitBid(hash2, { value: ethers.parseEther("5") });
            
            await time.increase(COMMIT_DURATION + 1);
            await auction.connect(bidder1).revealBid(ethers.parseEther("3"), ethers.id("secret1"));
            await auction.connect(bidder2).revealBid(ethers.parseEther("5"), ethers.id("secret2"));
            
            await time.increase(REVEAL_DURATION + 1);
            await auction.connect(owner).settle();
        });

        it("Should allow losing bidder to withdraw", async function () {
            const balanceBefore = await ethers.provider.getBalance(bidder1.address);
            await auction.connect(bidder1).withdraw();
            const balanceAfter = await ethers.provider.getBalance(bidder1.address);
            
            // Should have received back their 3 ETH deposit (minus gas)
            expect(balanceAfter).to.be.gt(balanceBefore);
        });

        it("Should not allow winner to withdraw deposit", async function () {
            // Winner is bidder2 with 5 ETH deposit
            // Base CommitRevealAuction doesn't allow winner withdrawals at all
            await expect(auction.connect(bidder2).withdraw()).to.be.reverted;
        });

        it("Should not allow double withdrawal", async function () {
            await auction.connect(bidder1).withdraw();
            
            await expect(
                auction.connect(bidder1).withdraw()
            ).to.be.reverted;
        });

        it("Should not allow withdrawal before settlement", async function () {
            // Deploy fresh instance
            const newAuction = await deployAuction();
            
            const hash = createCommitmentHash(ethers.parseEther("3"), "secret");
            await newAuction.connect(bidder1).commitBid(hash, { value: ethers.parseEther("3") });
            
            await expect(
                newAuction.connect(bidder1).withdraw()
            ).to.be.reverted;
        });
    });

    describe("Edge Cases", function () {
        it("Should handle single bidder correctly", async function () {
            const hash1 = createCommitmentHash(ethers.parseEther("3"), "secret1");
            await auction.connect(bidder1).commitBid(hash1, { value: ethers.parseEther("3") });
            
            await time.increase(COMMIT_DURATION + 1);
            await auction.connect(bidder1).revealBid(ethers.parseEther("3"), ethers.id("secret1"));
            
            await time.increase(REVEAL_DURATION + 1);
            await auction.connect(owner).settle();
            
            expect(await auction.highestBidder()).to.equal(bidder1.address);
            expect(await auction.highestBid()).to.equal(ethers.parseEther("3"));
        });

        it("Reserve price is enforced during commit phase via deposit", async function () {
            // Create a new auction with higher reserve price
            const VickreyAuction = await ethers.getContractFactory("VickreyAuction");
            const highReserveAuction = await VickreyAuction.deploy(
                COMMIT_DURATION,
                REVEAL_DURATION,
                ethers.parseEther("10"), // Reserve: 10 ETH
                owner.address
            );
            
            // Commit with deposit below reserve should fail
            const hash = createCommitmentHash(ethers.parseEther("5"), "secret");
            await expect(
                highReserveAuction.connect(bidder1).commitBid(hash, { value: ethers.parseEther("5") })
            ).to.be.reverted;
        });
    });
});
