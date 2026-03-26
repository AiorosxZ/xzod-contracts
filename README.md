# xZod Network — Smart Contracts

> A cyclical DeFi protocol anchored to the zodiac calendar.  
> Chapter 1: Polygon PoS · Chapter 2: xZile Supernet (2028)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-blue)](https://soliditylang.org/)
[![Network](https://img.shields.io/badge/Testnet-Sepolia-green)](https://sepolia.etherscan.io/)

---

## TL;DR

xZod is a cyclical DeFi protocol where:
- **Yield rotates monthly** based on the zodiac calendar — predictable years in advance
- **Users compete in burn-based PvP cycles** anchored to Full Moons
- **NFTs provide permanent, DAO-governed advantages** to active participants
- **xZile** — our Polygon CDK Supernet — is the endgame: a fast blockchain where xZOD becomes native gas, and stakers earn **predictable gas discounts tied to the zodiac calendar**

---

## Overview

xZod Network fuses the twelve-sign zodiac calendar with on-chain tokenomics to create a **predictable, cyclical DeFi protocol**. Two tokens power the ecosystem:

- **xZOD** — reserve asset, hard cap 100M, designed for Polygon DEX listing
- **12 ZOD tokens** (ZARI→ZPIS) — protocol-only utility tokens, one per zodiac sign
- **Core invariant:** 1 xZOD always equals a basket of all 12 ZOD signs combined —
fully backed and redeemable on demand. A holder can convert 1 xZOD into any 
combination of the 12 signs (12 ZLEO, or 6 ZARI + 6 ZGEM, or any mix) — the 
Unified Reserve Vault prices each sign dynamically based on demand, but the full 
basket always resolves to exactly 1 xZOD. This invariant can never be broken.
APY rotates monthly with the zodiac calendar. Clans compete in monthly **Burn Wars** anchored to Full Moons. NFTs provide permanent gameplay bonuses governed by DAO vote each season.

🌐 **Website:** [xzod.io](https://xzod.io)  
📄 **Whitepaper:** [xzod.io/whitepaper](https://xzod.io/whitepaper)  
🎥 **Demo:** [YouTube](https://www.youtube.com/watch?v=hdQ2uiK0gUU)

---

## Current Status

- ✅ All core contracts deployed and verified on **Ethereum Sepolia** (test phase)
- ✅ Staking, Burn Wars cycles, and NFT mechanics fully implemented
- ✅ Frontend live at [xzod.io](https://xzod.io) — fully functional testnet UI
- ✅ 6 Burn Wars cycles created and active on testnet
- ✅ Active testing phase — admin workflows, reward distribution, cycle finalization validated
- 🎯 **Target deployment: Polygon PoS mainnet** — pending audit

> **Note on network:** Current contracts run on Ethereum Sepolia for development and testing. All production deployment targets **Polygon PoS**, chosen for its low fees, fast finality, and CDK Supernet infrastructure required for xZile (Chapter 2).

---

## Grant Objective

xZod is seeking a Polygon grant to:

- Complete smart contract security audit
- Deploy on Polygon PoS mainnet
- Bootstrap initial liquidity (xZOD/USDC pool)
- Incentivize early users during Season 1 launch (24 Dec 2026)

This grant will accelerate xZod's transition from testnet MVP to a live Polygon-native DeFi protocol — and lay the foundation for xZile, a flagship Polygon CDK Supernet.

---

## Why Polygon

xZod is designed for high-frequency, low-cost cyclical DeFi mechanics that demand Polygon's infrastructure:

- **Monthly reward cycles (Burn Wars)** — dozens of on-chain interactions per cycle per user
- **Frequent staking operations** — 12 ZOD tokens with rotating APY every ~30 days
- **NFT-based dynamic boosts** — on-chain bonus computation at every burn transaction
- **Real-time clan competition** — leaderboard updates require fast, cheap finality

Polygon provides exactly this:
- **Low transaction fees** → viable micro-interactions (burning small amounts, claiming rewards)
- **Fast finality** → real-time clan leaderboards and cycle management
- **Polygon CDK** → the foundation for **xZile**, our sovereign Supernet where xZOD becomes native gas

### xZile — The Endgame: Predictable Gas Discounts

The ultimate goal of xZod is a **sovereign blockchain with calendar-predictable economics**.

On xZile (Polygon CDK Supernet, targeting 2028):
- **xZOD becomes the native gas token** — every transaction burns xZOD supply organically
- **Gas discounts are tied to the zodiac calendar** — stake the current HOT ZOD sign for 90+ days and unlock structural gas fee reductions of up to 50%
- **Discount windows are known years in advance** — because the zodiac calendar is astronomically fixed, businesses and developers can plan infrastructure costs with a precision no other blockchain offers
- **Priority block inclusion** for HOT token stakers — faster execution, predictable cost, no auction-based fee market surprises

| Tier | HOT ZOD Staked ≥90d | Gas Discount | Lane |
|---|---|---|---|
| Standard | None | 0% | Normal mempool |
| Contributor | 1,000+ | 15% | Priority |
| Advocate | 10,000+ | 30% | Fast lane |
| Constellation | 100,000+ | 50% | Express lane |

**xZile is the first blockchain where gas costs are a calendar event, not a market event.**

xZod aims to become a native Polygon DeFi primitive — and xZile, a flagship Polygon CDK Supernet.

---

## Contract Architecture

```
contracts/
├── xZOD.sol                  # ERC-20, 100M hard cap, no mint pre-xZile
├── ZodTokens/
│   ├── ZARI.sol              # Aries
│   ├── ZTAU.sol              # Taurus
│   ├── ZGEM.sol              # Gemini
│   ├── ZCAN.sol              # Cancer
│   ├── ZLEO.sol              # Leo
│   ├── ZVIR.sol              # Virgo
│   ├── ZLIB.sol              # Libra
│   ├── ZSCO.sol              # Scorpio
│   ├── ZSAG.sol              # Sagittarius
│   ├── ZCAP.sol              # Capricorn
│   ├── ZAQU.sol              # Aquarius
│   └── ZPIS.sol              # Pisces
├── ReservePool.sol           # Unified AMM vault — 1 xZOD ↔ 12 ZOD invariant
├── SeasonWars.sol            # V2.3 — Cycle mgmt, clan scoring, OPPOSITE rewards
├── ZODStakingVaultV2.sol     # Dynamic APY, 45-day lock, multi-token
├── xZodNFT.sol               # ERC-1155 — Elemental (permanent) + Zodiac + Collector
├── NFTRules.sol              # On-chain bonus computation (bps) — DAO-updatable
├── GPVPTracker.sol           # Cumulative governance + validator points
├── NFTMarketplace.sol        # xZOD-denominated P2P marketplace
├── ICOPresale.sol            # 3-round presale + USDC cliff/vesting
├── Oracle.sol                # ZOD price feed
└── Faucet.sol                # Testnet xZOD distribution
```

---

## Deployed Contracts — Sepolia Testnet

| Contract | Address |
|---|---|
| [xZOD](https://sepolia.etherscan.io/address/0x017f4333Aa7e83fA42d119d5489c41e3648c9D2f) | `0x017f4333Aa7e83fA42d119d5489c41e3648c9D2f` |
| [ZODStakingVaultV2](https://sepolia.etherscan.io/address/0x4A15Aa5A360e718c0222E8Fa03E2785D10A8c820) | `0x4A15Aa5A360e718c0222E8Fa03E2785D10A8c820` |
| [SeasonWars V2.3](https://sepolia.etherscan.io/address/0x5598778158a66d376bd96243FC6bc27316fD2fc8) | `0x5598778158a66d376bd96243FC6bc27316fD2fc8` |
| [ReservePool V3](https://sepolia.etherscan.io/address/0x125F8D775886FBF7513510300092Fb6de775D1A2) | `0x125F8D775886FBF7513510300092Fb6de775D1A2` |
| ZodiacOracle V2 | `0x32621712B22d7f96618D7d1d646aEEe7c21d9086` |
| xZodNFT | `0x5249D8eacbD47080642a7d89884CC3A1c0A110e3` |
| NFTRules | `0xd7e46DfF9E0095C8df9BCc5d2D6230bD4b72e7FF` |
| NFTController (Stub) | `0x4917cE198Ae08De5F1C5737C97998B3692b558B6` |
| GPVPTracker | `0xC94c4B4D60EDf75ceA030B46470daeD725C16A66` |
| NFTMarketplace | `0xfDFd25E31d65700872EB82B33f842DB11ba4b320` |
| ICOPresale | `0xeB0D984e2bC2f8934986d6A78C6962320b4F08C0` |
| Faucet | `0x6Db81d88A86a88f6E3C5f067dD497C4c35d274c4` |
| USDC (testnet) | `0x5FF41728ceC9D457a98ba9903aD19D6C8fc12e83` |
| Uniswap V2 Router | `0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3` |
| xZOD/USDC Pool | `0x991fb119845c9eA0a1e2Adc255b40f642C7E1C63` |

### ZOD Tokens — Sepolia

| Sign | Symbol | Address |
|---|---|---|
| Aries | ZARI | `0x151A8D40B3Bb2B2CB0B8B96e07A1C1c3E3b6b77` |
| Taurus | ZTAU | `0xADf6707990EdE8CBA5e8dEEfbc27F2e869B68B10` |
| Gemini | ZGEM | `0x4cCf74F76883DDd61D960F814270fE18d4dfEad6` |
| Cancer | ZCAN | `0x1f22D5E521Ef9FB11CF350B4177099805f3317Bf` |
| Leo | ZLEO | `0x82A6672451a2c72E1dbA34d7e0A40823840df929` |
| Virgo | ZVIR | `0xFca6878a4C8EbFF753468c5bab673012Ddb6EBA8` |
| Libra | ZLIB | `0xa035D327A9c803CAC4f57dB94F639D3B5104b037` |
| Scorpio | ZSCO | `0x695cfc99A6692693aAA9FAc614191bDC93a6a146` |
| Sagittarius | ZSAG | `0x87df726b6507F65e62ace7a1e253CE392dAcf6c8` |
| Capricorn | ZCAP | `0xB77045eB8D9939Af3A1540dC949e76964C2bCc79` |
| Aquarius | ZAQU | `0x9317D9BCDB781f7492fF9615466FD6a6B62C5EF0` |
| Pisces | ZPIS | `0x6D4817F0Db5922b77Bc64148C6a0Aa25C2276a0d` |

---

## Core Mechanics

### Zodiac Calendar — Staking APY

APY rotates automatically with the on-chain zodiac calendar (no oracle — pure arithmetic).

| Season | 🔥 HOT | Normal | ❄️ COLD | 🔮 OPPOSITE |
|---|---|---|---|---|
| S1 Dec 2026 | 8% | 3–5% | 2% | 4% |
| S2 Jun 2027 | 6% | 2.2–3.8% | 1.5% | 3% |
| S3 Dec 2027 | 4% | 1.5–2.5% | 1% | 2% |
| xZile S4+ | 3–7% (validator TX fees) | | | |

### Burn Wars — Reward Distribution

Each cycle (Full Moon → Full Moon, ~29.5 days):

| Share | Destination |
|---|---|
| 40% | Player rewards (proportional to burn contribution) |
| 25% | Clan ranking pool (weighted leaderboard) |
| 20% | Permanent burn (0xdead) |
| 10% | Staking pool (funds APY) |
| 5% | Treasury |

Rewards are paid in the **OPPOSITE token** — the ZOD sign diametrically opposite to HOT at cycle finalization.

### Elemental NFTs — Season 1 Parameters (DAO-governed)

| NFT | Main Bonus | Secondary |
|---|---|---|
| 🔥 Fire | BP ×1.25, +0.25/Fire sign (max ×2.0) · Clan weight 1.5 | +50% GP |
| 💧 Water | Lunar airdrop eligibility · LP yield +5%/Water sign (max +15%) | LP Access |
| 🌬️ Air | ZOD↔ZOD swap fee 0.30%→0.20%, −0.05%/Air sign (min 0.05%) · Clan deadline 48h before FM | — |
| 🌍 Earth | +2% staking APY, +1%/Earth sign (max +5%) | +50% VP |

---

## Technical Stack

- **Solidity** `^0.8.20`
- **OpenZeppelin** 5.x
- **Standards:** ERC-20, ERC-1155
- **Current deployment:** Ethereum Sepolia (test phase)
- **Target deployment:** Polygon PoS mainnet
- **Chapter 2:** Polygon CDK Supernet (xZile, 2028)
- **AMM:** Uniswap V2

---

## Security

- xZOD is a **minimal ERC-20** — standard OpenZeppelin, no custom logic, minimal attack surface
- All protocol complexity isolated in peripheral contracts — a bug in SeasonWars cannot drain xZOD
- **Reentrancy protections** via OpenZeppelin ReentrancyGuard on all value-handling contracts
- **Access control** — Ownable pattern with role separation (owner, treasury, staking pool)
- **Non-upgradeable by design** — xZOD contract is immutable; NFTRules is the only DAO-updatable module
- Full independent audit planned before Polygon mainnet deployment
- Audit reports will be published in this repository

---

## Roadmap

| Phase | Target | Status |
|---|---|---|
| Testnet (Sepolia) | Now | ✅ Live |
| Smart contract audit | Q3 2026 | ⏳ Planned |
| ICO — Polygon mainnet | Q4 2026 | ⏳ Planned |
| Season 1 launch | 24 Dec 2026 | ⏳ Planned |
| Season 2 | Jun 2027 | ⏳ Planned |
| Season 3 | Dec 2027 | ⏳ Planned |
| xZile migration | May–Jun 2028 | 🌠 Vision |

---

## Community

- 🌐 [Website](https://xzod.io)
- 🐦 [Twitter/X](https://x.com/XzodNetwork)
- 💬 [Discord](https://discord.gg/NBSsQupfnm)
- 📱 [Telegram](https://t.me/+SIO2woyEjQozZWE0)
- 📧 [team@xzod.io](mailto:team@xzod.io)

---

## License

MIT — see [LICENSE](LICENSE)

---

*"In Zod we trust."*
