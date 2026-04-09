require 'json'
require 'aws-sdk-dynamodb'
require 'aws-sdk-iotdataplane'
require 'aws-sdk-iot'

DYNAMODB = Aws::DynamoDB::Client.new
RECORDS_TABLE = ENV['RECORDS_TABLE']
IOT_TOPIC = 'pico-factory/action'

# IoT エンドポイントはコールドスタート時に一度だけ取得してキャッシュする
def iot_endpoint
  @iot_endpoint ||= begin
    iot = Aws::IoT::Client.new
    "https://#{iot.describe_endpoint(endpoint_type: 'iot:Data-ATS').endpoint_address}"
  end
end

def lambda_handler(event:, context:)
  path = event['path'] || event.dig('requestContext', 'resourcePath')
  http_method = event['httpMethod']

  # OPTIONS プリフライトリクエスト
  return cors_response(200, {}) if http_method == 'OPTIONS'

  body = event['body'] ? JSON.parse(event['body']) : {}

  case path
  when '/publish'
    handle_publish(body)
  when '/clear'
    handle_clear
  else
    cors_response(404, { error: 'Not found' })
  end
rescue JSON::ParserError
  cors_response(400, { error: 'Invalid JSON body' })
rescue => e
  puts "Error in api_handler: #{e.class} - #{e.message}"
  puts e.backtrace.first(5).join("\n")
  cors_response(500, { error: 'Internal server error' })
end

def handle_publish(body)
  action = body['action']
  unless %w[start stop].include?(action)
    return cors_response(400, { error: "Invalid action. Must be 'start' or 'stop'" })
  end

  client = Aws::IoTDataPlane::Client.new(endpoint: iot_endpoint)
  client.publish(
    topic: IOT_TOPIC,
    payload: { action: action }.to_json,
    qos: 0
  )

  puts "Published action '#{action}' to #{IOT_TOPIC}"
  cors_response(200, { message: "Published action: #{action}" })
end

def handle_clear
  all_items = []
  params = { table_name: RECORDS_TABLE }

  loop do
    result = DYNAMODB.scan(params)
    all_items.concat(result.items)
    break unless result.last_evaluated_key
    params[:exclusive_start_key] = result.last_evaluated_key
  end

  deleted_count = 0

  all_items.each_slice(25) do |batch|
    delete_requests = batch.map do |item|
      {
        delete_request: {
          key: {
            'device_id' => item['device_id'],
            'timestamp' => item['timestamp']
          }
        }
      }
    end

    next if delete_requests.empty?

    DYNAMODB.batch_write_item(
      request_items: { RECORDS_TABLE => delete_requests }
    )
    deleted_count += delete_requests.length
  end

  puts "Cleared #{deleted_count} records"
  cors_response(200, { message: "Cleared #{deleted_count} records" })
end

def cors_response(status_code, body)
  {
    statusCode: status_code,
    headers: {
      'Content-Type' => 'application/json',
      'Access-Control-Allow-Origin' => '*',
      'Access-Control-Allow-Headers' => 'Content-Type,Authorization',
      'Access-Control-Allow-Methods' => 'POST,OPTIONS'
    },
    body: body.to_json
  }
end
