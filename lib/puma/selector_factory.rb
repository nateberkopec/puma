# frozen_string_literal: true

require_relative 'io_select_selector'

module Puma
  module Selectors
    class Nio
      def supports?(backend)
        return false if RUBY_ENGINE == 'spinel' || backend == :select

        require 'nio'
        backend == :auto || ::NIO::Selector.backends.include?(backend)
      rescue LoadError
        false
      end

      def build(backend)
        ::NIO::Selector.new(::NIO::Selector.backends.delete(backend))
      end
    end

    class Select
      def supports?(backend)
        backend == :auto || backend == :select
      end

      def build(_backend)
        IOSelectSelector.new
      end
    end

    def self.build(backend)
      strategy = [Nio.new, Select.new].find { |candidate| candidate.supports?(backend) }
      raise ArgumentError, "unsupported IO selector backend: #{backend}" unless strategy

      strategy.build(backend)
    end
  end
end
