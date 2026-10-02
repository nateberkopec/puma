# frozen_string_literal: true

module Puma
  # Selector used when nio4r is unavailable or :select is requested.
  class IOSelectSelector
    Registration = Struct.new(:io, :value)

    def initialize
      @monitors = {}
      @wake_reader, @wake_writer = IO.pipe
    end

    def register(io, _interest)
      monitor = Registration.new(io)
      @monitors[io] = monitor
      monitor
    end

    def deregister(io)
      @monitors.delete(io)
    end

    def select(timeout)
      ready = IO.select([@wake_reader, *@monitors.keys], nil, nil, timeout)
      return unless ready

      ready[0].each do |io|
        if io == @wake_reader
          @wake_reader.read_nonblock(4096)
        elsif monitor = @monitors[io]
          yield monitor
        end
      end
    rescue IO::WaitReadable
      nil
    end

    def wakeup
      @wake_writer.write_nonblock('.')
    rescue IO::WaitWritable, IOError
      nil
    end

    def close
      @wake_reader.close unless @wake_reader.closed?
      @wake_writer.close unless @wake_writer.closed?
    end
  end
end
