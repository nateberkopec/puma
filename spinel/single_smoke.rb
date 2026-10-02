# frozen_string_literal: true

require_relative '../lib/puma'
require_relative 'smoke_app'

config = Puma::Configuration.new do |user|
  user.app SMOKE_APP
  user.port 0, '127.0.0.1'
end
runner = Puma::Single.new(config)
runner.run(true)
puts runner.connected_ports.first
STDOUT.flush
sleep 5
runner.stop(true)
