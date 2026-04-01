import path from 'node:path';
import * as lambdaLocal from 'lambda-local';

void lambdaLocal.execute({
  event: {},
  lambdaPath: path.join(__dirname, '../fetch-prices.lambda.ts'),
  profilePath: '~/.aws/credentials',
  profileName: 'fluidkey',
  region: 'eu-west-1',
  timeoutMs: 60000,
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
