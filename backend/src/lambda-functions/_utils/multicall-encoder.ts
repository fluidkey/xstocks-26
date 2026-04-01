import { concat, pad, toHex } from 'viem';

/** Single transaction in a MultiSend batch */
interface MultisendTx {
  /** 0 = CALL, 1 = DELEGATECALL */
  operation: number;
  to: `0x${string}`;
  value: bigint;
  data: `0x${string}`;
}

/**
 * Encodes an array of transactions into the packed format expected by MultiSend.
 * Each tx is: operation (1 byte) + to (20 bytes) + value (32 bytes) + dataLength (32 bytes) + data
 */
export function encodeMultisend(txs: MultisendTx[]): `0x${string}` {
  const encoded = txs.map((tx) => {
    const dataBytes = tx.data === '0x' ? '0x' as `0x${string}` : tx.data;
    const dataLength = (dataBytes.length - 2) / 2;

    return concat([
      toHex(tx.operation, { size: 1 }),
      tx.to,
      pad(toHex(tx.value), { size: 32 }),
      pad(toHex(dataLength), { size: 32 }),
      dataBytes,
    ]);
  });

  return concat(encoded);
}
