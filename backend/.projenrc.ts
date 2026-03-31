import { awscdk, javascript } from 'projen';

const project = new awscdk.AwsCdkTypeScriptApp({
  cdkVersion: '2.189.1',
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
});

// Fix file permissions after projen synth (so GitKraken can merge without permission errors)
project.defaultTask?.exec(
  'chmod -R u+w .projen/ cdk.json .eslintrc.json .gitattributes .gitignore LICENSE .npmignore tsconfig.dev.json tsconfig.json .yarnrc.yml || true',
);

project.synth();
