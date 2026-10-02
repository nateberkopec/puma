# frozen_string_literal: true

require 'stringio'

module Puma
  class IOBuffer
    def initialize
      @io = StringIO.new
      @io.binmode if @io.respond_to?(:binmode)
    end

    def empty?
      length.zero?
    end

    def length
      @io.length
    end

    def size
      @io.size
    end

    def write(*strs)
      strs.sum { |str| @io.write(str) }
    end

    def <<(str)
      @io << str
      self
    end

    def reset
      @io.truncate 0
      @io.rewind
    end

    def to_s
      @io.rewind
      @io.read
    end

    # Read & Reset - returns contents and resets
    # @return [String] StringIO contents
    def read_and_reset
      @io.rewind
      str = @io.read
      @io.truncate 0
      @io.rewind
      str
    end

    def clear
      reset
    end

    def append(*strs)
      write(*strs)
    end
  end
end
