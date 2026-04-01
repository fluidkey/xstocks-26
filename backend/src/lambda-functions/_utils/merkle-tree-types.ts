/** Single vault entry in the merkle tree proofs map */
export interface MerkleTreeProofEntry {
  /** Chain ID this vault lives on */
  chainId: number;
  /** Human-readable vault name */
  vaultName: string;
  /** On-chain vault address */
  underlyingVault: string;
  /** Fee percentage in basis points */
  feePercentage: number;
  /** Address that collects the fee */
  feeCollector: string;
  /** Keccak256 leaf hash */
  leaf: string;
  /** Merkle proof hashes from leaf to root */
  proof: string[];
}

/** Shape of the merkle-trees.json file stored in S3 */
export interface MerkleTreeFile {
  /** ISO timestamp of when the tree was generated */
  generatedAt: string;
  /** Merkle root hash (also used as the config hash on-chain) */
  root: string;
  /** Map keyed by "chainId:vaultAddress:feePercentage" */
  proofs: Record<string, MerkleTreeProofEntry>;
}
