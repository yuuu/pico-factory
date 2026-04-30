# pico-factory-backend

> **Demo project for RubyKaigi 2026 talk:**
> [PicoRuby for IoT: Connecting to the Cloud with MQTT](https://rubykaigi.org/2026/presentations/Y_uuu.html)

A serverless backend that receives data from IoT devices via AWS IoT Core, stores records in DynamoDB, and delivers real-time updates to a browser dashboard over WebSocket. All AWS resources are managed with AWS SAM.

## Architecture

```
[IoT Device]
     |
     | MQTT (pico-factory/device/{device_id})
     v
[AWS IoT Core]
     |
     | IoT Rule: SELECT *, topic(3) AS device_id, (timestamp()/1000 + 86400) AS ttl
     |           FROM 'pico-factory/device/+'
     v
[DynamoDB: records table]
     |
     | DynamoDB Streams
     v
[Lambda: stream_notifier]
     |
     | WebSocket Push  {"count": N}
     v
[API Gateway WebSocket] <-----> [Browser Dashboard (S3 + CloudFront)]
                                        |
                             REST API (POST /publish, POST /clear)
                                        |
                               [Lambda: api_handler]
                                   |            |
                         [AWS IoT Core]    [DynamoDB: records]
                         (publish action)  (delete all records)
```

## Components

| Component | AWS Service | Responsibility |
|---|---|---|
| Frontend | S3 + CloudFront | Static HTML/JS hosting |
| WebSocket API | API Gateway v2 (WebSocket) | Bidirectional browser communication |
| Connection manager | Lambda (`ws_handler`) | Save/delete connectionId on connect/disconnect |
| Push notifier | Lambda (`stream_notifier`) | Broadcast DynamoDB changes to all connected clients |
| REST API | Lambda (`api_handler`) | IoT publish, DynamoDB clear |
| Data store | DynamoDB (`records`) | IoT message storage (Streams enabled) |
| Connection store | DynamoDB (`connections`) | WebSocket connectionId management |
| Data ingestion | AWS IoT Core + IoT Rule | MQTT message → DynamoDB write |
| IaC | AWS SAM | Resource definition and deployment |

## Directory Structure

```
pico-factory-backend/
├── template.yaml          # AWS SAM template (all resource definitions)
├── samconfig.toml         # SAM CLI deployment config
├── Gemfile                # Shared dependencies
├── ws_handler/            # Lambda: WebSocket connection management
│   ├── app.rb
│   └── Gemfile
├── stream_notifier/       # Lambda: DynamoDB Streams → WebSocket push
│   ├── app.rb
│   └── Gemfile
├── api_handler/           # Lambda: REST API (IoT publish / clear)
│   ├── app.rb
│   └── Gemfile
├── tests/
│   └── unit/
│       └── test_handler.rb
└── events/                # Sample events for sam local invoke
```

## Prerequisites

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) with credentials configured
- [SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-sam-cli-install.html)
- [Ruby 3.4](https://www.ruby-lang.org/en/documentation/installation/)
- [Docker](https://hub.docker.com/search/?type=edition&offering=community) (for local testing)

## Deployment

### First deployment

```bash
sam build
sam deploy --guided
```

`--guided` walks you through the configuration interactively:

| Prompt | Recommended value |
|---|---|
| Stack Name | `pico-factory-backend` |
| AWS Region | e.g. `ap-northeast-1` |
| Confirm changes before deploy | `y` |
| Allow SAM CLI IAM role creation | `y` |
| Save arguments to samconfig.toml | `y` |

Settings are saved to `samconfig.toml`, so subsequent deploys only need:

```bash
sam build
sam deploy
```

### Stack outputs

After deployment, the following values are printed. Use them to configure the frontend.

| Output key | Description |
|---|---|
| `WebSocketUrl` | WebSocket endpoint (`wss://...`) |
| `RestApiEndpoint` | REST API base URL |
| `FrontendUrl` | CloudFront distribution URL |
| `FrontendBucketName` | S3 bucket for frontend files |

### Upload the frontend

```bash
aws s3 sync ./frontend s3://{FrontendBucketName} --delete
```

## API Reference

### WebSocket API

**Endpoint**: `wss://{api-id}.execute-api.{region}.amazonaws.com/prod`

| Route | Behavior |
|---|---|
| `$connect` | Saves connectionId to `connections` table (TTL: 2 hours) |
| `$disconnect` | Removes connectionId from `connections` table |

**Server → Client push message**

```json
{"count": 123}
```

Total record count from the `records` table, broadcast to all connected clients whenever a new record is inserted.

### REST API

#### `POST /publish` — Send a command to IoT devices

```bash
curl -X POST {RestApiEndpoint}/publish \
  -H 'Content-Type: application/json' \
  -d '{"action": "start"}'
```

Valid `action` values: `start` / `stop` / `reboot`

Publishes the payload to the IoT topic `pico-factory/action`.

#### `POST /clear` — Delete all records

```bash
curl -X POST {RestApiEndpoint}/clear \
  -H 'Content-Type: application/json' \
  -d '{}'
```

Deletes all items from the `records` table.

## IoT Topic Design

| Topic | Direction | Purpose |
|---|---|---|
| `pico-factory/device/{device_id}` | Device → Cloud | Measurement data |
| `pico-factory/action` | Cloud → Device | start / stop / reboot commands |

**Device payload**:

```json
{"timestamp": 1234567890}
```

The IoT Rule transforms and writes this to DynamoDB using:

```sql
SELECT *, topic(3) AS device_id, (timestamp() / 1000 + 86400) AS ttl
FROM 'pico-factory/device/+'
```

## DynamoDB Table Design

### `records` table

| Field | Value |
|---|---|
| Partition key | `device_id` (String) |
| Sort key | `timestamp` (Number) |
| Streams | Enabled (`NEW_IMAGE`) |
| TTL | `ttl` attribute — auto-deleted 1 day after ingestion |

### `connections` table

| Field | Value |
|---|---|
| Partition key | `connectionId` (String) |
| TTL | `ttl` attribute — auto-deleted 2 hours after connection |

## Local Development

### Unit tests

```bash
ruby tests/unit/test_handler.rb
```

### Invoke a Lambda function locally

```bash
sam local invoke WsHandlerFunction --event events/event.json
sam local invoke StreamNotifierFunction --event events/event.json
sam local invoke ApiHandlerFunction --event events/event.json
```

### Run the REST API locally

```bash
sam local start-api
curl -X POST http://localhost:3000/publish -d '{"action": "start"}'
```

### Tail Lambda logs

```bash
sam logs -n WsHandlerFunction --stack-name pico-factory-backend --tail
sam logs -n StreamNotifierFunction --stack-name pico-factory-backend --tail
sam logs -n ApiHandlerFunction --stack-name pico-factory-backend --tail
```

## Teardown

If the S3 bucket contains objects, empty it first:

```bash
aws s3 rm s3://{FrontendBucketName} --recursive
```

Then delete the stack:

```bash
sam delete --stack-name pico-factory-backend
```

## Cost Estimate (small scale)

| Service | Billing dimension | Estimate |
|---|---|---|
| Lambda | Invocations + duration | Within free tier |
| DynamoDB | Read/write capacity | Pay-per-request |
| API Gateway (WebSocket) | Connection minutes + messages | $0.25 / 1M connection-minutes |
| IoT Core | Messages | $0.08 / 1M messages |
| S3 + CloudFront | Storage + transfer | Within free tier |

For small-scale PoC usage, total cost is typically a few dollars per month or less.
