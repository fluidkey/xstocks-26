import path from 'node:path';
import * as lambdaLocal from 'lambda-local';

const jsonPayload = {
  body: JSON.stringify({
    idUser: 'own', // either 'own' or 'earn'
    ownerAddress: '0xE1934217f1adf611420576af84438e8F865078dd',
  }),
  isBase64Encoded: false,
};

void lambdaLocal.execute({
  event: jsonPayload,
  lambdaPath: path.join(__dirname, '../create-stealth-safe.lambda.ts'),
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
});
