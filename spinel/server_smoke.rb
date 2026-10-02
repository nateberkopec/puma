# frozen_string_literal: true

require_relative '../lib/puma'
require_relative 'smoke_app'

server = Puma::Server.new(SMOKE_APP)
listener = server.add_tcp_listener('127.0.0.1', 0)
puts listener.addr[1]
STDOUT.flush
server.run
sleep 5
server.stop(true)
