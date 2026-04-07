require 'net/mqtt'
require 'pwm'

motor_forward = PWM.new(4, frequency: 100)
motor_reverse = PWM.new(5, frequency: 100)
motor_forward.duty(0)
motor_reverse.duty(0)

client = Net::MQTT::Client.new(
  'a1wa78bd136vy9-ats.iot.ap-northeast-1.amazonaws.com', 8883,
  client_id: "picoruby-publisher",
  ssl: true,
  ca_file: "/home/certs/AmazonRootCA1.pem",
  cert_file: "/home/certs/certificate.pem.crt",
  key_file: "/home/certs/private.pem.key"
)
client.connect
puts "Connected to AWS IoT Core"

client.subscribe('pico-factory/control')
puts "Subscribed to topic 'pico-factory/control'"

status = :stopped
while true do
  topic, message = client.receive
  case message
  when '{"action": "start"}'
    motor_forward.duty(25)
    status = :running
    puts "Status: #{status}"
  when '{"action": "stop"}'
    motor_forward.duty(0)
    status = :stop
    puts "Status: #{status}"
  else
    # NOP
  end
  sleep_ms(1)
end

puts 'Finished'
