require 'net/mqtt'
require 'pwm'
require 'i2c'
require 'vl53l0x'

motor_forward = PWM.new(4, frequency: 100)
motor_reverse = PWM.new(5, frequency: 100)
motor_forward.duty(0)
motor_reverse.duty(0)

i2c = I2C.new(unit: :ESP32_I2C0, frequency: 100_000, sda_pin: 6, scl_pin: 7, timeout: 2000)
tof = VL53L0X.new(i2c)

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

puts "Starting demo..."
motor_forward.duty(25)

pre_detected = false
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

  distance = tof.read_distance
  detected = distance < 100
  if !pre_detected && detected
    print "Detect the ball"
    client.publish('pico-factory/data', "{ \"timestamp\": \"#{Time.now}\" }")
    puts " -> Published"
  end
  pre_detected = detected

  sleep_ms(1)
end

puts 'Finished'
