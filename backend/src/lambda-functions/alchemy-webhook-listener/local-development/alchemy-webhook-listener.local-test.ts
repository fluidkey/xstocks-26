import path from 'node:path';
import * as lambdaLocal from 'lambda-local';

const jsonPayload = {
  headers: {
    'x-alchemy-signature': 'test-signature',
  },
  body: JSON.stringify({
    webhookId: 'wh_v52d1albqg7aw33n',
    id: 'whevt_e3nagi5za9axh147',
    createdAt: '2026-03-31T13:56:41.206Z',
    type: 'GRAPHQL',
    event: {
      data: {
        block: {
          hash: '0x2d69dd9255bd13035f94177453c459ce22ba0106ef09d28c2fe3e4c93c42a40d',
          number: 24778030,
          timestamp: 1774965395,
          transactions: [],
          callTracerTraces: [],
          logs: [
            {
              topics: [
                '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef',
                '0x0000000000000000000000006faec2944071b2a5ebfd1b08f43f29597aad8ca1',
                '0x00000000000000000000000092a494bd2bbf727eef5703f3e197d0b4df99e96a',
              ],
              data: '0x00000000000000000000000000000000000000000000000000000000000bc812',
              account: {
                address: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
              },
              transaction: {
                hash: '0x98196e3cd1d828013547f0c4851d9ca8f7e38cfd2a8aa002bda8dc0a3b349389',
                from: { address: '0x090fc3ead2e5e81d3c0fa2e45636ef003bab9dfb' },
                to: { address: '0xae68b7117be0026cbd4366303f74eecbb19e4042' },
                value: '0x0',
                status: 1,
              },
            },
          ],
        },
      },
      sequenceNumber: '10000000374324955003',
      network: 'ETH_MAINNET',
    },
  }),
  isBase64Encoded: false,
};

void lambdaLocal.execute({
  event: jsonPayload,
  lambdaPath: path.join(__dirname, '../alchemy-webhook-listener.lambda.ts'),
  profilePath: '~/.aws/credentials',
  profileName: 'fluidkey',
  region: 'eu-west-1',
  timeoutMs: 30000,
  callback: function (err: any, data: any) {
    if (err) {
      console.log(err);
    } else {
      console.log(data);
    }
  },
  environment: {
    ALCHEMY_SIGNING_KEYS_PARAM: '/xstocks/alchemy-signing-keys',
    SKIP_SIGNATURE_VERIFICATION: 'true',
  },
});
