# frozen_string_literal: true

require_relative 'binding'
require_relative 'configuration'
require_relative 'spinel_server'

module Puma
  # Single-process runner for Spinel, using Puma's configuration and bindings.
  class Single
    def initialize(config, log_writer: LogWriter.stdio)
      @config = config
      @log_writer = log_writer
      @server = nil
    end

    def run(background = false)
      @config.clamp
      options = @config.options
      raise ArgumentError, "cluster mode is unavailable on Spinel" unless options[:workers] == 0
      raise ArgumentError, "Spinel requires an app configured in the compiled program" unless options[:app]

      raise ArgumentError, "Spinel supports one TCP listener" unless options[:binds].length == 1

      binding = Binding.parse(options[:binds].first, options, @log_writer)
      raise ArgumentError, "Spinel supports TCP binds only" unless binding.is_a?(TCPBinding)

      @server = Server.new(@config.app, @config.events, options)
      @server.add_tcp_listener(binding.host, binding.port)
      thread = @server.run
      thread.join unless background
      thread
    end

    def connected_ports
      @server.connected_ports
    end

    def stop(sync = true)
      @server&.stop(sync)
    end
  end
end
