import assert from 'assert';
import { getMultiSendDeployment } from '@safe-global/safe-deployments';
import { AbiItem, createPublicClient, createWalletClient, encodeFunctionData, erc20Abi, http } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { mainnet } from 'viem/chains';
import { AUTO_EARN_ABI, AUTO_EARN_MODULE_ADDRESS } from '../_utils/addresses-and-abis';
import { dynamo } from '../_utils/dynamo-client';
import { encodeMultisend } from '../_utils/multicall-encoder';
import { initPredictedSafe } from '../_utils/safe-init';
import { getParam } from '../_utils/ssm-params';
import { ExecuteAutoEarnRequest } from './types';

export async function handler(event: ExecuteAutoEarnRequest) {
  const { safeAddress, tokenAddress } = event;

  // 1. Read the stealth safe record from DynamoDB via GSI
  const queryResult = await dynamo.query({
    TableName: 'xstocks-user-address',
    IndexName: 'address-index',
    KeyConditionExpression: 'address = :address',
    ExpressionAttributeValues: {
      ':address': safeAddress.toLowerCase(),
    },
  });

  const record = queryResult.Items?.[0];
  if (!record) throw new Error(`No stealth safe found at ${safeAddress}`);

  // 2. Read secrets from SSM
  const [relayerPrivateKey, alchemyApiKey] = await Promise.all([
    getParam('/xstocks/relayer'),
    getParam('/xstocks/alchemy-api-key'),
  ]);
  const relayerAccount = privateKeyToAccount(relayerPrivateKey as `0x${string}`);
  const providerUrl = `https://eth-mainnet.g.alchemy.com/v2/${alchemyApiKey}`;

  const transport = http(providerUrl);
  const publicClient = createPublicClient({ chain: mainnet, transport });
  const walletClient = createWalletClient({ chain: mainnet, transport, account: relayerAccount });
  /*
  // 3. Check the token balance on the stealth safe
  const balance = await publicClient.readContract({
    abi: erc20Abi,
    address: tokenAddress as `0x${string}`,
    functionName: 'balanceOf',
    args: [safeAddress as `0x${string}`],
  });

  if (balance === BigInt(0)) {
    console.log('Balance is 0, nothing to do');
    return { status: 'NO_BALANCE' };
  }

  console.log(`Token balance: ${balance.toString()}`);
  */
  // 4. Build the list of txs to batch
  const txs: Array<{ to: `0x${string}`; data: `0x${string}`; value: bigint }> = [];
  // 4a. If safe is not deployed yet, add the deployment tx
  const needsDeploy = record.deploymentStatus !== 'DEPLOYED';
  if (needsDeploy) {
    const protocolKit = await initPredictedSafe({
      providerUrl,
      signerPrivateKey: relayerPrivateKey,
      ownerAddress: relayerAccount.address,
      initializerExtraTo: record.initializerExtraTo,
      initializerExtraData: record.initializerExtraData,
      saltNonce: record.saltNonce,
    });

    const deploymentTx = await protocolKit.createSafeDeploymentTransaction();
    txs.push({
      to: deploymentTx.to as `0x${string}`,
      data: deploymentTx.data as `0x${string}`,
      value: BigInt(deploymentTx.value),
    });
  }
  console.log(txs);
  // 4b. Add the autoDeposit call
  // TODO: underlyingVault, feePercentage, nonce, signature, merkleProof need to be provided
  /*
  const autoDepositCalldata = encodeFunctionData({
    abi: AUTO_EARN_ABI,
    functionName: 'autoDeposit',
    args: [
      tokenAddress as `0x${string}`, // token
      balance, // amount
      '0x0000000000000000000000000000000000000000' as `0x${string}`, // TODO: underlyingVault
      BigInt(0), // TODO: feePercentage
      safeAddress as `0x${string}`, // safe
      BigInt(0), // TODO: nonce
      '0x' as `0x${string}`, // TODO: signature
      [], // TODO: merkleProof
    ],
  });

  txs.push({
    to: AUTO_EARN_MODULE_ADDRESS,
    data: autoDepositCalldata,
    value: BigInt(0),
  });
  */
  // 5. If multiple txs, batch via MultiSend; otherwise send directly
  let txTo: `0x${string}`;
  let txData: `0x${string}`;
  let txValue: bigint;

  if (txs.length > 1) {
    const multisendDeployment = getMultiSendDeployment({
      network: '1',
      version: '1.3.0',
      released: true,
    });
    assert(!!multisendDeployment, 'Missing multisend for chain 1');

    const encoded = encodeMultisend(
      txs.map((tx) => ({
        operation: 0,
        to: tx.to,
        value: tx.value,
        data: tx.data,
      })),
    );

    txTo = multisendDeployment.defaultAddress as `0x${string}`;
    txData = encodeFunctionData({
      abi: multisendDeployment.abi as AbiItem[],
      functionName: 'multiSend',
      args: [encoded],
    });
    txValue = BigInt(0);
  } else {
    txTo = txs[0].to;
    txData = txs[0].data;
    txValue = txs[0].value;
  }

  // 6. Send the transaction on-chain
  const feesPerGas = await publicClient.estimateFeesPerGas();

  const gas = await publicClient.estimateGas({
    account: relayerAccount,
    to: txTo,
    value: txValue,
    data: txData,
    type: 'eip1559',
    maxPriorityFeePerGas: feesPerGas.maxPriorityFeePerGas,
  });

  const gasIncreaseMultiplier = BigInt(4);
  const request = await walletClient.prepareTransactionRequest({
    chain: mainnet,
    account: relayerAccount,
    to: txTo,
    value: txValue,
    data: txData,
    type: 'eip1559',
    maxFeePerGas: feesPerGas.maxFeePerGas! * gasIncreaseMultiplier,
    maxPriorityFeePerGas: feesPerGas.maxPriorityFeePerGas,
    gas: gas * BigInt(12) / BigInt(10),
  });

  const signature = await walletClient.signTransaction(request);
  const txHash = await walletClient.sendRawTransaction({ serializedTransaction: signature });
  console.log('Tx hash:', txHash);

  // 7. Update deployment status if we deployed
  if (needsDeploy) {
    await dynamo.update({
      TableName: 'xstocks-user-address',
      Key: { idUser: record.idUser, address: safeAddress.toLowerCase() },
      UpdateExpression: 'SET deploymentStatus = :status, deployHash = :hash',
      ExpressionAttributeValues: {
        ':status': 'DEPLOYED',
        ':hash': txHash,
      },
    });
  }

  return {
    safeAddress,
    txHash,
    deployed: needsDeploy,
    status: 'EXECUTED',
  };
}
