# Merkle Tree Generator

Generates a Merkle tree and proofs for the `SafeEarnModule` contract's vault authorization system.

## How it works

The `SafeEarnModule` uses a single Merkle root per Safe to authorize vault configurations across all chains. Each leaf encodes:

```
keccak256(abi.encodePacked(chainId, underlyingVault, feePercentage, feeCollector))
```

The `chainId` is part of the leaf, so one root covers every chain — a vault authorized on Base can't be replayed on Arbitrum.

The tree uses OpenZeppelin's sorted-pair hashing (commutative), matching `MerkleProof.verify` on-chain. Leaf hashing uses `abi.encodePacked` (not `abi.encode`), matching the Solidity contract exactly.

## Setup

```bash
npm install
```

## Usage

1. Edit `config/vaults.json` with your vault entries
2. Run:

```bash
npm run generate
```

3. Output is written to `output/merkle-trees.json`

## Config format (`config/vaults.json`)

```json
{
  "chains": [
    {
      "chainId": 8453,
      "chainName": "base",
      "vaults": [
        {
          "underlyingVault": "0x...",
          "feePercentage": 100,
          "feeCollector": "0x..."
        }
      ]
    }
  ]
}
```

The tree grows dynamically — no padding or fixed depth. 2 vaults = tiny tree, 200 vaults = deeper tree. `MerkleProof.verify` handles any depth.

## Output format (`output/merkle-trees.json`)

```json
{
  "generatedAt": "2025-01-15T10:30:00Z",
  "root": "0x...",
  "proofs": {
    "8453:0xvaultaddress:100": {
      "chainId": 8453,
      "underlyingVault": "0x...",
      "feePercentage": 100,
      "feeCollector": "0x...",
      "leaf": "0x...",
      "proof": ["0x...", "0x..."]
    }
  }
}
```

### Proof lookup key

Each entry in `proofs` is keyed by `chainId:vaultAddress:feePercentage`:

- `chainId` — the EVM chain ID (e.g. `8453`)
- `vaultAddress` — the `underlyingVault` address, lowercased
- `feePercentage` — the fee in basis points

Example: `8453:0x7bfa7c4f149e7415b73bdedfe609237e29cbf34a:100`

This allows the same vault to exist with different fee tiers as separate leaves.

### Using the output

- `root` → pass to `onInstall(bytes)` or `changeMerkleRoot(bytes32)` on the `SafeEarnModule`
- `proof` → pass as `merkleProof` to `autoDeposit` / `autoWithdraw`
- Load the JSON in the backend at startup, lookup by key when building a tx
