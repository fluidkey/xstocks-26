import { App, Stack, StackProps } from 'aws-cdk-lib';
import { Construct } from 'constructs';

export class XStocksBackendStack extends Stack {
  constructor(scope: Construct, id: string, props: StackProps = {}) {
    super(scope, id, props);

    // define resources here...
  }
}

const app = new App();

new XStocksBackendStack(app, 'xStocks2026');

app.synth();