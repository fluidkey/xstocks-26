# xStocks2026

Backend for xStocks — tracks wallet activity and token prices on Ethereum.

Users register wallet addresses through the API. Alchemy Custom Webhooks push on-chain events (native transfers, internal calls, ERC-20 transfers) to a Lambda that writes them to DynamoDB. A scheduled Lambda fetches token prices every 10 minutes and stores them in a public S3 bucket. The frontend reads prices from S3 and queries the REST API for user addresses and transaction history.

## Resources

| Resource | Purpose |
|---|---|
| **API Gateway** (`/v1`) | REST API for the frontend |
| **DynamoDB** `xstocks-user-address` | Maps users to their tracked wallet addresses |
| **DynamoDB** `xstocks-address-transaction` | Stores transactions detected by the webhook listener |
| **S3 Bucket** (public read) | Serves `prices.json` with current token prices |
| **Lambda** `AlchemyWebhookListener` | Receives Alchemy webhook events, writes transactions to DynamoDB |
| **Lambda** `AddAddress` | Registers a new address for a user (DynamoDB + Alchemy webhook variables) |
| **Lambda** `GetUserAddresses` | Returns all addresses registered by a user |
| **Lambda** `GetAddressTransactions` | Returns transaction history for an address |
| **Lambda** `FetchPrices` | Scheduled every 10 min — fetches token prices and writes to S3 |
| **SSM Parameters** | Stores Alchemy auth token and webhook signing keys |

## API endpoints

| Method | Path | Description |
|---|---|---|
| `POST` | `/address` | Register a new tracked address |
| `GET` | `/user/{id_user}/address` | List addresses for a user |
| `GET` | `/address/{address}/transaction` | List transactions for an address |

Full API spec in [`swagger.yaml`](./swagger.yaml).

## Architecture

```
                  ┌─────────────────┐
                  │  Alchemy Webhooks│
                  └────────┬────────┘
                           │
                           ▼
                ┌──────────────────────┐
                │ AlchemyWebhookListener│──▶ DynamoDB (transactions)
                └──────────────────────┘

  ┌──────────────┐         ┌─────────────────┐
  │  API Gateway │────────▶│  Lambda handlers │──▶ DynamoDB
  └──────────────┘         └─────────────────┘

  ┌───────────────────┐
  │ EventBridge (10m) │──▶ FetchPrices ──▶ S3 (prices.json)
  └───────────────────┘

  Frontend ──▶ S3 (prices.json)
  Frontend ──▶ API Gateway (addresses, transactions)
```

## Project structure

```
src/
├── main.ts                                    # CDK stack
└── lambda-functions/
    ├── add-address/                           # POST /address
    ├── alchemy-webhook-listener/              # Webhook receiver
    │   ├── alchemy-webhook-listener.lambda.ts
    │   ├── types.ts                           # Alchemy event interfaces
    │   └── local-development/                 # Local test harness
    ├── fetch-prices/                          # Scheduled price fetcher
    ├── get-user-addresses/                    # GET /user/{id_user}/address
    └── get-address-transactions/              # GET /address/{address}/transaction
```

## Setup

```bash
yarn install
npx projen bundle
npx projen deploy
```

See the Alchemy webhook setup section below for configuring the on-chain event pipeline.

## SSM parameters

```bash
aws ssm put-parameter --name /xstocks/alchemy-auth-token --value "YOUR_TOKEN" --type String
aws ssm put-parameter --name /xstocks/alchemy-signing-keys --value "key1,key2" --type String
```

## Alchemy webhook configuration

Two webhooks are needed because Alchemy's log topic filters use AND logic across positions — you can't match "from OR to" in a single query.

- **Webhook 1**: Native transfers (external + internal) + ERC-20 receives (`topics[2]`)
- **Webhook 2**: ERC-20 sends (`topics[1]`)

Both point to the `AlchemyWebhookUrl` output from the deploy. After creating them, update the signing keys SSM parameter with both webhook signing keys (comma-separated).

### Webhook 1 — Receives + Native transfers

```graphql
query (
  $trackedAddresses: [Address!],
  $trackedAddressesPadded: [Bytes32!]!
) {
  block {
    hash
    number
    timestamp

    transactions(filter: {
      addresses: [
        {to: $trackedAddresses},
        {from: $trackedAddresses}
      ]
    }) {
      hash
      from { address }
      to { address }
      value
      gas
      status
    }

    callTracerTraces(filter: {
      addresses: [
        {from: $trackedAddresses, to: []},
        {from: [], to: $trackedAddresses}
      ]
    }) {
      from { address }
      to { address }
      value
      type
    }

    logs(filter: {
      addresses: [],
      topics: [
        "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
        [],
        $trackedAddressesPadded
      ]
    }) {
      topics
      data
      account { address }
      transaction {
        hash
        from { address }
        to { address }
        value
        status
      }
    }
  }
}
```

### Webhook 2 — ERC-20 Sends

```graphql
query ($trackedAddressesPadded: [Bytes32!]!) {
  block {
    hash
    number
    timestamp

    logs(filter: {
      addresses: [],
      topics: [
        "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
        $trackedAddressesPadded,
        []
      ]
    }) {
      topics
      data
      account { address }
      transaction {
        hash
        from { address }
        to { address }
        value
        status
      }
    }
  }
}
```

## Local testing

```bash
npx projen test:alchemyWebhookListener
```

Runs the webhook listener locally with signature verification skipped.

## Useful commands

| Command | Description |
|---|---|
| `npx projen build` | Full build |
| `npx projen bundle` | Bundle Lambda functions |
| `npx projen deploy` | Deploy to AWS |
| `npx projen diff` | Diff against deployed stack |
| `npx projen destroy` | Tear down the stack |
