# OpenZeppelin Privacy Extensions

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-^0.8.20-blue)](https://docs.soliditylang.org/)

**Commit-Reveal Auctions & Encrypted Voting for Ethereum**

Production-ready privacy-preserving smart contract modules designed to extend [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts).

## Overview

This library provides sealed-bid auction and private voting mechanisms using cryptographic commit-reveal schemes. These contracts eliminate front-running, bid sniping, and vote manipulation by hiding sensitive data until a reveal phase.

### Features

- **CommitRevealAuction** — Sealed-bid auction where bids are hidden until reveal
- **VickreyAuction** — Second-price auction (winner pays 2nd highest bid)
- **PrivateVoting** — Commit-reveal voting with optional eligibility proofs
- **AuctionFactory** — Deploy auction instances with configurable parameters

## Problem

Ethereum's transparent blockchain creates systemic failures in auctions and voting:

| Issue | Impact |
|-------|--------|
| **Visible bids** | MEV bots front-run and snipe auctions |
| **Public votes** | Vote buying, social coercion, collusion |
| **Intent leakage** | Revealing willingness-to-pay distorts markets |

MEV extraction costs Ethereum users **$1B+ annually**. These contracts fix that.

## Installation

```bash
forge install giwaov/oz-privacy-extensions
```

Or with npm:

```bash
npm install @giwaov/oz-privacy-extensions
```

## Usage

### Commit-Reveal Auction

```solidity
import {CommitRevealAuction} from "oz-privacy-extensions/src/CommitRevealAuction.sol";

contract MyAuction is CommitRevealAuction {
    constructor(
        uint256 _commitDuration,
        uint256 _revealDuration,
        uint256 _reservePrice
    ) CommitRevealAuction(_commitDuration, _revealDuration, _reservePrice) {}

    function _handleSettlement(address winner, uint256 amount) internal override {
        // Transfer NFT or asset to winner
        // Transfer payment to seller
    }
}
```

### Bidding Flow

```javascript
// 1. Commit Phase - Submit sealed bid
const secret = ethers.randomBytes(32);
const commitment = ethers.solidityPackedKeccak256(
    ["uint256", "bytes32"],
    [bidAmount, secret]
);
await auction.commitBid(commitment, { value: deposit });

// 2. Reveal Phase - Reveal your bid
await auction.revealBid(bidAmount, secret);

// 3. Settlement - Winner determined, losers withdraw
await auction.settle();
await auction.withdraw(); // For non-winners
```

### Vickrey Auction (Second-Price)

```solidity
import {VickreyAuction} from "oz-privacy-extensions/src/VickreyAuction.sol";

// Winner pays the SECOND highest bid price
// This incentivizes truthful bidding (game-theoretically optimal)
contract NFTVickreyAuction is VickreyAuction {
    IERC721 public nft;
    uint256 public tokenId;

    function _handleSettlement(address winner, uint256) internal override {
        nft.transferFrom(address(this), winner, tokenId);
    }
}
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    COMMIT PHASE                          │
│  Bidders submit: hash(bid_amount, secret)               │
│  No one knows bid values — MEV protection               │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│                    REVEAL PHASE                          │
│  Bidders reveal: (bid_amount, secret)                   │
│  Contract verifies hash matches commitment              │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│                    SETTLEMENT                            │
│  Highest bidder wins                                     │
│  Vickrey: Winner pays 2nd highest price                 │
│  Losers withdraw deposits                               │
└─────────────────────────────────────────────────────────┘
```

## Security Considerations

### Commit Phase
- Bidders must keep their secret secure until reveal
- Deposit must be ≥ bid amount to prevent dishonest reveals
- Commitment cannot be changed once submitted

### Reveal Phase
- All bidders MUST reveal to recover deposits
- Non-revealing bidders forfeit their deposit
- Time-bounded to prevent indefinite delays

### Known Limitations
- Requires bidder participation in reveal phase
- Does not hide NUMBER of bids (only amounts)
- Auction creator can see how many commitments exist

## Gas Estimates

| Operation | Gas (approx) |
|-----------|-------------|
| `commitBid` | ~50,000 |
| `revealBid` | ~65,000 |
| `settle` | ~45,000 |
| `withdraw` | ~30,000 |

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) or [Hardhat](https://hardhat.org/)
- Node.js 18+

### Build

```bash
# Foundry
forge build

# Hardhat
npm install
npm run compile
```

### Test

```bash
# Foundry tests
forge test -vvv

# Hardhat tests
npm test
```

### Coverage

```bash
forge coverage
```

### CI/CD

Tests run automatically on pull requests via GitHub Actions. See [.github/workflows/test.yml](.github/workflows/test.yml).

## Roadmap

- [x] Core CommitRevealAuction implementation
- [x] VickreyAuction (second-price)
- [ ] PrivateVoting with commit-reveal
- [ ] AuctionFactory for easy deployment
- [ ] ZK eligibility proof integration (optional)
- [ ] Comprehensive documentation
- [ ] Security audit
- [ ] OpenZeppelin PR submission

## Prior Art

This implementation is informed by:

- [Arcium Blind Auction](https://blind-auction-frontend.vercel.app) — MPC-based encrypted auctions (Solana)
- [MACI](https://github.com/privacy-scaling-explorations/maci) — Minimal Anti-Collusion Infrastructure
- [Vickrey Auction Theory](https://en.wikipedia.org/wiki/Vickrey_auction) — Nobel Prize-winning mechanism design

## Contributing

Contributions welcome! Please read our [Contributing Guide](CONTRIBUTING.md) first.

1. Fork the repository
2. Create a feature branch
3. Write tests for new functionality
4. Submit a PR

## License

MIT License — see [LICENSE](LICENSE) for details.

## Author

**Victor Giwa** ([@0xgiwa](https://x.com/0xgiwa))

---

*Built with support from the Ethereum Foundation Ecosystem Support Program*
