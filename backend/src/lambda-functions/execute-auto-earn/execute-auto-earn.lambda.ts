import assert from 'assert';
import { getMultiSendCallOnlyDeployment } from '@safe-global/safe-deployments';
import { AbiItem, createPublicClient, createWalletClient, encodeAbiParameters, encodeFunctionData, erc20Abi, http, keccak256 } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { mainnet } from 'viem/chains';
import { AUTO_EARN_ABI, AUTO_EARN_MODULE_ADDRESS } from '../_utils/addresses-and-abis';
import { dynamo } from '../_utils/dynamo-client';
import { findVaultProof, loadMerkleTree } from '../_utils/merkle-tree-reader';
import { encodeMultisend } from '../_utils/multicall-encoder';
import { initPredictedSafe } from '../_utils/safe-init';
import { getParam } from '../_utils/ssm-params';
import { TOKEN_TO_VAULT } from '../_utils/vault-config';
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

  // 2. Read secrets from SSM (tx relayer sends the tx, module relayer signs the autoDeposit authorization)
  const [relayerPrivateKey, alchemyApiKey, moduleRelayerPrivateKey] = await Promise.all([
    getParam('/xstocks/relayer'),
    getParam('/xstocks/alchemy-api-key'),
    getParam('/xstocks/module-authorized-relayer'),
  ]);
  const relayerAccount = privateKeyToAccount(relayerPrivateKey as `0x${string}`);
  const providerUrl = `https://eth-mainnet.g.alchemy.com/v2/${alchemyApiKey}`;

  const transport = http(providerUrl);
  const publicClient = createPublicClient({ chain: mainnet, transport });
  const walletClient = createWalletClient({ chain: mainnet, transport, account: relayerAccount });
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
  // 4b. Look up which vault this token maps to
  const vaultMapping = TOKEN_TO_VAULT.find(
    (m) => m.tokenAddress.toLowerCase() === tokenAddress.toLowerCase(),
  );
  if (!vaultMapping) {
    console.log(`No vault mapping for token ${tokenAddress}, skipping`);
    return { status: 'NO_VAULT_MAPPING' };
  }

  // 4c. Load merkle tree from S3 and find the proof for this vault
  const merkleTree = await loadMerkleTree();
  const proofEntry = findVaultProof(merkleTree, vaultMapping.chainId, vaultMapping.vaultAddress, vaultMapping.feePercentage);
  if (!proofEntry) {
    throw new Error(`No merkle proof found for vault ${vaultMapping.vaultAddress} on chain ${vaultMapping.chainId} with fee ${vaultMapping.feePercentage}`);
  }

  // 4d. Build the authorized relayer signature for the autoDeposit call
  const moduleRelayerAccount = privateKeyToAccount(moduleRelayerPrivateKey as `0x${string}`);

  // Random nonce for replay protection — matches the contract's executedHashes tracking
  const nonce = BigInt('0x' + crypto.randomUUID().replace(/-/g, ''));

  // Replicate the contract's _buildDepositMessageHash:
  // keccak256(abi.encode("deposit", chainId, token, amount, underlyingVault, feePercentage, feeCollector, safe, nonce))
  const messageHash = keccak256(
    encodeAbiParameters(
      [
        { type: 'string' },
        { type: 'uint256' },
        { type: 'address' },
        { type: 'uint256' },
        { type: 'address' },
        { type: 'uint256' },
        { type: 'address' },
        { type: 'address' },
        { type: 'uint256' },
      ],
      [
        'deposit',
        BigInt(1), // chainId — mainnet
        tokenAddress as `0x${string}`,
        balance,
        proofEntry.underlyingVault as `0x${string}`,
        BigInt(proofEntry.feePercentage),
        proofEntry.feeCollector as `0x${string}`,
        safeAddress as `0x${string}`,
        nonce,
      ],
    ),
  );

  // EIP-191 personal sign — the contract uses toEthSignedMessageHash + ECDSA.recover
  const moduleSignature = await moduleRelayerAccount.signMessage({ message: { raw: messageHash } });

  // 4e. Encode the autoDeposit call with the signed authorization
  const autoDepositCalldata = encodeFunctionData({
    abi: AUTO_EARN_ABI,
    functionName: 'autoDeposit',
    args: [
      tokenAddress as `0x${string}`,
      balance,
      {
        underlyingVault: proofEntry.underlyingVault as `0x${string}`,
        feePercentage: BigInt(proofEntry.feePercentage),
        feeCollector: proofEntry.feeCollector as `0x${string}`,
      },
      safeAddress as `0x${string}`,
      nonce,
      moduleSignature,
      proofEntry.proof as `0x${string}`[],
    ],
  });

  txs.push({
    to: AUTO_EARN_MODULE_ADDRESS,
    data: autoDepositCalldata,
    value: BigInt(0),
  });
  // 5. If multiple txs, batch via MultiSend; otherwise send directly
  let txTo: `0x${string}`;
  let txData: `0x${string}`;
  let txValue: bigint;

  if (txs.length > 1) {
    const multisendDeployment = getMultiSendCallOnlyDeployment({
      network: '1',
      version: '1.3.0',
      released: true,
    });
    assert(!!multisendDeployment, 'Missing MultiSendCallOnly for chain 1');

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
