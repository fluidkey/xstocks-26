# Fluid Stocks

Non-custodial crypto platform where users hold funds in personal smart accounts (Gnosis Safe) and earn yield automatically — without giving up custody.

## The idea

Traditional finance makes earning yield easy but requires trusting a custodian. DeFi vaults offer yield without custody, but require users to manually manage deposits, track fees, and interact with complex protocols.

Fluid Stocks bridges this gap. Each user gets a personal Safe smart account. Funds stay in the user's Safe at all times — they're never pooled or held by a third party. An automated system handles deposits into yield-bearing vaults and withdrawals back to the Safe, all governed by on-chain authorization and cryptographic signatures.

The user stays in control. The automation just does the heavy lifting.

## Auto-Earn: how it works

This is the core innovation. The `SafeEarnModule` is a Gnosis Safe module that allows an authorized backend to move funds between a user's Safe and ERC-4626 yield vaults — but only under strict constraints:

1. The Safe owner pre-approves a set of vaults via a merkle root (each leaf encodes chain, vault address, fee tier, and fee collector)
2. Every deposit/withdraw operation requires a valid ECDSA signature from an authorized operator, plus a merkle proof that the target vault is whitelisted
3. Each signature includes a nonce and chain ID — preventing replay attacks across transactions and chains
4. The Safe owner can update or revoke the vault whitelist at any time by changing the merkle root

Funds flow through a `VaultWrapper` — an ERC-4626 middleware contract that sits between the Safe and the underlying vault. The wrapper:
- Applies a transparent annualized fee via virtual share dilution (no surprise deductions — the share price smoothly reflects fees in real time)
- Issues non-transferable shares (your position, your Safe, no one else's)
- Is deployed deterministically via CREATE2 through a factory — one wrapper per (vault, fee, collector) combination

The result: users get automated yield with full custody, transparent fees, and cryptographic guarantees that the system can only do what they've explicitly authorized.

```
Safe Owner
    │
    │  sets merkle root (authorized vaults)
    ▼
┌──────────────┐     signature + proof     ┌──────────────────┐     deposit/withdraw     ┌──────────────┐
│  Gnosis Safe  │◄─────────────────────────│  SafeEarnModule  │─────────────────────────▶│ VaultWrapper │──▶ Underlying Vault
│  (user funds) │                          │  (authorization)  │                          │  (fee layer) │
└──────────────┘                           └──────────────────┘                          └──────────────┘
```

## Repo structure

```
├── contract/     Solidity smart contracts — the auto-earn module, vault wrappers, factory (Foundry)
├── backend/      AWS serverless stack — orchestrates wallet tracking, transaction history, price feeds
├── frontend/     Demo UI showing two flows: fund your Safe, and auto-earn yield (Next.js)
└── scripts/      Merkle tree generator for vault authorization config
```

### contract/

The core of the project. Three contracts:

| Contract | Role |
|---|---|
| `SafeEarnModule` | Safe module — validates signatures + merkle proofs, orchestrates deposits/withdrawals through the Safe |
| `VaultWrapper` | ERC-4626 wrapper with non-transferable shares and smooth fee accrual via share dilution |
| `VaultWrapperFactory` | Deterministic CREATE2 factory — one wrapper per (vault, fee, collector) triple |

```bash
cd contract
forge build && forge test
```

### backend/

Serverless backend that tracks on-chain activity (transfers in/out of user Safes), stores transaction history, and serves token prices. Provides the REST API the frontend consumes.

```bash
cd backend
yarn install && npx projen deploy
```

### frontend/

Demo app with two flows: funding a Safe (receiving bank transfers that convert to on-chain deposits) and viewing auto-earn positions. Built with Next.js, wagmi, and viem.

```bash
cd frontend
npm install && npm run dev
```

### scripts/

Generates the merkle tree and proofs used by `SafeEarnModule` to authorize vaults. Configure vaults in `config/vaults.json`, run the generator, and use the output root on-chain.

```bash
cd scripts
npm install && npm run generate
```

## Tech stack

| Layer | Tech |
|---|---|
| Smart contracts | Solidity 0.8.30, Foundry, Gnosis Safe, ERC-4626, OpenZeppelin |
| Backend | AWS CDK, Lambda, DynamoDB, S3, API Gateway |
| Frontend | Next.js 16, React 19, Tailwind CSS, wagmi, viem |

## License

See individual package directories for license information.