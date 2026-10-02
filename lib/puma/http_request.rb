# frozen_string_literal: true

module Puma
  module HttpRequest
    include Const

    def validate_request_env!(env)
      return unless env[SERVER_PROTOCOL] == HTTP_11

      raise HttpParserError, "Missing Host header" unless env.key?(HTTP_HOST)
      raise HttpParserError, "Invalid Host header" if env[HTTP_HOST].empty?
    end
  end
end
