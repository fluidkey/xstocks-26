# xStocks2026

Real-time on-chain token transfer tracker powered by [Alchemy Custom Webhooks](https://docs.alchemy.com/reference/custom-webhook-variables) and AWS Lambda.

## What it does

Monitors a set of wallet addresses for all token movement — both sending and receiving — across three transfer types:

- **Native token transfers (external)** — direct ETH/MATIC sends between wallets
- **Native token transfers (internal)** — contract-initiated native transfers (e.g. `.call{value: ...}`)
- **ERC-20 token transfers** — any tracked ERC-20 token sent to or from tracked wallets

Alchemy pushes webhook events to a Lambda Function URL whenever matching on-chain activity is detected.

## Architecture

```
Alchemy Custom Webhooks (x2)
        │
        ├── Webhook 1: ERC-20 receives + native transfers
        ├── Webhook 2: ERC-20 sends
        │
        ▼
  Lambda Function URL
        │
        └── Logs structured events to CloudWatch
            ├── NATIVE_EXTERNAL
            ├── NATIVE_INTERNAL
            ├── ERC20_RECEIVED
            └── ERC20_SENT
```

We use two webhooks because Alchemy's log topic filters are AND across positions.
You can't do "from OR to" in a single `logs` query, so we split:
- Webhook 1: `topics[2]` = tracked addresses (receives) + native tx/trace filters
- Webhook 2: `topics[1]` = tracked addresses (sends)

## Project structure

```
src/
├── main.ts                          # CDK stack definition
└── lambda-functions/
    ├── alchemy-webhook-listener/
    │   ├── alchemy-webhook-listener.lambda.ts      # Lambda handler source
    │   └── alchemy-webhook-listener-function.ts    # Projen-generated CDK construct
    └── alchemy-setup-variables/
        ├── alchemy-setup-variables.lambda.ts       # Variable setup handler
        └── alchemy-setup-variables-function.ts     # Projen-generated CDK construct
```

## Prerequisites

- AWS CLI configured with credentials
- Node.js 22+
- Yarn 4.x
- An [Alchemy](https://www.alchemy.com/) account

## Setup

### 1. Install dependencies

```bash
yarn install
```

### 2. Create SSM parameters

```bash
# Alchemy Auth Token (from top of https://dashboard.alchemy.com/webhooks)
aws ssm put-parameter \
  --name /xstocks/alchemy-auth-token \
  --value "YOUR_ALCHEMY_AUTH_TOKEN" \
  --type String

# Signing keys — use a placeholder for now, update after creating webhooks (Step 7)
aws ssm put-parameter \
  --name /xstocks/alchemy-signing-keys \
  --value "placeholder" \
  --type String
```

### 3. Bundle and deploy

```bash
npx projen bundle
npx projen deploy
```

The deploy output will print `AlchemyWebhookUrl` — copy this URL.

### 4. Create webhook variables

Invoke the setup lambda to create the `trackedAddresses` and `trackedAddressesPadded` variables on Alchemy:

```bash
aws lambda invoke \
  --function-name <AlchemySetupVariables function name> \
  --cli-binary-format raw-in-base64-out \
  --payload '{"trackedAddresses": ["0xYOUR_WALLET_1", "0xYOUR_WALLET_2"]}' \
  /dev/stdout
```

The lambda automatically creates both:
- `trackedAddresses` — normal format for transaction/trace filters
- `trackedAddressesPadded` — zero-padded to 32 bytes for log topic filters

> To find the exact function name: `aws lambda list-functions --query "Functions[?contains(FunctionName, 'SetupVariables')].FunctionName"`

### 5. Create Webhook 1 — Receives + Native transfers

Go to [Alchemy Webhooks Dashboard](https://dashboard.alchemy.com/webhooks) → Create Webhook → Custom (GraphQL).

Paste the Lambda Function URL as the webhook URL, then use this query:

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

This catches:
- All native token transfers (external + internal) involving your tracked addresses
- All ERC-20 Transfer events where your tracked address is the **recipient** (`topics[2]`)

### 6. Create Webhook 2 — ERC-20 Sends

Create a second webhook with the same Lambda URL but this query:

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

This catches all ERC-20 Transfer events where your tracked address is the **sender** (`topics[1]`).

### 7. Update the SSM signing keys

Each webhook gets its own signing key. Store both as a comma-separated value:

```bash
aws ssm put-parameter \
  --name /xstocks/alchemy-signing-keys \
  --value "whsec_key_from_webhook_1,whsec_key_from_webhook_2" \
  --type String \
  --overwrite
```

The Lambda tries each key when validating the signature — if any matches, the request is accepted.

## How the filters work

- **transactions filter** (Webhook 1) — catches direct native token sends where your tracked address is the sender (`from`) or receiver (`to`)
- **callTracerTraces filter** (Webhook 1) — catches internal native token transfers triggered by smart contracts
- **logs filter with topics[2]** (Webhook 1) — catches ERC-20 `Transfer` events where your tracked address is the **recipient**
- **logs filter with topics[1]** (Webhook 2) — catches ERC-20 `Transfer` events where your tracked address is the **sender**

Topics are positional per the `eth_getLogs` spec:
- `topics[0]` = event signature (Transfer)
- `topics[1]` = `from` address (sender)
- `topics[2]` = `to` address (recipient)

Empty arrays `[]` act as wildcards.

## Why two webhooks?

Alchemy's log topic filters use AND logic across positions. Putting `$trackedAddressesPadded` in both `topics[1]` and `topics[2]` would only match transfers **between** your own addresses. To catch "from OR to", we need two separate queries — and since Alchemy doesn't support GraphQL aliases on the `logs` field, that means two webhooks.

## Useful commands

| Command | Description |
|---|---|
| `npx projen build` | Full build (compile + synth + test + lint) |
| `npx projen bundle` | Bundle Lambda functions |
| `npx projen deploy` | Deploy to AWS |
| `npx projen diff` | Diff against deployed stack |
| `npx projen destroy` | Tear down the stack |
