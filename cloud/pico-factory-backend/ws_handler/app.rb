require 'json'
require 'aws-sdk-dynamodb'

DYNAMODB = Aws::DynamoDB::Client.new
CONNECTIONS_TABLE = ENV['CONNECTIONS_TABLE']

def lambda_handler(event:, context:)
  route_key = event.dig('requestContext', 'routeKey')
  connection_id = event.dig('requestContext', 'connectionId')

  case route_key
  when '$connect'
    handle_connect(connection_id)
  when '$disconnect'
    handle_disconnect(connection_id)
  end

  { statusCode: 200, body: 'OK' }
rescue => e
  puts "Error in ws_handler: #{e.class} - #{e.message}"
  puts e.backtrace.first(5).join("\n")
  { statusCode: 500, body: 'Internal Server Error' }
end

def handle_connect(connection_id)
  DYNAMODB.put_item(
    table_name: CONNECTIONS_TABLE,
    item: {
      'connectionId' => connection_id,
      'ttl' => Time.now.to_i + 7200
    }
  )
  puts "Connected: #{connection_id}"
end

def handle_disconnect(connection_id)
  DYNAMODB.delete_item(
    table_name: CONNECTIONS_TABLE,
    key: { 'connectionId' => connection_id }
  )
  puts "Disconnected: #{connection_id}"
end
