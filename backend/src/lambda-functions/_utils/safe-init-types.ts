/**
 * Parameters needed to initialize a predicted (counterfactual) Safe via the protocol kit.
 * Used both at address-prediction time and at deployment time.
 */
export interface InitPredictedSafeParams {
  /** Alchemy (or other) JSON-RPC URL */
  providerUrl: string;
  /** Hex-encoded relayer private key */
  signerPrivateKey: string;
  /** Relayer address (owner of the safe) */
  ownerAddress: string;
  /** Target address for the initializer delegatecall (multisend) */
  initializerExtraTo: `0x${string}`;
  /** Calldata for the initializer delegatecall */
  initializerExtraData: `0x${string}`;
  /** Salt nonce used for CREATE2 address derivation */
  saltNonce: string;
}
