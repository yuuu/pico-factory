# pico-factory

> **Demo project for RubyKaigi 2026 talk:**
> [PicoRuby for IoT: Connecting to the Cloud with MQTT](https://rubykaigi.org/2026/presentations/Y_uuu.html)

PicoRuby programs running on a Raspberry Pi Pico connect to AWS IoT Core over MQTT, send sensor data to the cloud, and display real-time detection counts on a browser dashboard. The dashboard also lets you send commands (start / stop / reboot) back to the device.

## System Overview

```
[IoT Device (PicoRuby)]
     |
     | MQTT  pico-factory/device/{device_id}
     v
[AWS IoT Core]
     |
     | IoT Rule
     v
[DynamoDB: records]
     |
     | DynamoDB Streams
     v
[Lambda: stream_notifier]
     |
     | WebSocket push  {"count": N}
     v
[Browser Dashboard] <---> [API Gateway WebSocket]
     |
     | REST API  POST /publish, POST /clear
     v
[Lambda: api_handler] --> [AWS IoT Core] --> [IoT Device]
```

## Repository Structure

```
pico-factory/
├── cloud/
│   └── pico-factory-backend/   # AWS SAM serverless backend
│       ├── template.yaml        # SAM template (all AWS resource definitions)
│       ├── samconfig.toml       # SAM CLI deployment config
│       ├── frontend/            # Browser dashboard (served via S3 + CloudFront)
│       ├── ws_handler/          # Lambda: WebSocket connection management
│       ├── stream_notifier/     # Lambda: DynamoDB Streams → WebSocket push
│       └── api_handler/         # Lambda: REST API (publish / clear)
└── device/
    ├── demo1.rb                 # PWM motor control only (no cloud)
    ├── demo2.rb                 # MQTT + motor control
    └── demo3.rb                 # MQTT + ToF distance sensor + motor control
```

## Device Programs

| File | Description |
|------|-------------|
| `device/demo1.rb` | Controls a DC motor via PWM. No cloud connectivity. |
| `device/demo2.rb` | Connects to AWS IoT Core over MQTT. Receives `start` / `stop` / `reboot` commands and drives the motor accordingly. |
| `device/demo3.rb` | Reads distance from a VL53L0X ToF sensor (I2C). Detects objects within 100 mm and publishes detection data to the cloud with a timestamp. |

## Tech Stack

| Layer | Technology |
|-------|------------|
| Device | PicoRuby, MQTT, VL53L0X ToF sensor |
| Cloud | AWS IoT Core, DynamoDB, Lambda (Ruby 3.4), API Gateway, S3, CloudFront |
| Infrastructure | AWS SAM |
| Frontend | HTML/JS, Tailwind CSS, Chart.js, Luxon |

## Prerequisites

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) with credentials configured
- [SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-sam-cli-install.html)
- Ruby 3.4
- Raspberry Pi Pico running PicoRuby

## Quick Start

### 1. Deploy the backend

```bash
cd cloud/pico-factory-backend
sam build
sam deploy --guided   # first time only
```

After deployment, note the CloudFormation stack outputs:

| Output key | Description |
|------------|-------------|
| `WebSocketUrl` | WebSocket endpoint for the dashboard |
| `RestApiEndpoint` | REST API base URL for the dashboard |
| `FrontendBucketName` | S3 bucket to upload frontend files |
| `FrontendUrl` | CloudFront URL to open the dashboard |

### 2. Upload the frontend

```bash
aws s3 sync ./frontend s3://{FrontendBucketName} --delete
```

### 3. Configure the dashboard

Open `https://{FrontendUrl}` and enter the `WebSocketUrl` and `RestApiEndpoint` in **Settings**.

### 4. Configure the device

Create a device certificate in AWS IoT Core, then update the following values in `device/demo2.rb` or `device/demo3.rb`:

```ruby
ENDPOINT  = "xxxxxxxxxxxx-ats.iot.ap-northeast-1.amazonaws.com"
DEVICE_ID = "your-device-id"
```

Place the CA certificate, client certificate, and private key on the device filesystem and set their paths in the program.

## Backend Details

See [`cloud/pico-factory-backend/README.md`](cloud/pico-factory-backend/README.md) for full API reference, DynamoDB table design, local development guide, and teardown instructions.

## Teardown

```bash
aws s3 rm s3://{FrontendBucketName} --recursive
sam delete --stack-name pico-factory-backend
```
