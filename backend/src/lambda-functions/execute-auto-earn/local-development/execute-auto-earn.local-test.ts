import * as lambdaLocal from 'lambda-local';
import path from 'node:path';

// Simulate an SQS event wrapping the payload
const jsonPayload = {
  Records: [
    {
      body: JSON.stringify({
        safeAddress: '0xd9cfd18332d278205965dc95f33da47daecc8338',
        tokenAddress: '0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a',
      }),
      messageId: 'local-test-1',
      receiptHandle: 'local-test',
      attributes: {
        ApproximateReceiveCount: '1',
        SentTimestamp: Date.now().toString(),
        SenderId: 'local',
        ApproximateFirstReceiveTimestamp: Date.now().toString(),
      },
      messageAttributes: {},
      md5OfBody: '',
      eventSource: 'aws:sqs',
      eventSourceARN: 'arn:aws:sqs:eu-west-1:000000000000:xstocks-tx-relay.fifo',
      awsRegion: 'eu-west-1',
    },
  ],
};

void lambdaLocal.execute({
  event: jsonPayload,
  lambdaPath: path.join(__dirname, '../execute-auto-earn.lambda.ts'),
  profilePath: '~/.aws/credentials',
  profileName: 'fluidkey',
  region: 'eu-west-1',
  timeoutMs: 300000,
  callback: function (err: any, data: any) {
    if (err) {
      console.log(err);
    } else {
      console.log(data);
    }
  },
  environment: {
    PRICES_BUCKET: 'xstocks2026-pricesbucket7bd6c8de-20gavwamlmay',
  },
});
