require 'json'
require 'aws-sdk-dynamodb'

DYNAMODB = Aws::DynamoDB::Client.new
RECORDS_TABLE = ENV['RECORDS_TABLE']

def lambda_handler(event:, context:)
  puts "IoT event received: #{event.inspect}"

  device_id = event['device_id']
  timestamp = event['timestamp']
  ttl = event['ttl']

  unless device_id && timestamp
    puts "Missing required fields. device_id=#{device_id.inspect}, timestamp=#{timestamp.inspect}"
    return { statusCode: 400, body: 'Missing required fields: device_id, timestamp' }
  end

  DYNAMODB.put_item(
    table_name: RECORDS_TABLE,
    item: {
      'device_id' => device_id.to_s,
      'timestamp' => timestamp.to_i,
      'ttl' => (ttl || Time.now.to_i + 86400).to_i
    }
  )

  puts "Stored record: device_id=#{device_id}, timestamp=#{timestamp}"
  { statusCode: 200 }
rescue => e
  puts "Error in iot_handler: #{e.class} - #{e.message}"
  puts e.backtrace.first(5).join("\n")
  raise e
end
