import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocument } from '@aws-sdk/lib-dynamodb';

/**
 * Shared DynamoDB Document client with standard marshalling options.
 * Used across lambdas that interact with the xstocks-user-address table.
 */
export const dynamo = DynamoDBDocument.from(new DynamoDBClient({}), {
  marshallOptions: { convertEmptyValues: false, removeUndefinedValues: true, convertClassInstanceToMap: false },
  unmarshallOptions: { wrapNumbers: false },
});
