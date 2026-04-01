import path from 'node:path';
import * as lambdaLocal from 'lambda-local';

const jsonPayload = {
  safeAddress: '0xD8a87F9DbEe4306ED253b0C9d82BD4aFdc34ff18',
  tokenAddress: '0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a',
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
