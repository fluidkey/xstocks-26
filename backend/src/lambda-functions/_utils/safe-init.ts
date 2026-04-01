import Safe from '@safe-global/protocol-kit';
import { InitPredictedSafeParams } from './safe-init-types';

/**
 * Initializes the Safe protocol kit with a predicted (counterfactual) safe.
 * Used both at address-prediction time and at deployment time so the
 * config stays consistent across lambdas.
 */
export async function initPredictedSafe(params: InitPredictedSafeParams): Promise<Safe> {
  return Safe.init({
    provider: params.providerUrl,
    signer: params.signerPrivateKey,
    predictedSafe: {
      safeAccountConfig: {
        owners: [params.ownerAddress],
        threshold: 1,
        to: params.initializerExtraTo,
        data: params.initializerExtraData,
      },
      safeDeploymentConfig: {
        saltNonce: params.saltNonce,
        safeVersion: '1.3.0',
      },
    },
  });
}
