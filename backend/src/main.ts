import { App, aws_logs, CfnOutput, RemovalPolicy, Stack, StackProps } from 'aws-cdk-lib';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';
import { AlchemySetupVariablesFunction } from './lambda-functions/alchemy-setup-variables/alchemy-setup-variables-function';
import { AlchemyWebhookListenerFunction } from './lambda-functions/alchemy-webhook-listener/alchemy-webhook-listener-function';

export class XStocksBackendStack extends Stack {
  constructor(scope: Construct, id: string, props: StackProps = {}) {
    super(scope, id, props);

    const alchemySigningKeys = ssm.StringParameter.fromStringParameterName(
      this, 'AlchemySigningKeys', '/xstocks/alchemy-signing-keys',
    );

    const alchemyWebhookListener = new AlchemyWebhookListenerFunction(this, 'AlchemyWebhookListener', {
      environment: {
        ALCHEMY_SIGNING_KEYS_PARAM: alchemySigningKeys.parameterName,
      },
      logGroup: new aws_logs.LogGroup(
        this,
        'AlchemyWebhookListenerLogGroup',
        {
          removalPolicy: RemovalPolicy.DESTROY,
          retention: aws_logs.RetentionDays.ONE_WEEK,
        },
      ),
    });

    alchemySigningKeys.grantRead(alchemyWebhookListener);

    const fnUrl = alchemyWebhookListener.addFunctionUrl({
      authType: lambda.FunctionUrlAuthType.NONE,
    });

    new CfnOutput(this, 'AlchemyWebhookUrl', {
      value: fnUrl.url,
      description: 'Alchemy webhook listener URL',
    });

    // --- Alchemy Setup Variables Lambda ---
    const alchemyAuthToken = ssm.StringParameter.fromStringParameterName(
      this, 'AlchemyAuthToken', '/xstocks/alchemy-auth-token',
    );

    const alchemySetupVariables = new AlchemySetupVariablesFunction(this, 'AlchemySetupVariables', {
      environment: {
        ALCHEMY_AUTH_TOKEN_PARAM: alchemyAuthToken.parameterName,
      },
      logGroup: new aws_logs.LogGroup(
        this,
        'AlchemySetupVariablesLogGroup',
        {
          removalPolicy: RemovalPolicy.DESTROY,
          retention: aws_logs.RetentionDays.ONE_WEEK,
        },
      ),
    });

    alchemyAuthToken.grantRead(alchemySetupVariables);
  }
}

const app = new App();

new XStocksBackendStack(app, 'xStocks2026');

app.synth();