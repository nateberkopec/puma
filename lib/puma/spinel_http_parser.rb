# frozen_string_literal: true

require 'io/buffer'

# The C functions are linked from ext/puma_http11/http11_parser.c and
# spinel/puma_parser.c when building a Spinel executable.
module Puma
  module SpinelParserNative
    ffi_func :puma_spinel_parser_new, [], :ptr
    ffi_func :puma_spinel_parser_reset, [:ptr], :void
    ffi_func :puma_spinel_parser_free, [:ptr], :void
    ffi_func :puma_spinel_parser_execute, [:ptr, :str, :size_t, :size_t], :size_t
    ffi_func :puma_spinel_parser_error, [:ptr], :bool
    ffi_func :puma_spinel_parser_finished, [:ptr], :bool
    ffi_func :puma_spinel_parser_finish, [:ptr], :bool
    ffi_func :puma_spinel_parser_field_count, [:ptr], :size_t
    ffi_func :puma_spinel_parser_nread, [:ptr], :size_t
    ffi_func :puma_spinel_parser_field_name, [:ptr, :size_t], :str
    ffi_func :puma_spinel_parser_field_length, [:ptr, :size_t], :size_t
    ffi_func :puma_spinel_parser_field_copy, [:ptr, :size_t, :ptr], :void
  end

  class HttpParserError < StandardError; end

  class HttpParser
    def initialize
      @pointer = SpinelParserNative.puma_spinel_parser_new
      raise NoMemoryError, "Could not allocate HTTP parser" unless @pointer
      @field_index = 0
      @body = nil
    end

    def reset
      SpinelParserNative.puma_spinel_parser_reset(@pointer)
      @field_index = 0
      @body = nil
      nil
    end

    def execute(request, data, start)
      result = SpinelParserNative.puma_spinel_parser_execute(@pointer, data, data.bytesize, start)
      count = SpinelParserNative.puma_spinel_parser_field_count(@pointer)
      while @field_index < count
        name = SpinelParserNative.puma_spinel_parser_field_name(@pointer, @field_index)
        length = SpinelParserNative.puma_spinel_parser_field_length(@pointer, @field_index)
        buffer = IO::Buffer.new(length)
        SpinelParserNative.puma_spinel_parser_field_copy(@pointer, @field_index, buffer) if length > 0
        value = buffer.get_string
        if name == "__BODY__"
          @body = value
        elsif name.start_with?("HTTP_") || name == "CONTENT_LENGTH" || name == "CONTENT_TYPE"
          request[name] = request.key?(name) ? "#{request[name]}, #{value}" : value
        else
          request[name] = value
        end
        @field_index += 1
      end
      raise HttpParserError, "Invalid HTTP format, parsing fails. Are you trying to open an SSL connection to a non-SSL Puma?" if error?
      result
    end

    def body = @body
    def nread = SpinelParserNative.puma_spinel_parser_nread(@pointer)
    def error? = SpinelParserNative.puma_spinel_parser_error(@pointer)
    def finished? = SpinelParserNative.puma_spinel_parser_finished(@pointer)
    def finish = SpinelParserNative.puma_spinel_parser_finish(@pointer)

    def close
      SpinelParserNative.puma_spinel_parser_free(@pointer)
      @pointer = nil
    end
  end
end
