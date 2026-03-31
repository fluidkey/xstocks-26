import { awscdk, javascript } from 'projen';
import { LambdaRuntime } from 'projen/lib/awscdk';

const project = new awscdk.AwsCdkTypeScriptApp({
  cdkVersion: '2.208.0',
  defaultReleaseBranch: 'main',
  github: false,
  name: 'xStocks2026',
  packageManager: javascript.NodePackageManager.YARN_BERRY,
  projenrcTs: true,
  yarnBerryOptions: {
    version: '4.9.1',
    yarnRcOptions: {
      nodeLinker: javascript.YarnNodeLinker.NODE_MODULES,
      supportedArchitectures: {
        cpu: ['x64', 'arm64'],
        os: ['linux', 'darwin'],
        libc: ['glibc', 'musl'],
      },
    },
  },
  eslint: true,
  deps: [
    '@aws-sdk/client-ssm@3.1020.0',
    '@aws-sdk/client-s3@3.1020.0',
    '@aws-sdk/client-dynamodb@3.1020.0',
    '@aws-sdk/lib-dynamodb@3.1020.0',
    'lambda-local',
    'viem',
  ],
  devDeps: [
  ],
  lambdaOptions: {
    runtime: LambdaRuntime.NODEJS_22_X,
  },
  tsconfig: {
    compilerOptions: {
      types: ['node'],
    },
  },
  tsconfigDev: {
    compilerOptions: {
      types: ['node'],
    },
  },
});

// Fix file permissions after projen synth (so GitKraken can merge without permission errors)
project.defaultTask?.exec(
  'chmod -R u+w .projen/ cdk.json .eslintrc.json .gitattributes .gitignore LICENSE .npmignore tsconfig.dev.json tsconfig.json .yarnrc.yml || true',
);

// Local test task for alchemy-webhook-listener
project.addTask('test:alchemyWebhookListener', {
  exec: 'npx ts-node src/lambda-functions/alchemy-webhook-listener/local-development/alchemy-webhook-listener.local-test.ts',
});

project.synth();
