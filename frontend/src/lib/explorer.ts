/** Block explorer /tx/ base URL by chain (Etherscan family & common L2s). */
const TX_BASE_BY_CHAIN: Record<number, string> = {
  1: "https://etherscan.io/tx/",
  11155111: "https://sepolia.etherscan.io/tx/",
  8453: "https://basescan.org/tx/",
  84532: "https://sepolia.basescan.org/tx/",
  42161: "https://arbiscan.io/tx/",
  421614: "https://sepolia.arbiscan.io/tx/",
  137: "https://polygonscan.com/tx/",
  80002: "https://amoy.polygonscan.com/tx/",
  10: "https://optimistic.etherscan.io/tx/",
  11155420: "https://sepolia-optimism.etherscan.io/tx/",
  56: "https://bscscan.com/tx/",
  43114: "https://snowtrace.io/tx/",
};

export function blockExplorerTxUrl(
  chainId: number,
  txHash: `0x${string}`,
): string {
  const base = TX_BASE_BY_CHAIN[chainId] ?? TX_BASE_BY_CHAIN[1]!;
  return `${base}${txHash}`;
}
