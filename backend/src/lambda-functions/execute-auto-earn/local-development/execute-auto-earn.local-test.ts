import path from 'node:path';
import * as lambdaLocal from 'lambda-local';

const jsonPayload = {
  safeAddress: '0x71C91D742d910f6c34a5A2C9567804C3491D438A',
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
});
