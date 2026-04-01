import assert from 'assert';
import { getMultiSendDeployment } from '@safe-global/safe-deployments';
import { AbiItem, encodeFunctionData } from 'viem';
import {
  AUTO_EARN_ABI,
  AUTO_EARN_CONFIG_HASH,
  AUTO_EARN_MODULE_ADDRESS,
  SAFE_MODULE_DEPLOYER_ABI,
  SAFE_MODULE_DEPLOYER_ADDR,
} from './addresses-and-abis';
import { encodeMultisend } from './multicall-encoder';

/**
 * Returns the initializer extra fields to enable the AutoEarn module during safe deployment.
 */
export const getInitializerExtraFields = (): { to: `0x${string}`; data: `0x${string}` } => {
  const encodedTxs = encodeMultisend([
    {
      operation: 1, // DELEGATE_CALL
      to: SAFE_MODULE_DEPLOYER_ADDR,
      value: BigInt(0),
      data: encodeFunctionData({
        abi: SAFE_MODULE_DEPLOYER_ABI,
        functionName: 'enableModules',
        args: [[AUTO_EARN_MODULE_ADDRESS]],
      }),
    },
    {
      operation: 0, // CALL
      to: AUTO_EARN_MODULE_ADDRESS,
      value: BigInt(0),
      data: encodeFunctionData({
        abi: AUTO_EARN_ABI,
        functionName: 'onInstall',
        args: [AUTO_EARN_CONFIG_HASH],
      }),
    },
  ]);

  const multisendDeployment = getMultiSendDeployment({
    network: '1',
    version: '1.3.0',
    released: true,
  });
  assert(!!multisendDeployment, 'Missing multisend for given chain');

  return {
    to: multisendDeployment.defaultAddress.toLowerCase() as `0x${string}`,
    data: encodeFunctionData({
      abi: multisendDeployment.abi as AbiItem[],
      functionName: 'multiSend',
      args: [encodedTxs],
    }),
  };
};
