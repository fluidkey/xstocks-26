/**
 * Vault entry from the config file.
 * Represents a single ERC-4626 vault with its fee configuration.
 */
export interface VaultEntry {
  /** The ERC-4626 vault contract address */
  underlyingVault: string;
  /** Human-readable vault name */
  vaultName: string;
  /** Fee in basis points (1–5000) */
  feePercentage: number;
  /** Address that receives the fees */
  feeCollector: string;
}

/**
 * Chain configuration grouping vaults by EVM chain.
 */
export interface ChainConfig {
  /** EVM chain ID (e.g. 8453 for Base) */
  chainId: number;
  /** Human-readable chain name (optional, not used in output) */
  chainName?: string;
  /** Authorized vaults for this chain */
  vaults: VaultEntry[];
}

/**
 * Top-level config file structure read from vaults.json.
 */
export interface VaultsConfig {
  /** Array of per-chain vault configurations */
  chains: ChainConfig[];
}

/**
 * Proof data for a single vault, used by the backend
 * to call autoDeposit/autoWithdraw on the SafeEarnModule.
 */
export interface VaultProof {
  /** EVM chain ID this vault belongs to */
  chainId: number;
  /** Human-readable vault name */
  vaultName: string;
  /** The ERC-4626 vault address */
  underlyingVault: string;
  /** Fee in basis points */
  feePercentage: number;
  /** Fee collector address */
  feeCollector: string;
  /** The keccak256 leaf hash */
  leaf: string;
  /** Merkle proof path (array of bytes32 hex strings) */
  proof: string[];
}

/**
 * Complete output file structure written to merkle-trees.json.
 * One single Merkle root covers all chains — chainId is part of each leaf.
 */
export interface MerkleOutput {
  /** ISO 8601 timestamp of generation */
  generatedAt: string;
  /** Single Merkle root for all chains (used in onInstall/changeMerkleRoot) */
  root: string;
  /** Flat map of all vault proofs keyed by "chainId:lowercasedVaultAddress" */
  proofs: Record<string, VaultProof>;
}
