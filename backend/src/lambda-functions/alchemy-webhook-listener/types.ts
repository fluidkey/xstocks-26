export interface AlchemyWebhookEvent {
  webhookId: string;
  id: string;
  createdAt: string;
  type: string;
  event: {
    data: {
      block: {
        hash: string;
        number: number;
        timestamp: string;
        transactions?: Transaction[];
        callTracerTraces?: Trace[];
        logs?: Log[];
      };
    };
    sequenceNumber: string;
  };
}

export interface Transaction {
  hash: string;
  from: { address: string };
  to: { address: string };
  value: string;
  gas: number;
  status: number;
}

export interface Trace {
  from: { address: string };
  to: { address: string };
  value: string;
  type: string;
}

export interface Log {
  topics: string[];
  data: string;
  account: { address: string };
  transaction: {
    hash: string;
    from: { address: string };
    to: { address: string };
    value: string;
    status: number;
  };
}
