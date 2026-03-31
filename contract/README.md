# Safe 4626 Vault Module

Solidity smart contracts for automated ERC-4626 vault deposits/withdrawals through Gnosis Safe, with per-depositor fee tracking via virtual share dilution.

## Contracts

- **VaultWrapperFactory** — Deploys VaultWrapper instances via CREATE2. One unique wrapper per (vault, fee) pair.
- **VaultWrapper** — ERC-4626 middleware vault with non-transferable shares. Sits between depositors and underlying vaults, applying a fixed annual % fee.
- **SafeEarnModule** — Safe module for relayer-triggered deposits/withdrawals. Uses merkle proofs + ECDSA signatures with replay protection.

## Setup

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
# Clone and init submodules
git submodule update --init --recursive

# Build
forge build

# Test
forge test

# Test with verbosity
forge test -vvv
```

## Project Structure

```
src/
├── VaultWrapperFactory.sol
├── VaultWrapper.sol
├── SafeEarnModule.sol
└── ISafe.sol
test/
├── VaultWrapperFactory.t.sol
├── VaultWrapper.t.sol
├── SafeEarnModule.t.sol
├── Integration.t.sol
└── mocks/
    └── MockERC4626.sol
```
