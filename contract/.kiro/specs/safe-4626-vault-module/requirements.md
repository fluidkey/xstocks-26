# Requirements Document

## Introduction

This document specifies the requirements for a Solidity smart contract system consisting of three contracts: a VaultWrapperFactory, a VaultWrapper, and a SafeEarnModule. The Factory deploys middleware wrapper vaults (via CREATE2) that sit between Safe smart accounts and underlying ERC-4626 vaults, tracking per-depositor positions and applying a consistent annual fee. The SafeEarnModule is an automation module for Safe smart accounts that enables relayer-triggered deposits and withdrawals through wrapper vaults, verified on-chain via merkle proofs. Unlike the v2 reference (which uses a global yield-based fee), this system uses per-depositor position tracking with a fixed annual percentage fee independent of underlying vault APY. The system is built using Foundry (forge) inside the `contract/` folder.

## Glossary

- **Wrapper_Vault**: An ERC-4626 compliant middleware vault deployed by the Factory. It wraps an Underlying_Vault, tracks per-depositor positions, and applies a consistent annual fee. Its share token is non-transferable. It exposes a permissionless function to withdraw accumulated fees per Fee_Collector — anyone can call it and the accumulated fees for that Fee_Collector are sent directly to that Fee_Collector address.
- **Factory**: A singleton contract that deploys Wrapper_Vaults via CREATE2, ensuring a unique deterministic address per (Underlying_Vault address, Fee_Percentage) pair.
- **Safe_Module**: The SafeEarnModule contract installed on a Safe smart account. It enables authorized relayers to deposit into and withdraw from Wrapper_Vaults on behalf of the Safe, verified via merkle proofs. It stores a Root_Hash and Fee_Collector per Safe.
- **Safe**: A Gnosis Safe smart account (version 1.3.0) that acts as the depositor and asset holder. The Safe holds Wrapper_Vault shares after deposits.
- **Underlying_Vault**: Any external ERC-4626 compliant vault that the Wrapper_Vault deposits into on behalf of depositors.
- **Fee_Collector**: An address designated to receive accrued fees from depositors in a Wrapper_Vault. Set per depositor at deposit time, passed by the Safe_Module from the Safe's configuration.
- **Fee_Percentage**: A fixed annual fee rate stored as a uint256 in basis points (e.g., 50 means 0.50% per year, 100 means 1%). Valid range: 1 (0.01%) to 5000 (50%). Must be provided when deploying a Wrapper_Vault via the Factory. Applied consistently over time to the total AUM under each Fee_Collector, independent of the Underlying_Vault's yield.
- **Merkle_Proof**: A cryptographic proof used by the Safe_Module to verify that a given (Underlying_Vault address, Fee_Percentage) pair is authorized for a Safe.
- **Root_Hash**: A bytes32 merkle tree root stored in the Safe_Module per Safe, representing the set of authorized (Underlying_Vault, Fee_Percentage) pairs.
- **Depositor_Fee_Collector**: A per-depositor mapping (`mapping(address => address)`) in the Wrapper_Vault storing only the Fee_Collector address for each depositor. The depositor's share balance is tracked via the ERC20 balanceOf. All time-based fee accrual tracking lives at the Fee_Collector level, not the depositor level.
- **Virtual_Fee_Shares**: The computed (not yet minted) shares owed to fee collectors based on time elapsed and total assets under management per Fee_Collector. These are included in the Wrapper_Vault's effective totalSupply so that `convertToAssets` automatically reflects the fee dilution. They are materialized (minted and redeemed) only when `collectFees` is called.
- **Fee_Collector_State**: A per-Fee_Collector record in the Wrapper_Vault containing: total assets under management (sum of asset values of all depositors assigned to this Fee_Collector), last accrual timestamp, and settled Virtual_Fee_Shares ready for collection.
- **Relayer**: An address authorized by the Safe_Module owner to trigger deposits and withdrawals on behalf of Safes. Only authorized relayers (or the contract owner) can call deposit/withdraw functions.
- **Wrapped_Native**: The wrapped native token contract (e.g., WETH on Ethereum/Base) used when depositing or withdrawing native ETH.
- **CREATE2**: An EVM opcode that deploys contracts to deterministic addresses based on deployer address, salt, and init code hash.

## Requirements

### Requirement 1: Wrapper Vault Deployment via Factory

**User Story:** As a protocol integrator, I want to deploy wrapper vaults through a dedicated factory contract using CREATE2, so that each (underlying vault, fee percentage) pair has a unique, deterministic wrapper vault address.

#### Acceptance Criteria

1. WHEN a deployment is requested for an (Underlying_Vault address, Fee_Percentage) pair that has no existing Wrapper_Vault, THE Factory SHALL deploy a new Wrapper_Vault via CREATE2 and return the deployed address.
2. WHEN a deployment is requested for an (Underlying_Vault address, Fee_Percentage) pair that already has a deployed Wrapper_Vault, THE Factory SHALL return the existing Wrapper_Vault address without deploying a new contract.
3. THE Factory SHALL derive the CREATE2 salt from keccak256(abi.encodePacked(underlyingVault, feePercentage)), ensuring a deterministic and unique address per pair.
4. THE Factory SHALL expose a view function that computes the deterministic address of a Wrapper_Vault for a given (Underlying_Vault address, Fee_Percentage) pair without deploying it.
5. THE Factory SHALL store a mapping from the CREATE2 salt to the deployed Wrapper_Vault address, enabling lookup of existing deployments.
6. THE Factory SHALL emit an event containing the Underlying_Vault address, deployed Wrapper_Vault address, asset token address, and Fee_Percentage when a new Wrapper_Vault is deployed.

### Requirement 2: Wrapper Vault ERC-4626 Compliance

**User Story:** As a depositor, I want the wrapper vault to be ERC-4626 compliant, so that it integrates with standard vault tooling and interfaces.

#### Acceptance Criteria

1. THE Wrapper_Vault SHALL implement the full ERC-4626 interface including deposit, mint, withdraw, redeem, and all required view functions (totalAssets, convertToShares, convertToAssets, maxDeposit, maxMint, maxWithdraw, maxRedeem, previewDeposit, previewMint, previewWithdraw, previewRedeem).
2. THE Wrapper_Vault SHALL deposit received assets into the Underlying_Vault and hold the Underlying_Vault's shares on behalf of all depositors.
3. WHEN a deposit is made, THE Wrapper_Vault SHALL mint shares to the depositor according to the Wrapper_Vault's own asset-to-share ratio, where the effective totalSupply includes Virtual_Fee_Shares so that the share price automatically reflects fee dilution.
4. WHEN a withdrawal or redemption is made, THE Wrapper_Vault SHALL settle accrued Virtual_Fee_Shares for the depositor, then redeem the corresponding shares from the Underlying_Vault and return assets to the receiver.
5. THE Wrapper_Vault SHALL store the Underlying_Vault address and the Fee_Percentage as immutable constructor parameters.
6. THE Wrapper_Vault SHALL use the same asset token as the Underlying_Vault (obtained via Underlying_Vault.asset()).
7. THE Wrapper_Vault SHALL override totalSupply to return the real minted shares plus all accumulated Virtual_Fee_Shares (settled and pending), ensuring that convertToAssets and convertToShares reflect the fee dilution at all times.

### Requirement 3: Non-Transferable Share Token

**User Story:** As a protocol designer, I want the wrapper vault's share token to be non-transferable, so that positions remain bound to the original depositor for correct per-depositor fee tracking.

#### Acceptance Criteria

1. THE Wrapper_Vault SHALL implement ERC20 for its share token with a name derived from the Underlying_Vault's name and a symbol prefixed with "w".
2. WHEN a transfer call is made on the Wrapper_Vault share token where the sender is not the zero address and the receiver is not the zero address, THE Wrapper_Vault SHALL revert the transaction.
3. WHEN a transferFrom call is made on the Wrapper_Vault share token where the sender is not the zero address and the receiver is not the zero address, THE Wrapper_Vault SHALL revert the transaction.
4. WHEN an approve call is made on the Wrapper_Vault share token, THE Wrapper_Vault SHALL revert the transaction.
5. THE Wrapper_Vault SHALL allow internal mint operations (from zero address) and burn operations (to zero address) to function normally for deposit and withdrawal flows.

### Requirement 4: Virtual Share Fee Mechanism

**User Story:** As a fee collector, I want the fee to be a fixed annual percentage applied consistently over time via virtual share dilution, so that fee accrual is automatically reflected in the ERC-4626 share price and is predictable regardless of the underlying vault's APY.

#### Acceptance Criteria

1. THE Wrapper_Vault SHALL compute Virtual_Fee_Shares per Fee_Collector based on: virtualFeeShares = convertToShares(feeCollectorTotalAUM * Fee_Percentage * elapsedTime / (10000 * 365.25 days)), where feeCollectorTotalAUM is the total asset value of all depositors assigned to that Fee_Collector, and elapsedTime is since the Fee_Collector's last accrual timestamp.
2. THE Wrapper_Vault SHALL include all accumulated Virtual_Fee_Shares (across all Fee_Collectors) in its effective totalSupply, so that `convertToAssets(shares)` automatically returns the post-fee value for depositors.
3. THE Wrapper_Vault SHALL track per Fee_Collector: total assets under management, last accrual timestamp, and settled Virtual_Fee_Shares. Pending (unsettled) virtual shares are computed on the fly from AUM, Fee_Percentage, and elapsed time.
4. THE Wrapper_Vault SHALL accept any Fee_Percentage from 1 (0.01% annual) to 5000 (50% annual) as valid values. A Fee_Percentage of 0 SHALL cause the Factory to revert deployment. A Fee_Percentage above 5000 SHALL cause the Factory to revert deployment. The fee is expressed in basis points where 100 = 1% annual.
5. WHEN any depositor's position changes size (deposit or withdrawal) or rotates Fee_Collector, THE Wrapper_Vault SHALL first settle the affected Fee_Collector's pending Virtual_Fee_Shares (compute and add to settled total, reset timestamp), then update the Fee_Collector's total AUM.
6. THE Wrapper_Vault SHALL expose a view function that returns the total effective supply (real shares + all settled Virtual_Fee_Shares + all pending unsettled Virtual_Fee_Shares) for accurate ERC-4626 accounting.

### Requirement 5: Fee Collector Assignment and Rotation

**User Story:** As a protocol operator, I want each depositor to have a fee collector set at deposit time, with the ability to rotate to a new collector on subsequent deposits, so that fee revenue is directed correctly and past accrued virtual fee shares are settled before rotation.

#### Acceptance Criteria

1. WHEN a deposit is made for a depositor with no existing fee collector assignment, THE Wrapper_Vault SHALL record the provided Fee_Collector address for that depositor, update the Fee_Collector_State's total AUM (settling pending virtual shares first and resetting the timestamp), and set the depositor's Fee_Collector.
2. WHEN a subsequent deposit is made for a depositor with an existing fee collector assignment and a different Fee_Collector address, THE Wrapper_Vault SHALL first settle the previous Fee_Collector's pending Virtual_Fee_Shares, subtract the depositor's asset value from the previous Fee_Collector's AUM, then settle the new Fee_Collector's pending Virtual_Fee_Shares, add the depositor's updated asset value to the new Fee_Collector's AUM, and update the depositor's Fee_Collector address.
3. WHEN a subsequent deposit is made for a depositor with an existing fee collector assignment and the same Fee_Collector address, THE Wrapper_Vault SHALL settle the Fee_Collector's pending Virtual_Fee_Shares, update the AUM to reflect the new deposit, and reset the timestamp.
4. THE Wrapper_Vault SHALL accept the Fee_Collector address as a parameter on the deposit function (extending the standard ERC-4626 deposit signature).
5. IF a deposit is made with a zero-address Fee_Collector, THEN THE Wrapper_Vault SHALL revert the transaction.

### Requirement 6: Fee Collection via Virtual Share Redemption

**User Story:** As a fee collector, I want to withdraw all accumulated virtual fee shares assigned to my address from the wrapper vault, so that the protocol receives its revenue.

#### Acceptance Criteria

1. THE Wrapper_Vault SHALL expose a collectFees function that accepts a Fee_Collector address, mints the accumulated Virtual_Fee_Shares for that Fee_Collector, redeems them from the Underlying_Vault, and transfers the resulting assets to that Fee_Collector address.
2. THE collectFees function SHALL be callable by anyone (permissionless), with assets only transferable to the specified Fee_Collector address.
3. THE Wrapper_Vault SHALL track settled Virtual_Fee_Shares per Fee_Collector address, so that collection can be done in a single call per Fee_Collector rather than per depositor.
4. WHEN collectFees is called, THE Wrapper_Vault SHALL mint the accumulated Virtual_Fee_Shares (making them real shares), then immediately redeem them from the Underlying_Vault and transfer the assets to the Fee_Collector. After redemption, the minted shares are burned, reducing totalSupply back down.
5. WHEN collectFees is called and the accumulated Virtual_Fee_Shares for that Fee_Collector is zero, THE Wrapper_Vault SHALL complete without minting, redeeming, or transferring any assets.
6. WHEN fees are settled during deposit, withdrawal, or fee collector rotation for a depositor, THE Wrapper_Vault SHALL compute the depositor's pending Virtual_Fee_Shares and add them to the per-Fee_Collector settled total.

### Requirement 7: On-Chain Depositor Config and Fee Tracking

**User Story:** As a protocol operator, I want liberal on-chain storage for position and fee tracking, so that fee calculations are always correct and the system is simple to audit.

#### Acceptance Criteria

1. THE Wrapper_Vault SHALL store per-depositor only the Fee_Collector address. The depositor's share balance is tracked via the ERC20 balanceOf.
2. THE Wrapper_Vault SHALL store per-Fee_Collector a Fee_Collector_State containing: total assets under management (uint256), last accrual timestamp (uint256), and settled Virtual_Fee_Shares (uint256).
3. THE Wrapper_Vault SHALL store a global total of all settled Virtual_Fee_Shares across all Fee_Collectors, used to compute the effective totalSupply.
4. THE Wrapper_Vault SHALL update the affected Fee_Collector_State (settle pending, update AUM, reset timestamp) on every deposit, withdrawal, redemption, fee collection, and fee collector rotation.
5. THE Wrapper_Vault SHALL expose view functions to query: a depositor's Fee_Collector, a Fee_Collector's current state (AUM, settled virtual shares, pending virtual shares, total claimable asset value), and the global effective totalSupply.
6. THE Wrapper_Vault SHALL expose a view function that returns the real-time pending Virtual_Fee_Shares for a given Fee_Collector, computed from the Fee_Collector's AUM, Fee_Percentage, and time elapsed since last accrual — in O(1) without iteration.

### Requirement 8: Safe Module Initialization

**User Story:** As a Safe owner, I want to initialize the Safe Module with a root hash and fee collector address, so that only authorized vaults can be used and fees from my Safe's deposits are directed to the correct collector.

#### Acceptance Criteria

1. WHEN a Safe enables the Safe_Module via onInstall, THE Safe_Module SHALL decode and store both the Root_Hash (bytes32) and the Fee_Collector (address) for that Safe.
2. IF the provided Root_Hash is bytes32(0), THEN THE Safe_Module SHALL revert the transaction.
3. IF the provided Fee_Collector is the zero address, THEN THE Safe_Module SHALL revert the transaction.
4. IF the Safe_Module is already initialized for the calling Safe, THEN THE Safe_Module SHALL revert the transaction.
5. THE Safe_Module SHALL allow an initialized Safe to update its Root_Hash by calling a changeMerkleRoot function (callable only by the Safe itself).
6. WHEN a Safe calls onUninstall, THE Safe_Module SHALL clear the Root_Hash and Fee_Collector for that Safe.

### Requirement 9: Relayer Signature Authorization

**User Story:** As a protocol operator, I want deposits and withdrawals to be authorized via relayer signatures, so that anyone can submit the transaction but only signed operations from authorized relayers are executed, with replay protection.

#### Acceptance Criteria

1. THE Safe_Module SHALL maintain a mapping of authorized Relayer addresses.
2. THE Safe_Module SHALL require a valid ECDSA signature from an authorized Relayer on every autoDeposit and autoWithdraw call. The caller (msg.sender) does not need to be the relayer — anyone can submit the transaction.
3. THE Safe_Module SHALL recover the signer address from the signature using ECDSA recovery and verify that the recovered address is an authorized Relayer.
4. IF the recovered signer is not an authorized Relayer, THEN THE Safe_Module SHALL revert with a descriptive error.
5. THE Safe_Module SHALL include a nonce in the signed message to ensure uniqueness, and SHALL store executed message hashes in an `executedHashes` mapping to prevent replay attacks.
6. IF a signature has already been used (message hash exists in executedHashes), THEN THE Safe_Module SHALL revert the transaction.
7. THE signed message SHALL include at minimum: chainId, relevant operation parameters (token, amount/shares, vault, safe address), and nonce — ensuring signatures are chain-specific and operation-specific.
8. THE Safe_Module SHALL allow the contract owner to add and remove authorized Relayers.
9. THE Safe_Module constructor SHALL accept an initial authorized Relayer address and the contract owner address.

### Requirement 10: Deposit via Safe Module

**User Story:** As an authorized relayer, I want to trigger deposits through the Safe Module using merkle proofs, so that Safe assets are deposited into authorized wrapper vaults with correct fee collector assignment.

#### Acceptance Criteria

1. WHEN autoDeposit is called with a valid Merkle_Proof for an authorized (Underlying_Vault, Fee_Percentage) pair, THE Safe_Module SHALL execute a deposit through the Wrapper_Vault on behalf of the Safe using execTransactionFromModule.
2. THE Safe_Module SHALL verify the Merkle_Proof against the Safe's stored Root_Hash before executing any deposit, where the leaf is keccak256(abi.encodePacked(underlyingVault, feePercentage)).
3. IF the Merkle_Proof is invalid, THEN THE Safe_Module SHALL revert the transaction.
4. WHEN executing a deposit, THE Safe_Module SHALL pass the Safe's configured Fee_Collector address to the Wrapper_Vault's deposit function.
5. WHEN a Wrapper_Vault for the (Underlying_Vault, Fee_Percentage) pair does not yet exist, THE Safe_Module SHALL deploy it via the Factory before executing the deposit.
6. WHEN the token to deposit is the native token (ETH), THE Safe_Module SHALL first wrap it to Wrapped_Native (WETH) via the Safe before approving and depositing.
7. THE Safe_Module SHALL approve the Wrapper_Vault to spend the deposit amount from the Safe before calling deposit.
8. THE Safe_Module SHALL emit an event containing the Safe address, token address, Underlying_Vault address, and deposited amount after a successful deposit.

### Requirement 11: Withdrawal via Safe Module

**User Story:** As an authorized relayer, I want to trigger withdrawals through the Safe Module, so that funds can be returned from wrapper vaults to the Safe.

#### Acceptance Criteria

1. WHEN autoWithdraw is called for a Safe's position in a Wrapper_Vault, THE Safe_Module SHALL execute a redemption of wrapper shares on behalf of the Safe using execTransactionFromModule.
2. THE Safe_Module SHALL verify the Merkle_Proof against the Safe's stored Root_Hash before executing any withdrawal, using the same leaf format as deposits.
3. IF the Merkle_Proof is invalid, THEN THE Safe_Module SHALL revert the transaction.
4. THE Safe_Module SHALL return the withdrawn assets to the Safe address (Safe is both the share owner and the asset receiver).
5. WHEN the original token is the native token, THE Safe_Module SHALL unwrap Wrapped_Native (WETH) back to ETH after redemption via the Safe.
6. IF no Wrapper_Vault exists for the specified vault (wrapper address is zero), THEN THE Safe_Module SHALL revert the transaction.
7. THE Safe_Module SHALL emit an event containing the Safe address, token address, Underlying_Vault address, redeemed shares, and returned assets after a successful withdrawal.

### Requirement 12: Merkle Leaf Format

**User Story:** As a protocol operator, I want the merkle leaf to encode (underlying vault, fee percentage), so that different fee tiers for the same vault produce different merkle leaves and map to different wrapper vaults.

#### Acceptance Criteria

1. THE Safe_Module SHALL compute merkle leaves as keccak256(abi.encodePacked(underlyingVault, feePercentage)) where underlyingVault is an address and feePercentage is a uint256.
2. THE Safe_Module SHALL use OpenZeppelin's MerkleProof library for proof verification.
3. WHEN the same Underlying_Vault appears in the merkle tree with different Fee_Percentage values, THE Safe_Module SHALL treat each as a distinct authorized entry, resulting in distinct Wrapper_Vaults via the Factory.

### Requirement 13: Foundry Project Structure

**User Story:** As a developer, I want the project to use Foundry (forge) inside the contract/ folder, so that the codebase follows standard Solidity development practices.

#### Acceptance Criteria

1. THE project SHALL be structured as a Foundry project inside the `contract/` directory, with standard `src/`, `test/`, and `script/` subdirectories.
2. THE project SHALL include a `foundry.toml` configuration file in the `contract/` directory with Solidity version 0.8.23, optimizer enabled with 200 runs, and EVM version paris.
3. THE project SHALL use OpenZeppelin contracts as a dependency for ERC-4626, ERC20, Ownable, and MerkleProof implementations.
4. THE project SHALL use Safe smart account interfaces for module integration (execTransactionFromModule).
