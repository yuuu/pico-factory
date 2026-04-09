require 'json'
require 'aws-sdk-dynamodb'
require 'aws-sdk-apigatewaymanagementapi'

DYNAMODB = Aws::DynamoDB::Client.new
CONNECTIONS_TABLE = ENV['CONNECTIONS_TABLE']
RECORDS_TABLE = ENV['RECORDS_TABLE']
WEBSOCKET_ENDPOINT = ENV['WEBSOCKET_ENDPOINT']

def lambda_handler(event:, context:)
  puts "Stream event received: #{event['Records']&.length} records"

  count = get_record_count
  puts "Current record count: #{count}"

  broadcast_count(count)

  { statusCode: 200 }
rescue => e
  puts "Error in stream_notifier: #{e.class} - #{e.message}"
  puts e.backtrace.first(5).join("\n")
  raise e
end

def get_record_count
  total = 0
  params = { table_name: RECORDS_TABLE, select: 'COUNT' }

  loop do
    result = DYNAMODB.scan(params)
    total += result.count
    break unless result.last_evaluated_key
    params[:exclusive_start_key] = result.last_evaluated_key
  end

  total
end

def broadcast_count(count)
  client = Aws::ApiGatewayManagementApi::Client.new(
    endpoint: WEBSOCKET_ENDPOINT
  )

  connections = get_all_connections
  puts "Broadcasting to #{connections.length} connections"

  stale_connections = []

  connections.each do |connection_id|
    client.post_to_connection(
      connection_id: connection_id,
      data: { count: count }.to_json
    )
  rescue Aws::ApiGatewayManagementApi::Errors::GoneException
    puts "Stale connection detected: #{connection_id}"
    stale_connections << connection_id
  rescue => e
    puts "Failed to push to #{connection_id}: #{e.class} - #{e.message}"
  end

  remove_stale_connections(stale_connections)
end

def get_all_connections
  connections = []
  params = { table_name: CONNECTIONS_TABLE }

  loop do
    result = DYNAMODB.scan(params)
    connections.concat(result.items.map { |item| item['connectionId'] })
    break unless result.last_evaluated_key
    params[:exclusive_start_key] = result.last_evaluated_key
  end

  connections
end

def remove_stale_connections(connection_ids)
  connection_ids.each do |connection_id|
    DYNAMODB.delete_item(
      table_name: CONNECTIONS_TABLE,
      key: { 'connectionId' => connection_id }
    )
  rescue => e
    puts "Failed to remove stale connection #{connection_id}: #{e.message}"
  end
end
