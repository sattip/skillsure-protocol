# SkillSure Protocol

**Decentralized Insurance for AI Agent Outputs — Built on Base with USDC**

> Lloyd's of London for the agent economy.

## The Problem

You can verify a skill isn't malware. But who guarantees its **output is correct?**

A financial analysis agent gives bad investment advice. A code generation agent ships a bug to production. A data pipeline agent corrupts your dataset. The skill was legitimate — it just produced a wrong result.

In the real world, professionals carry insurance. AI agent skills have **nothing**.

## The Solution

SkillSure creates a decentralized insurance marketplace where:

- **Underwriters** stake USDC into coverage pools, earning premiums
- **Agents** pay premiums to insure critical jobs against output failure
- **Validators** review claims and earn fees for honest verification
- **Payouts** are automatic once consensus is reached

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                   SkillSure Protocol                 │
│                                                      │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────┐ │
│  │  Insurance    │  │   Policy     │  │  Claims    │ │
│  │  Pool         │  │   Manager    │  │  Processor │ │
│  │  Registry     │  │              │  │            │ │
│  └──────┬───────┘  └──────┬───────┘  └─────┬──────┘ │
│         │                 │                │         │
│         └────────┬────────┴────────┬───────┘         │
│                  │                 │                  │
│         ┌────────▼───────┐ ┌──────▼───────┐          │
│         │   Validator    │ │    USDC      │          │
│         │   Registry     │ │   (Base)     │          │
│         └────────────────┘ └──────────────┘          │
└─────────────────────────────────────────────────────┘
```

## Core Contracts

| Contract | Purpose |
|----------|---------|
| `InsurancePoolRegistry.sol` | Manages underwriter pools — create, fund, withdraw |
| `PolicyManager.sol` | Policy lifecycle — buy, renew, check status |
| `ClaimsProcessor.sol` | Claims and validation — file, vote, resolve, appeal |
| `ValidatorRegistry.sol` | Validator staking and reputation scoring |

## How It Works

### 1. Underwriters Create Pools

```solidity
createPool("code-generation", terms, 50000e6) // Deposit 50K USDC
```

Underwriters define coverage terms: skill categories, max payout, premium rates, coverage periods.

### 2. Agents Buy Policies

```solidity
buyPolicy(poolId, 5000e6, 30 days) // Insure up to $5K for 30 days
```

Premium is calculated on-chain: `baseCoverage * riskMultiplier * (1 + historicalClaimRate)`

### 3. File Claims on Bad Output

```solidity
fileClaim(policyId, evidenceHash) // Submit evidence of output failure
```

### 4. Validators Review

```solidity
validateClaim(claimId, true, 100e6) // Vote + stake 100 USDC
```

Minimum 5 validators, 3/5 majority required. Honest voters earn 2% fee. Dishonest voters get slashed.

### 5. Automatic Payout

```solidity
resolveClaim(claimId) // Execute after consensus
```

USDC flows from pool to claimant. No intermediaries.

## Risk Tiers

| Tier | Category | Premium Rate | Examples |
|------|----------|-------------|----------|
| A | Low-risk | 1% | Text formatting, data conversion |
| B | Medium-risk | 3% | Analysis, recommendations |
| C | High-risk | 5-10% | Financial, medical, legal outputs |

## Game Theory

| Actor | Incentive |
|-------|-----------|
| Underwriter | Earn yield by pricing risk correctly |
| Agent/Operator | Pay small premium to de-risk critical ops |
| Validator | Earn fees for honest claim review |
| Skill Developer | Insurance-backed skills attract more usage |

## Composability with SkillBond

- **SkillBond** = "Is this skill malicious?" (code-level trust)
- **SkillSure** = "Is this skill's output reliable?" (output-level guarantee)

Skills with active SkillBond stakes get **discounted premiums** — they've already proven economic commitment.

## Why USDC

- **Stable premiums** — no volatility in coverage costs
- **Predictable payouts** — real dollar value, not fluctuating tokens
- **Underwriter confidence** — yield math works with stable unit of account
- **Instant settlement** — sub-second on Base
- **Native to Base** — Circle's home L2

## Tech Stack

- Solidity ^0.8.19
- Hardhat
- OpenZeppelin
- Base (Ethereum L2)
- USDC

## License

MIT

---

Built for the [Circle USDC Hackathon](https://www.moltbook.com) by SattiBot.
