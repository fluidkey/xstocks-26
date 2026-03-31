# Implementation Plan: Safe 4626 Vault Module

## Overview

Incrementally build three Solidity contracts (VaultWrapperFactory, VaultWrapper, SafeEarnModule) inside `contract/` using Foundry. Each task builds on the previous, with property-based fuzz tests placed close to the code they validate. A mock ERC-4626 vault is created first to enable isolated testing throughout.

## Tasks

- [ ] 1. Scaffold Foundry project and shared infrastructure
  - [ ] 1.1 Initialize Foundry project in `contract/`
    - Create `contract/foundry.toml` matching reference config (solc 0.8.23, optimizer 200 runs, paris EVM)
    - Create `contract/remappings.txt` with OpenZeppelin, Safe, and forge-std mappings
    - Install dependencies: `forge install OpenZeppelin/openzeppelin-contracts`, `forge install safe-global/safe-contracts`, `forge install foundry-rs/forge-std`
    - Create directory structure: `contract/src/`, `contract/test/`, `contract/test/mocks/`, `contract/script/`
    - _Requirements: 13.1, 13.2, 13.3, 13.4_

  - [ ] 1.2 Create `ISafe.sol` interface and mock ERC-4626 vault
    - Create `contract/src/ISafe.sol` with `execTransactionFromModule` signature matching Safe 1.3.0
    - Create `contract/test/mocks/MockERC4626.sol` — a minimal ERC-4626 vault (OpenZeppelin ERC4626 with a simple ERC20 asset) for isolated testing
    - _Requirements: 13.4_

- [ ] 2. Implement VaultWrapperFactory
  - [ ] 2.1 Create `contract/src/VaultWrapperFactory.sol`
    - Implement `deploy(address underlyingVault, uint256 feePercentage)` using CREATE2 with salt = `keccak256(abi.encodePacked(underlyingVault, feePercentage))`
    - Implement `computeAddress(address underlyingVault, uint256 feePercentage)` view function
    - Store `mapping(bytes32 => address) public deployedWrappers` for O(1) lookup
    - Validate fee range [1, 5000] bps, revert on 0 or >5000; validate underlyingVault != address(0)
    - Emit `WrapperDeployed` event on new deployments
    - Return existing address on duplicate deploy calls without redeploying
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 4.4_

  - [ ] 2.2 Write property test: Factory Deploy Idempotence
    - **Property 1: Factory Deploy Idempotence**
    - Fuzz over random vault addresses and fee percentages; assert two consecutive deploys return the same address
    - **Validates: Requirements 1.2**

  - [ ] 2.3 Write property test: Factory CREATE2 Determinism
    - **Property 2: Factory CREATE2 Determinism**
    - Fuzz over random vault addresses and fee percentages; assert `computeAddress` matches `deploy` result
    - **Validates: Requirements 1.3, 1.4**

  - [ ] 2.4 Write property test: Fee Percentage Validation
    - **Property 3: Fee Percentage Validation**
    - Fuzz over uint256 feePercentage; assert revert when 0 or >5000, success when in [1, 5000]
    - **Validates: Requirements 4.4**

  - [ ] 2.5 Write unit tests for VaultWrapperFactory
    - Test event emission on deploy
    - Test boundary fee values (1, 5000)
    - Test invalid fee values (0, 5001)
    - Test zero-address underlying vault revert
    - Place in `contract/test/VaultWrapperFactory.t.sol`
    - _Requirements: 1.1, 1.2, 1.6, 4.4_

- [ ] 3. Checkpoint — Factory tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 4. Implement VaultWrapper core (ERC20, non-transferable, constructor)
  - [ ] 4.1 Create `contract/src/VaultWrapper.sol` — ERC20 base and immutables
    - Extend OpenZeppelin ERC20 with name derived from underlying vault name, symbol prefixed with "w"
    - Set immutables: `underlying` (IERC4626), `asset` (IERC20 from underlying.asset()), `feePercentage`
    - Override `transfer`, `transferFrom`, `approve` to revert (non-transferable shares)
    - Define custom errors: `TransfersDisabled`, `ApprovalsDisabled`, `ZeroFeeCollector`, `ZeroAssets`, `ZeroShares`, `InsufficientBalance`
    - Define events: `FeeCollectorChanged`, `FeesCollected`, `FeeSettled`
    - Define `FeeCollectorState` struct and storage mappings: `depositorFeeCollector`, `feeCollectorStates`, `totalSettledVirtualShares`
    - _Requirements: 2.5, 2.6, 3.1, 3.2, 3.3, 3.4, 3.5, 7.1, 7.2, 7.3_

  - [ ] 4.2 Write property test: Non-Transferable Shares
    - **Property 6: Non-Transferable Shares**
    - Fuzz over random addresses and amounts; assert `transfer`, `transferFrom`, `approve` all revert
    - **Validates: Requirements 3.2, 3.3, 3.4**

- [ ] 5. Implement VaultWrapper fee math and view functions
  - [ ] 5.1 Implement virtual fee share computation and view functions
    - Implement `getPendingVirtualShares(address feeCollector)` — O(1) computation: `convertToShares(AUM * feePercentage * elapsed / (10000 * 365.25 days))`
    - Implement `effectiveTotalSupply()` — `totalSupply() + totalSettledVirtualShares + sum of all pending virtual shares`
    - Implement `totalAssets()` — `underlying.convertToAssets(underlying.balanceOf(address(this)))`
    - Implement `convertToShares(uint256 assets)` and `convertToAssets(uint256 shares)` using `effectiveTotalSupply()` and `Math.mulDiv`
    - Implement all ERC-4626 preview and max functions
    - Implement `getFeeCollectorState` and `getDepositorFeeCollector` view helpers
    - Use OpenZeppelin `Math.mulDiv` with explicit rounding direction throughout
    - _Requirements: 2.1, 2.7, 4.1, 4.2, 4.3, 4.6, 7.5, 7.6_

  - [ ] 5.2 Write property test: Virtual Fee Shares Formula
    - **Property 7: Virtual Fee Shares Formula**
    - Fuzz over AUM, feePercentage, and elapsed time; assert pending virtual shares match the formula
    - **Validates: Requirements 4.1**

  - [ ] 5.3 Write property test: Effective Total Supply Invariant
    - **Property 5: Effective Total Supply Invariant**
    - Fuzz over sequences of deposits and time warps; assert `effectiveTotalSupply() == totalSupply() + totalSettledVirtualShares + allPendingVirtualShares`
    - **Validates: Requirements 2.7, 4.2**

- [ ] 6. Implement VaultWrapper deposit, withdraw, redeem
  - [ ] 6.1 Implement `deposit(uint256 assets, address receiver, address feeCollector)` and `mint(uint256 shares, address receiver, address feeCollector)`
    - Validate feeCollector != address(0), assets/shares > 0
    - Settle affected Fee_Collector's pending virtual shares before state mutation
    - Handle fee collector assignment: new depositor, same collector, or rotation (settle old, subtract AUM, settle new, add AUM)
    - Transfer assets from msg.sender, deposit into underlying vault, mint wrapper shares to receiver
    - Update Fee_Collector AUM and reset timestamp
    - _Requirements: 2.2, 2.3, 4.5, 5.1, 5.2, 5.3, 5.4, 5.5_

  - [ ] 6.2 Implement `withdraw(uint256 assets, address receiver, address owner)` and `redeem(uint256 shares, address receiver, address owner)`
    - Validate shares/assets > 0, owner has sufficient balance
    - Settle affected Fee_Collector's pending virtual shares before state mutation
    - Update Fee_Collector AUM (subtract withdrawn asset value)
    - Redeem from underlying vault, burn wrapper shares, transfer assets to receiver
    - _Requirements: 2.4, 4.5, 7.4_

  - [ ] 6.3 Write property test: Deposit Mints Correct Shares
    - **Property 4: Deposit Mints Correct Shares**
    - Fuzz over deposit amounts; assert minted shares == `convertToShares(assets)` computed before deposit
    - **Validates: Requirements 2.3**

  - [ ] 6.4 Write property test: Settlement on Position Change
    - **Property 8: Settlement on Position Change**
    - Fuzz over deposit/withdraw sequences with time warps; assert settled virtual shares increase and timestamp resets on each position change
    - **Validates: Requirements 4.5, 6.6, 7.4**

  - [ ] 6.5 Write property test: Fee Collector Assignment and AUM Tracking
    - **Property 9: Fee Collector Assignment and AUM Tracking**
    - Fuzz over deposits with same/different fee collectors; assert AUM updates correctly on assignment and rotation
    - **Validates: Requirements 5.1, 5.2, 5.3**

  - [ ] 6.6 Write property test: Deposit-Withdraw Round Trip
    - **Property 23: Deposit-Withdraw Round Trip**
    - Fuzz over deposit amounts; deposit then immediately redeem (no time warp); assert returned assets ≈ deposited assets (within underlying vault rounding)
    - **Validates: Requirements 2.2, 2.4**

- [ ] 7. Implement VaultWrapper fee collection
  - [ ] 7.1 Implement `collectFees(address feeCollector)`
    - Settle pending virtual shares for the fee collector
    - If settled virtual shares > 0: mint them as real shares, redeem from underlying vault, transfer assets to feeCollector, burn minted shares
    - If settled virtual shares == 0: no-op
    - Reset settled virtual shares and update `totalSettledVirtualShares`
    - Emit `FeesCollected` event
    - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5_

  - [ ] 7.2 Write property test: Fee Collection Transfers to Collector
    - **Property 10: Fee Collection Transfers to Collector**
    - Fuzz over fee collector addresses; assert assets go exclusively to the feeCollector address
    - **Validates: Requirements 6.1, 6.2**

  - [ ] 7.3 Write property test: Fee Collection Preserves Real Total Supply
    - **Property 11: Fee Collection Preserves Real Total Supply**
    - Assert ERC20 `totalSupply()` before collectFees == `totalSupply()` after collectFees
    - **Validates: Requirements 6.4**

  - [ ] 7.4 Write property test: Global Settled Virtual Shares Consistency
    - **Property 12: Global Settled Virtual Shares Consistency**
    - Fuzz over deposit/withdraw/collect sequences; assert `totalSettledVirtualShares` == sum of all individual `feeCollectorStates[fc].settledVirtualShares`
    - **Validates: Requirements 7.3**

- [ ] 8. Checkpoint — VaultWrapper tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 9. Implement SafeEarnModule — lifecycle and relayer management
  - [ ] 9.1 Create `contract/src/SafeEarnModule.sol` — constructor, storage, relayer management
    - Extend OpenZeppelin Ownable
    - Set immutables: `wrappedNative`, `factory`
    - Define `SafeConfig` struct, `safeConfigs` mapping, `authorizedRelayers` mapping, `executedHashes` mapping
    - Define all custom errors and events per design
    - Constructor: accept initial relayer, wrappedNative, owner, factory; set `authorizedRelayers[initialRelayer] = true`
    - Implement `addAuthorizedRelayer` (owner or authorized relayer can call), `removeAuthorizedRelayer` (owner or authorized relayer, cannot remove self)
    - Define `NATIVE_TOKEN` constant
    - _Requirements: 9.1, 9.8, 9.9_

  - [ ] 9.2 Implement module lifecycle: `onInstall`, `onUninstall`, `changeMerkleRoot`, `isInitialized`
    - `onInstall`: decode (rootHash, feeCollector), validate non-zero, revert if already initialized, store config, emit event
    - `onUninstall`: clear config, emit event
    - `changeMerkleRoot`: callable by Safe only (msg.sender), validate non-zero root, update rootHash, emit event
    - `isInitialized`: return rootHash != bytes32(0)
    - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6_

  - [ ] 9.3 Write property test: Module onInstall Stores Config
    - **Property 13: Module onInstall Stores Config**
    - Fuzz over random rootHash and feeCollector; assert stored values match and isInitialized returns true
    - **Validates: Requirements 8.1**

  - [ ] 9.4 Write property test: Module changeMerkleRoot
    - **Property 14: Module changeMerkleRoot**
    - Fuzz over random new roots; assert rootHash updates and feeCollector unchanged
    - **Validates: Requirements 8.5**

  - [ ] 9.5 Write property test: Module onUninstall Clears Config
    - **Property 15: Module onUninstall Clears Config**
    - Fuzz over random configs; assert both fields cleared and isInitialized returns false after uninstall
    - **Validates: Requirements 8.6**

  - [ ] 9.6 Write property test: Relayer Management
    - **Property 18: Relayer Management**
    - Fuzz over random addresses; assert add/remove behavior and self-removal revert
    - **Validates: Requirements 9.8**

- [ ] 10. Implement SafeEarnModule — signature verification and replay protection
  - [ ] 10.1 Implement signature verification and replay protection helpers
    - Build message hash from (chainId, token, amount/shares, underlyingVault, feePercentage, safe, nonce) using `abi.encode` + `keccak256`
    - Convert to EIP-191 eth_signedMessage hash via `MessageHashUtils.toEthSignedMessageHash`
    - Recover signer via `ECDSA.recover`, check `authorizedRelayers[signer]`
    - Store used hash in `executedHashes`, revert on duplicate
    - _Requirements: 9.2, 9.3, 9.4, 9.5, 9.6, 9.7_

  - [ ] 10.2 Write property test: Signature Verification
    - **Property 16: Signature Verification**
    - Fuzz over random private keys; sign messages, assert authorized signers succeed and unauthorized revert
    - **Validates: Requirements 9.2, 9.3, 9.4**

  - [ ] 10.3 Write property test: Replay Protection
    - **Property 17: Replay Protection**
    - Fuzz over valid signatures; assert second submission reverts with `SignatureAlreadyUsed`
    - **Validates: Requirements 9.5, 9.6**

- [ ] 11. Implement SafeEarnModule — autoDeposit and autoWithdraw
  - [ ] 11.1 Implement `autoDeposit`
    - Verify signature and replay protection
    - Verify merkle proof: leaf = `keccak256(abi.encodePacked(underlyingVault, feePercentage))`, verify against `safeConfigs[safe].rootHash`
    - Get or deploy wrapper via `factory.deploy(underlyingVault, feePercentage)`
    - Handle native token: if token == NATIVE_TOKEN, wrap ETH to WETH via Safe's execTransactionFromModule
    - Approve wrapper to spend tokens from Safe via execTransactionFromModule
    - Call `wrapper.deposit(amount, safe, feeCollector)` via Safe's execTransactionFromModule
    - Emit `AutoDepositExecuted` event
    - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.5, 10.6, 10.7, 10.8_

  - [ ] 11.2 Implement `autoWithdraw`
    - Verify signature and replay protection
    - Verify merkle proof
    - Compute wrapper address via `factory.computeAddress`, revert if not deployed (`WrapperNotDeployed`)
    - Call `wrapper.redeem(shares, safe, safe)` via Safe's execTransactionFromModule
    - Handle native token: if token == NATIVE_TOKEN, unwrap WETH to ETH via Safe's execTransactionFromModule
    - Emit `AutoWithdrawExecuted` event
    - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5, 11.6, 11.7_

  - [ ] 11.3 Write property test: Merkle Proof Verification
    - **Property 19: Merkle Proof Verification**
    - Fuzz over random vault/fee pairs and invalid proofs; assert revert with `InvalidMerkleProof`
    - **Validates: Requirements 10.2, 10.3, 11.2, 11.3**

  - [ ] 11.4 Write property test: Merkle Leaf Uniqueness
    - **Property 22: Merkle Leaf Uniqueness**
    - Fuzz over two distinct (vault, fee) pairs; assert computed leaves differ
    - **Validates: Requirements 12.1, 12.3**

- [ ] 12. Checkpoint — SafeEarnModule tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 13. Integration tests — end-to-end flows
  - [ ] 13.1 Write property test: Deposit Flow Correctness
    - **Property 20: Deposit Flow Correctness**
    - Fuzz over deposit amounts with mock Safe and underlying vault; assert Safe receives wrapper shares, wrapper holds underlying shares, fee collector assignment correct
    - **Validates: Requirements 10.1, 10.4**

  - [ ] 13.2 Write property test: Withdrawal Flow Correctness
    - **Property 21: Withdrawal Flow Correctness**
    - Fuzz over withdrawal amounts; assert Safe's wrapper shares decrease and asset balance increases
    - **Validates: Requirements 11.1, 11.4**

  - [ ] 13.3 Write integration unit tests
    - Full deposit → time warp → fee collection → withdraw flow through module → wrapper → underlying
    - Native token wrap/unwrap deposit and withdraw flows
    - Place in `contract/test/Integration.t.sol`
    - _Requirements: 10.1, 11.1, 6.1_

- [ ] 14. Final checkpoint — All tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- Property tests validate universal correctness properties via Foundry fuzz testing
- Unit tests validate specific examples and edge cases
- All 23 correctness properties from the design document are covered
