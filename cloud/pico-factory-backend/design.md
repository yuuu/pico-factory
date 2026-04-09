# AWS IoT リアルタイムダッシュボード 設計指針

## 概要

AWS IoT Core をデータ源とし、DynamoDB にレコードを蓄積しながら、WebSocket を通じてブラウザ上のダッシュボードへリアルタイムにカウントを表示するシステムの設計指針。

---

## システム構成

### コンポーネント一覧

| コンポーネント | サービス | 役割 |
|---|---|---|
| フロントエンド | S3 + CloudFront | 静的 HTML/JS のホスティング |
| WebSocket API | API Gateway (WebSocket) | ブラウザとの双方向通信 |
| 接続管理 | Lambda (`ws_handler`) | 接続 ID の保存・削除 |
| Push 通知 | Lambda (`stream_notifier`) | カウント変化の全クライアントへの Push |
| 汎用 API | Lambda (`api_handler`) | IoT publish、DynamoDB クリア |
| データ格納 | DynamoDB (`records`) | IoT メッセージの格納（Streams 有効） |
| 接続管理 DB | DynamoDB (`connections`) | WebSocket connectionId 管理 |
| データ取り込み | AWS IoT Core + IoT Rule | MQTT メッセージ受信 → DynamoDB 書き込み |
| IaC | AWS SAM | 全リソースのコード管理・デプロイ |

### データフロー

```
[デバイス/外部] --MQTT--> IoT Core
                              |
                         IoT Rule
                              |
                          Lambda (IoT Rule Action)
                              |
                         DynamoDB (records テーブル)
                              |
                      DynamoDB Streams
                              |
                     Lambda (stream_notifier)
                              |
                    API Gateway (WebSocket)
                              |
                          ブラウザ (Dashboard)
```

---

## フロントエンド

### ホスティング

- S3 バケットに静的ファイルを配置し、CloudFront で配信する
- React 等のフレームワークは不要。素の HTML + JavaScript で実装する

### 機能と実装方針

| UI 要素 | 動作 | 実装 |
|---|---|---|
| カウント表示 | DynamoDB レコード数をリアルタイム表示 | WebSocket で Push を受信して DOM 更新 |
| 開始ボタン | IoT Core の制御トピックにメッセージ送信 | `fetch()` → REST API → Lambda → IoT publish |
| 終了ボタン | 同上 | 同上 |
| クリアボタン | DynamoDB のレコードを全件削除 | `fetch()` → REST API → Lambda → DynamoDB 削除 |

### WebSocket 接続

```javascript
const ws = new WebSocket('wss://{api-id}.execute-api.{region}.amazonaws.com/{stage}');

ws.onmessage = (event) => {
  const { count } = JSON.parse(event.data);
  document.getElementById('count').textContent = count;
};
```

---

## バックエンド（Lambda 3本構成）

### 1. `ws_handler` — WebSocket 接続管理

- **トリガー**: API Gateway WebSocket (`$connect` / `$disconnect`)
- **処理**:
  - `$connect` 時: `connectionId` を `connections` テーブルに保存
  - `$disconnect` 時: `connectionId` を `connections` テーブルから削除

### 2. `stream_notifier` — DynamoDB Streams トリガー

- **トリガー**: DynamoDB Streams（`records` テーブルの変更イベント）
- **処理**:
  - Streams イベントの `eventName`（`INSERT` / `REMOVE`）から増減を計算し、現在のカウントを算出する（フルスキャンを避けるため差分方式を採用）
  - `connections` テーブルから全 `connectionId` を取得
  - `Aws::ApiGatewayManagementApi::Client` でカウントを全クライアントに Push

```ruby
client = Aws::ApiGatewayManagementApi::Client.new(
  endpoint: ENV['WEBSOCKET_ENDPOINT'] # 環境変数で渡す
)

client.post_to_connection(
  connection_id: connection_id,
  data: { count: count }.to_json
)
```

### 3. `api_handler` — REST API

- **トリガー**: API Gateway REST (`POST /publish`, `POST /clear`)
- **処理**:
  - `/publish`: `Aws::IoTDataPlane::Client` でトピック `pico-factory/action` に `{"action": "start"}` または `{"action": "stop"}` を送信
  - `/clear`: `records` テーブルの全件スキャン → `batch_write_item` で削除

---

## DynamoDB テーブル設計

### `records` テーブル

| 項目 | 設定 |
|---|---|
| パーティションキー | `device_id` (String) — デバイス ID（トピックの第3セグメント） |
| ソートキー | `timestamp` (Number) — Unix time |
| Streams | 有効 (`StreamViewType: NEW_IMAGE`) |
| TTL | `ttl` 属性を利用し、受信から1日経過したレコードを自動削除 |

### `connections` テーブル

| 項目 | 設定 |
|---|---|
| パーティションキー | `connectionId` (String) |
| TTL | `ttl` 属性を利用し、接続切れの残留レコードを自動削除（有効期限: 接続時刻 + 2時間） |

`ws_handler` の `$connect` 処理で `ttl: Time.now.to_i + 7200` を書き込む。

---

## AWS IoT Core

### トピック設計

| トピック | 方向 | 用途 |
|---|---|---|
| `pico-factory/device/{device_id}` | デバイス → クラウド | 計測データ送信 |
| `pico-factory/action` | クラウド → デバイス | ダッシュボードからの開始・終了コマンド |

#### ペイロード仕様（デバイス → クラウド）

```json
{"timestamp": 12345678}
```

- `timestamp`: デバイスが計測したイベントの Unix time (Integer)

#### ペイロード仕様（クラウド → デバイス）

| ボタン | ペイロード |
|---|---|
| 開始ボタン | `{"action": "start"}` |
| 終了ボタン | `{"action": "stop"}` |

### IoT Rule

- `pico-factory/device/+` に届いたメッセージを Lambda（または DynamoDB アクション）でそのまま `records` テーブルに書き込む
- **Lambda 経由を推奨**: 前処理・バリデーションを挟みやすい
- **DynamoDB アクション直書きも可**: Lambda レスでシンプルになるが、変換の柔軟性が下がる

#### TTL 値の設定

IoT Rule の SQL にて、受信時刻から 86400 秒（1日）後の Unix タイムスタンプを `ttl` 属性として付与する。

```sql
SELECT *, topic(3) AS device_id, (timestamp() / 1000 + 86400) AS ttl FROM 'pico-factory/device/+'
```

- `topic(3)` でトピック名の第3セグメント（デバイス ID）を取り出し `device_id` として付与する
- `timestamp()` は IoT Rule SQL の組み込み関数で、現在時刻をミリ秒単位の Unix タイムスタンプで返す
- DynamoDB の TTL は秒単位の Unix タイムスタンプを要求するため、1000 で割って秒に変換する
- Lambda 経由の場合は、Lambda 内でトピック名から `device_id` を抽出し、`Time.now.to_i + 86400` を `ttl` として設定する

---

## SAM テンプレート構成

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31

Resources:

  # DynamoDB: データ格納
  RecordsTable:
    Type: AWS::DynamoDB::Table
    Properties:
      TableName: records
      BillingMode: PAY_PER_REQUEST
      AttributeDefinitions:
        - AttributeName: device_id
          AttributeType: S
        - AttributeName: timestamp
          AttributeType: N
      KeySchema:
        - AttributeName: device_id
          KeyType: HASH
        - AttributeName: timestamp
          KeyType: RANGE
      StreamSpecification:
        StreamViewType: NEW_IMAGE
      TimeToLiveSpecification:
        AttributeName: ttl
        Enabled: true

  # DynamoDB: WebSocket 接続管理
  ConnectionsTable:
    Type: AWS::DynamoDB::Table
    Properties:
      TableName: connections
      BillingMode: PAY_PER_REQUEST
      AttributeDefinitions:
        - AttributeName: connectionId
          AttributeType: S
      KeySchema:
        - AttributeName: connectionId
          KeyType: HASH
      TimeToLiveSpecification:
        AttributeName: ttl
        Enabled: true

  # API Gateway: WebSocket
  WebSocketApi:
    Type: AWS::ApiGatewayV2::Api
    Properties:
      Name: DashboardWebSocket
      ProtocolType: WEBSOCKET
      RouteSelectionExpression: "$request.body.action"

  # Lambda: WebSocket 接続管理
  WsHandlerFunction:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: ws_handler/
      Handler: app.lambda_handler
      Runtime: ruby3.4
      Environment:
        Variables:
          CONNECTIONS_TABLE: !Ref ConnectionsTable
      Policies:
        - DynamoDBCrudPolicy:
            TableName: !Ref ConnectionsTable

  # Lambda: Streams → Push 通知
  StreamNotifierFunction:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: stream_notifier/
      Handler: app.lambda_handler
      Runtime: ruby3.4
      Environment:
        Variables:
          CONNECTIONS_TABLE: !Ref ConnectionsTable
          RECORDS_TABLE: !Ref RecordsTable
          WEBSOCKET_ENDPOINT: !Sub "https://${WebSocketApi}.execute-api.${AWS::Region}.amazonaws.com/prod"
      Policies:
        - DynamoDBReadPolicy:
            TableName: !Ref ConnectionsTable
        - DynamoDBReadPolicy:
            TableName: !Ref RecordsTable
        - Statement:
            - Effect: Allow
              Action: execute-api:ManageConnections
              Resource: !Sub "arn:aws:execute-api:${AWS::Region}:${AWS::AccountId}:${WebSocketApi}/*"
      Events:
        Stream:
          Type: DynamoDB
          Properties:
            Stream: !GetAtt RecordsTable.StreamArn
            StartingPosition: LATEST
            BatchSize: 10

  # Lambda: REST API (IoT publish / DynamoDB clear)
  ApiHandlerFunction:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: api_handler/
      Handler: app.lambda_handler
      Runtime: ruby3.4
      Environment:
        Variables:
          RECORDS_TABLE: !Ref RecordsTable
          IOT_ENDPOINT: !Sub "https://data.iot.${AWS::Region}.amazonaws.com"
      Policies:
        - DynamoDBCrudPolicy:
            TableName: !Ref RecordsTable
        - Statement:
            - Effect: Allow
              Action: iot:Publish
              Resource: "*"
      Events:
        Publish:
          Type: Api
          Properties:
            Path: /publish
            Method: post
        Clear:
          Type: Api
          Properties:
            Path: /clear
            Method: post
```

---

## 構築手順

```bash
# 1. SAM プロジェクト初期化
sam init --runtime ruby3.4 --name pico-factory-backend

# 2. template.yaml を上記に沿って記述

# 3. ビルド & デプロイ
sam build
sam deploy --guided

# 4. フロントエンドを S3 へアップロード
aws s3 sync ./frontend s3://{your-bucket-name} --delete

# 5. CloudFront ディストリビューションを S3 オリジンで作成（コンソールまたは CFn）

# 6. IoT Rule を作成（コンソールまたは CFn）
#    SQL: SELECT *, topic(3) AS device_id, (timestamp() / 1000 + 86400) AS ttl FROM 'pico-factory/device/+'
#    アクション: Lambda 呼び出し or DynamoDB 書き込み
```

---

## 注意事項・設計上のトレードオフ

### WebSocket エンドポイント URL

`stream_notifier` Lambda が `Aws::ApiGatewayManagementApi::Client` を使う際、エンドポイント URL（`https://{api-id}.execute-api.{region}.amazonaws.com/{stage}`）を環境変数として渡す必要がある。SAM テンプレートで `!Sub` を使って自動設定すること。

### クリア処理のスケール

全件スキャン → 削除はレコード数が多い場合にコスト・時間がかかる。以下のいずれかで対応する。

- **TTL の活用**: レコードに `ttl` 属性を付与し、クリア時は TTL を過去に更新する（削除は DynamoDB が非同期で実施）
- **テーブルの再作成**: 件数が非常に多い場合は `DeleteTable` → `CreateTable` の方が高速

### IoT Rule のアクション選択

| 方式 | メリット | デメリット |
|---|---|---|
| Lambda 経由 | 前処理・バリデーション・エラーハンドリングが容易 | Lambda のコールドスタートがある |
| DynamoDB アクション直書き | Lambda 不要でシンプル | データ変換の柔軟性が低い |

### 同時接続数

API Gateway WebSocket は 1 API あたりデフォルト 500 同時接続（Service Quota で引き上げ可能）。大規模用途の場合は要確認。

---

## コスト概算（小規模利用）

| サービス | 課金軸 | 目安 |
|---|---|---|
| Lambda | 実行回数・実行時間 | ほぼ無料枠内 |
| DynamoDB | 読み書きキャパシティ | PAY_PER_REQUEST で従量 |
| API Gateway (WebSocket) | 接続時間・メッセージ数 | 接続 $0.25/100万分 |
| IoT Core | メッセージ数 | $0.08/100万メッセージ |
| S3 + CloudFront | ストレージ・転送量 | ほぼ無料枠内 |

小規模の PoC・検証用途であれば、月額数ドル以内に収まることがほとんど。