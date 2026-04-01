import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { encodePacked, keccak256, getAddress, type Hex, type Address } from "viem";

import type {
  VaultsConfig,
  VaultEntry,
  VaultProof,
  MerkleOutput,
} from "./generate-merkle-tree-types.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

/**
 * Hash a leaf exactly as the Solidity contract does:
 * keccak256(abi.encodePacked(chainId, underlyingVault, feePercentage, feeCollector))
 *
 * chainId is included so a single Merkle root can authorize vaults across
 * multiple chains without cross-chain replay.
 *
 * @param chainId - EVM chain ID
 * @param vault - Vault entry with address, fee, and collector
 * @returns The keccak256 hash matching the on-chain leaf computation
 */
function hashLeaf(chainId: bigint, vault: VaultEntry): Hex {
  // Normalize addresses to valid checksummed form so viem doesn't reject them
  const underlyingVault = getAddress(vault.underlyingVault) as Address;
  const feeCollector = getAddress(vault.feeCollector) as Address;

  const packed = encodePacked(
    ["uint256", "address", "uint256", "address"],
    [chainId, underlyingVault, BigInt(vault.feePercentage), feeCollector]
  );
  return keccak256(packed);
}

/**
 * Sorted-pair hash matching OpenZeppelin's MerkleProof internal node hashing.
 * OZ sorts the two children before concatenating and hashing, making
 * proof verification order-independent (commutative hashing).
 *
 * @param a - First hash
 * @param b - Second hash
 * @returns keccak256 of the sorted concatenation
 */
function hashPair(a: Hex, b: Hex): Hex {
  const [left, right] = a < b ? [a, b] : [b, a];
  return keccak256(encodePacked(["bytes32", "bytes32"], [left, right]));
}

/**
 * Build a Merkle tree from leaf hashes using OZ-compatible sorted-pair hashing.
 * Returns all layers (bottom-up) for proof extraction.
 *
 * @param leaves - Pre-hashed leaf values
 * @returns Array of layers where layers[0] = sorted leaves, layers[last] = [root]
 */
function buildTree(leaves: Hex[]): Hex[][] {
  if (leaves.length === 0) {
    throw new Error("Cannot build a Merkle tree with zero leaves");
  }

  // Sort leaves for deterministic ordering matching OZ's approach
  const sorted = [...leaves].sort();
  const layers: Hex[][] = [sorted];

  let current = sorted;
  while (current.length > 1) {
    const next: Hex[] = [];
    for (let i = 0; i < current.length; i += 2) {
      if (i + 1 < current.length) {
        next.push(hashPair(current[i], current[i + 1]));
      } else {
        // Odd node promoted as-is
        next.push(current[i]);
      }
    }
    layers.push(next);
    current = next;
  }

  return layers;
}

/**
 * Extract the Merkle proof for a specific leaf from the tree layers.
 * Walks up from the leaf position, collecting the sibling at each level.
 *
 * @param layers - Tree layers from buildTree()
 * @param leaf - The leaf hash to generate a proof for
 * @returns Array of sibling hashes forming the proof path
 */
function getProof(layers: Hex[][], leaf: Hex): Hex[] {
  let index = layers[0].indexOf(leaf);
  if (index === -1) {
    throw new Error(`Leaf ${leaf} not found in tree`);
  }

  const proof: Hex[] = [];
  for (let i = 0; i < layers.length - 1; i++) {
    const layer = layers[i];
    const siblingIndex = index % 2 === 0 ? index + 1 : index - 1;

    if (siblingIndex < layer.length) {
      proof.push(layer[siblingIndex]);
    }

    index = Math.floor(index / 2);
  }

  return proof;
}

/**
 * Main entry point. Reads the vault config, builds a single Merkle tree
 * from ALL vaults across ALL chains (chainId is encoded in each leaf),
 * and writes the output JSON with the shared root and per-vault proofs.
 */
function main(): void {
  const configPath = resolve(__dirname, "..", "config", "vaults.json");
  const raw = readFileSync(configPath, "utf-8");
  const config: VaultsConfig = JSON.parse(raw);

  // Collect every leaf across all chains into one tree
  const allLeaves: Hex[] = [];
  const leafMeta = new Map<Hex, { chainId: number; vault: VaultEntry }>();

  for (const chain of config.chains) {
    const chainId = BigInt(chain.chainId);
    for (const vault of chain.vaults) {
      const leaf = hashLeaf(chainId, vault);
      allLeaves.push(leaf);
      leafMeta.set(leaf, { chainId: chain.chainId, vault });
    }
  }

  const totalLeaves = allLeaves.length;
  console.log(`Building single Merkle tree with ${totalLeaves} leaves across ${config.chains.length} chains`);

  const layers = buildTree(allLeaves);
  const root = layers[layers.length - 1][0];
  console.log(`Root: ${root}`);

  // Build flat proofs map keyed by "chainId:lowercasedVaultAddress"
  const proofs: Record<string, VaultProof> = {};

  for (const chain of config.chains) {
    const chainId = BigInt(chain.chainId);

    for (const vault of chain.vaults) {
      const leaf = hashLeaf(chainId, vault);
      const proof = getProof(layers, leaf);
      const key = `${chain.chainId}:${vault.underlyingVault.toLowerCase()}:${vault.feePercentage}`;

      proofs[key] = {
        chainId: chain.chainId,
        vaultName: vault.vaultName,
        underlyingVault: vault.underlyingVault,
        feePercentage: vault.feePercentage,
        feeCollector: vault.feeCollector,
        leaf,
        proof,
      };
    }

    console.log(`  chain ${chain.chainId}: ${chain.vaults.length} vaults`);
  }

  const output: MerkleOutput = {
    generatedAt: new Date().toISOString(),
    root,
    proofs,
  };

  // Write output
  const outputDir = resolve(__dirname, "..", "output");
  mkdirSync(outputDir, { recursive: true });
  const outputPath = resolve(outputDir, "merkle-trees.json");
  writeFileSync(outputPath, JSON.stringify(output, null, 2), "utf-8");

  console.log(`\nMerkle tree written to ${outputPath}`);
}

main();
