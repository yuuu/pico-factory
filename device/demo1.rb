require 'pwm'

puts 'Starting demo1...'
motor_forward = PWM.new(4, frequency: 100)
motor_reverse = PWM.new(5, frequency: 100)
motor_forward.duty(0)
motor_reverse.duty(0)

motor_forward.duty(25)
motor_reverse.duty(0)

while true do
  sleep_ms(5)
end

puts 'Finished'
