require 'net/mqtt'
require 'pwm'
require 'json'
require 'i2c'
require 'vl53l0x'

puts 'Starting demo3...'
motor_forward = PWM.new(4, frequency: 100)
motor_reverse = PWM.new(5, frequency: 100)
motor_forward.duty(0)
motor_reverse.duty(0)

i2c = I2C.new(unit: :ESP32_I2C0, frequency: 100_000, sda_pin: 6, scl_pin: 7, timeout: 2000)
tof = VL53L0X.new(i2c)

client = Net::MQTT::Client.new(
  ENV['AWS_IOT_CORE_HOST'], 8883,
  client_id: 'pico-factory-device',
  ssl: true,
  ca_file: '/home/certs/AmazonRootCA1.pem',
  cert_file: '/home/certs/certificate.pem.crt',
  key_file: '/home/certs/private.pem.key'
)
client.connect
puts 'Connected to AWS IoT Core'

client.subscribe('pico-factory/action')
puts "Subscribed to topic 'pico-factory/action'"

status = :stopped
pre_detected = false

while true do
  topic, payload = client.receive(timeout: 0.005)
  if topic
    message = JSON.parse(payload)
    case message['action']
    when 'start'
      motor_forward.duty(25)
      status = :running
      puts "Status: #{status}"
    when 'stop'
      motor_forward.duty(0)
      status = :stop
      puts "Status: #{status}"
    when 'reboot'
      puts "Rebooting..."
      Machine.reboot
    end
  end

  distance = tof.read_distance
  detected = distance < 100
  if !pre_detected && detected
    print 'Detect the ball'
    client.publish("pico-factory/device/#{Machine.unique_id}", "{ \"timestamp\": #{Time.now.to_i} }")
    puts ' -> Published'
  end
  pre_detected = detected

  sleep_ms(1)
end

puts 'Finished'
