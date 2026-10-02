# frozen_string_literal: true

require_relative '../lib/puma'
require_relative '../lib/puma/reactor'

reactor = Puma::Reactor.new(:auto) { |_client| true }
selector = reactor.instance_variable_get(:@selector)
raise 'Spinel did not select IO.select' unless selector.is_a?(Puma::IOSelectSelector)

reader, writer = IO.pipe
selector.register(reader, :r).value = 'ready'
writer.write('x')
seen = nil
selector.select(1) { |registration| seen = registration.value }
raise 'selector did not report readable IO' unless seen == 'ready'

selector.deregister(reader)
selector.wakeup
selector.select(1) { |_registration| raise 'unexpected readable IO' }
selector.close
reader.close
writer.close

class ReactorClient
  def initialize(io)
    @io = io
  end

  def io_ok? = true
  def to_io = @io
  def timeout = 1
  def timeout_at = 1
end

reader, writer = IO.pipe
seen = Queue.new
reactor = Puma::Reactor.new(:auto) { |client| seen << client; true }
reactor.run
client = ReactorClient.new(reader)
reactor.add(client)
writer.write('x')
raise 'reactor missed readable client' unless seen.pop == client
reactor.shutdown
reader.close
writer.close
puts 'Spinel Puma selector OK'
