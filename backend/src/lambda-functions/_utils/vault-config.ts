/**
 * Static mapping of token addresses to their target vault config.
 * chainId + vaultAddress + feePercentage form the exact key
 * used to look up the merkle proof in merkle-trees.json at runtime.
 */

/** Each entry maps a token we auto-earn on to its vault parameters */
export const TOKEN_TO_VAULT: Array<{
  /** ERC-20 token address that triggers auto-earn when received */
  tokenAddress: `0x${string}`;
  /** Chain ID the vault lives on */
  chainId: number;
  /** Target vault address for the autoDeposit call */
  vaultAddress: `0x${string}`;
  /** Fee percentage in basis points — must match the merkle tree leaf */
  feePercentage: number;
}> = [
  {
    // aUSD → Flowdesk AUSD RWA Strategy on mainnet
    tokenAddress: '0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a',
    chainId: 1,
    vaultAddress: '0x32401B9fb79065Bc15949DE0BD43927492f02F0C',
    feePercentage: 50,
  },
];
