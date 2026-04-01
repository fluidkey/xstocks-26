import { GetObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { MerkleTreeFile, MerkleTreeProofEntry } from './merkle-tree-types';

const s3 = new S3Client({});

/**
 * Downloads and parses merkle-trees.json from the shared S3 bucket.
 * The bucket name is read from the PRICES_BUCKET env var.
 */
export async function loadMerkleTree(): Promise<MerkleTreeFile> {
  const bucket = process.env.PRICES_BUCKET;
  if (!bucket) throw new Error('PRICES_BUCKET env var not set');

  const response = await s3.send(new GetObjectCommand({
    Bucket: bucket,
    Key: 'merkle-trees.json',
  }));

  const body = await response.Body?.transformToString();
  if (!body) throw new Error('merkle-trees.json is empty');

  return JSON.parse(body) as MerkleTreeFile;
}

/**
 * Finds the merkle proof entry for a given vault using the exact key format.
 * The key is "chainId:vaultAddress:feePercentage" (vault address lowercased).
 * @param tree - Parsed merkle tree file
 * @param chainId - Chain ID (e.g. 1 for mainnet)
 * @param vaultAddress - Vault address
 * @param feePercentage - Fee in basis points
 */
export function findVaultProof(
  tree: MerkleTreeFile,
  chainId: number,
  vaultAddress: string,
  feePercentage: number,
): MerkleTreeProofEntry | undefined {
  const key = `${chainId}:${vaultAddress.toLowerCase()}:${feePercentage}`;
  return tree.proofs[key];
}
