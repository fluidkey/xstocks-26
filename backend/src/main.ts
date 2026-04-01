import { App, aws_apigateway, aws_dynamodb, aws_events, aws_events_targets, aws_iam, aws_logs, aws_s3, CfnOutput, Duration, RemovalPolicy, Stack, StackProps } from 'aws-cdk-lib';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';
import { AlchemyWebhookListenerFunction } from './lambda-functions/alchemy-webhook-listener/alchemy-webhook-listener-function';
import { CreateStealthSafeFunction } from './lambda-functions/create-stealth-safe/create-stealth-safe-function';
import { ExecuteAutoEarnFunction } from './lambda-functions/execute-auto-earn/execute-auto-earn-function';
import { FetchPricesFunction } from './lambda-functions/fetch-prices/fetch-prices-function';
import { GetAddressTransactionsFunction } from './lambda-functions/get-address-transactions/get-address-transactions-function';
import { GetUserAddressesFunction } from './lambda-functions/get-user-addresses/get-user-addresses-function';

export class XStocksBackendStack extends Stack {
  constructor(scope: Construct, id: string, props: StackProps = {}) {
    super(scope, id, props);

    // --- DynamoDB Tables ---
    const userAddressTable = new aws_dynamodb.Table(this, 'UserAddressTable', {
      tableName: 'xstocks-user-address',
      partitionKey: { name: 'idUser', type: aws_dynamodb.AttributeType.STRING },
      sortKey: { name: 'address', type: aws_dynamodb.AttributeType.STRING },
      billingMode: aws_dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: RemovalPolicy.DESTROY,
    });

    userAddressTable.addGlobalSecondaryIndex({
      indexName: 'address-index',
      partitionKey: { name: 'address', type: aws_dynamodb.AttributeType.STRING },
    });

    const addressTransactionTable = new aws_dynamodb.Table(this, 'AddressTransactionTable', {
      tableName: 'xstocks-address-transaction',
      partitionKey: { name: 'address', type: aws_dynamodb.AttributeType.STRING },
      sortKey: { name: 'sk', type: aws_dynamodb.AttributeType.STRING },
      billingMode: aws_dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: RemovalPolicy.DESTROY,
    });

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
    addressTransactionTable.grantWriteData(alchemyWebhookListener);
    userAddressTable.grantReadData(alchemyWebhookListener);

    const fnUrl = alchemyWebhookListener.addFunctionUrl({
      authType: lambda.FunctionUrlAuthType.NONE,
    });

    new CfnOutput(this, 'AlchemyWebhookUrl', {
      value: fnUrl.url,
      description: 'Alchemy webhook listener URL',
    });

    // --- Fetch Prices Lambda (every 10 minutes) ---
    const pricesBucket = new aws_s3.Bucket(this, 'PricesBucket', {
      removalPolicy: RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
      publicReadAccess: true,
      blockPublicAccess: aws_s3.BlockPublicAccess.BLOCK_ACLS,
      cors: [{
        allowedMethods: [aws_s3.HttpMethods.GET],
        allowedOrigins: ['*'],
        allowedHeaders: ['*'],
      }],
    });

    const fetchPrices = new FetchPricesFunction(this, 'FetchPrices', {
      timeout: Duration.seconds(30),
      environment: {
        PRICES_BUCKET: pricesBucket.bucketName,
      },
      logGroup: new aws_logs.LogGroup(this, 'FetchPricesLogGroup', {
        removalPolicy: RemovalPolicy.DESTROY,
        retention: aws_logs.RetentionDays.ONE_WEEK,
      }),
    });

    pricesBucket.grantPut(fetchPrices);

    new aws_events.Rule(this, 'FetchPricesSchedule', {
      schedule: aws_events.Schedule.rate(Duration.minutes(10)),
      targets: [new aws_events_targets.LambdaFunction(fetchPrices)],
    });

    new CfnOutput(this, 'PricesFileUrl', {
      value: `https://${pricesBucket.bucketDomainName}/prices.json`,
      description: 'Public URL for prices.json',
    });

    // --- Get User Addresses Lambda ---
    const getUserAddresses = new GetUserAddressesFunction(this, 'GetUserAddresses', {
      logGroup: new aws_logs.LogGroup(this, 'GetUserAddressesLogGroup', {
        removalPolicy: RemovalPolicy.DESTROY,
        retention: aws_logs.RetentionDays.ONE_WEEK,
      }),
    });
    userAddressTable.grantReadData(getUserAddresses);

    // --- Get Address Transactions Lambda ---
    const getAddressTransactions = new GetAddressTransactionsFunction(this, 'GetAddressTransactions', {
      logGroup: new aws_logs.LogGroup(this, 'GetAddressTransactionsLogGroup', {
        removalPolicy: RemovalPolicy.DESTROY,
        retention: aws_logs.RetentionDays.ONE_WEEK,
      }),
    });
    addressTransactionTable.grantReadData(getAddressTransactions);

    // --- Create Stealth Safe Lambda ---
    const createStealthSafe = new CreateStealthSafeFunction(this, 'CreateStealthSafe', {
      timeout: Duration.minutes(5),
      memorySize: 512,
      logGroup: new aws_logs.LogGroup(this, 'CreateStealthSafeLogGroup', {
        removalPolicy: RemovalPolicy.DESTROY,
        retention: aws_logs.RetentionDays.ONE_WEEK,
      }),
    });

    userAddressTable.grantWriteData(createStealthSafe);

    createStealthSafe.addToRolePolicy(new aws_iam.PolicyStatement({
      actions: ['ssm:GetParameter'],
      resources: [
        `arn:aws:ssm:${this.region}:${this.account}:parameter/xstocks/relayer`,
        `arn:aws:ssm:${this.region}:${this.account}:parameter/xstocks/alchemy-api-key`,
        `arn:aws:ssm:${this.region}:${this.account}:parameter/xstocks/alchemy-auth-token`,
      ],
    }));

    // --- API Gateway ---
    const api = new aws_apigateway.RestApi(this, 'XStocksApi', {
      restApiName: 'xStocks API',
      endpointConfiguration: {
        types: [aws_apigateway.EndpointType.EDGE],
      },
      deployOptions: {
        stageName: 'v1',
      },
    });

    const addressResource = api.root.addResource('address');
    addressResource.addCorsPreflight({
      allowOrigins: aws_apigateway.Cors.ALL_ORIGINS,
      allowMethods: ['POST', 'OPTIONS'],
      allowHeaders: ['Content-Type'],
    });
    addressResource.addMethod('POST', new aws_apigateway.LambdaIntegration(createStealthSafe));

    // GET /user/{id_user}/address
    const userResource = api.root.addResource('user');
    const userIdResource = userResource.addResource('{id_user}');
    const userAddressResource = userIdResource.addResource('address');
    userAddressResource.addCorsPreflight({
      allowOrigins: aws_apigateway.Cors.ALL_ORIGINS,
      allowMethods: ['GET', 'OPTIONS'],
      allowHeaders: ['Content-Type'],
    });
    userAddressResource.addMethod('GET', new aws_apigateway.LambdaIntegration(getUserAddresses));

    // GET /address/{address}/transaction
    const addressByIdResource = addressResource.addResource('{address}');
    const transactionResource = addressByIdResource.addResource('transaction');
    transactionResource.addCorsPreflight({
      allowOrigins: aws_apigateway.Cors.ALL_ORIGINS,
      allowMethods: ['GET', 'OPTIONS'],
      allowHeaders: ['Content-Type'],
    });
    transactionResource.addMethod('GET', new aws_apigateway.LambdaIntegration(getAddressTransactions));

    new CfnOutput(this, 'ApiUrl', {
      value: api.url,
      description: 'xStocks API URL',
    });

    // --- Execute Auto Earn Lambda (async invocation) ---
    const executeAutoEarn = new ExecuteAutoEarnFunction(this, 'ExecuteAutoEarn', {
      functionName: 'xstocks-execute-auto-earn',
      timeout: Duration.minutes(5),
      memorySize: 512,
      logGroup: new aws_logs.LogGroup(this, 'ExecuteAutoEarnLogGroup', {
        removalPolicy: RemovalPolicy.DESTROY,
        retention: aws_logs.RetentionDays.ONE_WEEK,
      }),
    });

    userAddressTable.grantReadWriteData(executeAutoEarn);

    executeAutoEarn.addToRolePolicy(new aws_iam.PolicyStatement({
      actions: ['ssm:GetParameter'],
      resources: [
        `arn:aws:ssm:${this.region}:${this.account}:parameter/xstocks/relayer`,
        `arn:aws:ssm:${this.region}:${this.account}:parameter/xstocks/alchemy-api-key`,
      ],
    }));

    // Allow webhook listener to invoke execute-auto-earn async
    executeAutoEarn.grantInvoke(alchemyWebhookListener);
  }
}

const app = new App();

new XStocksBackendStack(app, 'xStocks2026');

app.synth();