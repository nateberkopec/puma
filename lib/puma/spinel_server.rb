# frozen_string_literal: true

require 'socket'
require 'stringio'
require_relative 'const'
require_relative 'http_request'
require_relative 'io_buffer'
require_relative 'response'
require_relative 'spinel_http_parser'

module Puma
  # Single-process HTTP server for Spinel's currently supported socket API.
  class Server
    include Response
    include HttpRequest

    MAX_BODY = 16 * 1024 * 1024
    class BodyTooLarge < StandardError; end

    def initialize(app, _events = nil, options = {})
      @app = app
      @listener = nil
      @running = false
      @threads = []
      @max_threads = Integer(options[:max_threads] || 16)
      @max_keep_alive = Integer(options[:max_keep_alive] || 999)
      @queue_requests = true
      raise ArgumentError, "max_threads must be positive" if @max_threads <= 0
    end

    def add_tcp_listener(host, port, _optimize_for_latency = true, _backlog = 1024)
      raise ArgumentError, "Spinel supports one TCP listener" if @listener

      @listener = TCPServer.new(host, port)
    end

    def connected_ports
      [@listener.addr[1]] if @listener
    end

    def run(background = true, thread_name: 'srv')
      raise ArgumentError, "no TCP listener configured" unless @listener

      @running = true
      return serve unless background

      @thread = Thread.new { serve }
    end

    def stop(sync = false)
      @running = false
      @listener.close if @listener && !@listener.closed?
      @thread.join if sync && @thread
      @threads.each(&:join) if sync
    end

    private

    def serve
      while @running
        @threads.reject! { |thread| !thread.alive? }
        if @threads.length >= @max_threads
          sleep 0.01
          next
        end

        ready = IO.select([@listener], nil, nil, 0.1)
        next unless ready

        socket = @listener.accept
        @threads << Thread.new { handle_connection(socket, @listener) }
      end
    rescue IOError, Errno::EBADF
      raise if @running
    end

    def handle_connection(socket, listener)
      pending = +''
      parser = nil
      requests = 0
      loop do
        parser = HttpParser.new
        request = {}
        data = pending
        parsed = 0
        until parser.finished?
          data << read_socket(socket, 16_384) if parsed >= data.bytesize
          parsed = parser.execute(request, data, parsed)
        end
        validate_request_env!(request)

        pending = parser.body || +''
        transfer_encoding = request['HTTP_TRANSFER_ENCODING']
        if transfer_encoding
          if request['CONTENT_LENGTH']
            write_error(socket, 400)
            return
          end
          unless transfer_encoding.downcase.strip == 'chunked'
            write_error(socket, 501)
            return
          end
          write_continue(socket, request)
          body = read_chunked_body(socket, pending)
          request.delete('HTTP_TRANSFER_ENCODING')
          request['CONTENT_LENGTH'] = body.bytesize.to_s
        else
          length = Integer(request.fetch('CONTENT_LENGTH', '0'))
          if length < 0
            write_error(socket, 400)
            return
          end
          if length > MAX_BODY
            write_error(socket, 413)
            return
          end
          write_continue(socket, request)
          pending << read_socket(socket, length - pending.bytesize) while pending.bytesize < length
          body = pending.byteslice(0, length)
          pending = pending.byteslice(length, pending.bytesize - length) || +''
        end

        env = request.merge(
          'rack.version' => [1, 6],
          'rack.input' => StringIO.new(body),
          'rack.errors' => STDERR,
          'rack.multithread' => true,
          'rack.multiprocess' => false,
          'rack.run_once' => false,
          'rack.url_scheme' => 'http',
          'SERVER_SOFTWARE' => 'puma',
          'GATEWAY_INTERFACE' => 'CGI/1.2',
          'SCRIPT_NAME' => '',
          'PATH_INFO' => request['REQUEST_PATH'] || '/',
          'QUERY_STRING' => request['QUERY_STRING'] || '',
          'REMOTE_ADDR' => socket.peeraddr[3],
          'SERVER_NAME' => listener.addr[2],
          'SERVER_PORT' => listener.addr[1].to_s
        )
        status, headers, response_body = @app.call(env)
        requests += 1
        keep_alive = write_response(socket, env, status, headers, response_body, requests)
        parser.close
        parser = nil
        break unless keep_alive
      end
    rescue BodyTooLarge
      write_error(socket, 413)
    rescue HttpParserError, ArgumentError
      write_error(socket, 400)
    rescue EOFError, IOError, SystemCallError
      # The peer closed the connection.
    rescue StandardError => error
      STDERR.puts "Puma request error: #{error.message}"
      write_error(socket, 500)
    ensure
      parser&.close
      socket.close unless socket.closed?
    end

    def write_error(socket, status)
      socket.write("HTTP/1.1 #{status} #{fetch_status_code(status)}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
    end

    def write_continue(socket, request)
      socket.write("HTTP/1.1 100 Continue\r\n\r\n") if request['HTTP_EXPECT']&.downcase == '100-continue'
    end

    def write_response(socket, env, status, headers, response_body, requests)
      has_length = headers.any? do |name, value|
        name.to_s.downcase == 'content-length' && /\A\d+\z/.match?(value.to_s)
      end
      transfer_encoding = headers.find { |name, _value| name.to_s.downcase == 'transfer-encoding' }&.last
      raise "unsupported response transfer encoding: #{transfer_encoding}" if transfer_encoding && transfer_encoding.to_s.downcase != 'chunked'

      buffer = IOBuffer.new
      info = str_headers(env, status.to_i, headers, response_body, buffer,
        @running && requests < @max_keep_alive && (has_length || !!transfer_encoding || env['REQUEST_METHOD'] == 'HEAD' || status.to_i == 204 || status.to_i == 304))
      if info[:content_length] && status.to_i != 204
        buffer.append CONTENT_LENGTH_S, info[:content_length].to_s, LINE_END
      end
      buffer << LINE_END
      socket.write(buffer.read_and_reset)
      unless info[:no_body]
        response_body.each do |part|
          if transfer_encoding
            socket.write("#{part.bytesize.to_s(16)}\r\n#{part}\r\n") unless part.empty?
          else
            socket.write(part)
          end
        end
        socket.write(CLOSE_CHUNKED) if transfer_encoding
      end
      info[:keep_alive]
    ensure
      response_body.close if response_body.respond_to?(:close)
    end

    def read_chunked_body(socket, buffer)
      body = +''
      loop do
        line = read_chunk_line(socket, buffer)
        size = line.split(';', 2)[0]
        raise ArgumentError, 'invalid chunk size' unless size && /\A[0-9a-fA-F]+\z/.match?(size)

        length = size.to_i(16)
        raise BodyTooLarge if length > MAX_BODY - body.bytesize

        if length == 0
          trailer_bytes = 0
          loop do
            trailer = read_chunk_line(socket, buffer)
            trailer_bytes += trailer.bytesize + 2
            raise ArgumentError, 'trailers too large' if trailer_bytes > 8192
            break if trailer.empty?
          end
          return body
        end

        fill_chunk_buffer(socket, buffer, length + 2)
        raise ArgumentError, 'invalid chunk ending' unless buffer.byteslice(length, 2) == "\r\n"

        body << buffer.byteslice(0, length)
        buffer.slice!(0, length + 2)
      end
    rescue EOFError
      raise ArgumentError, 'incomplete chunked body'
    end

    def read_chunk_line(socket, buffer)
      until (ending = buffer.index("\r\n"))
        raise ArgumentError, 'chunk line too long' if buffer.bytesize > 8192
        buffer << read_socket(socket, 16_384)
      end
      raise ArgumentError, 'chunk line too long' if ending > 8192

      line = buffer.byteslice(0, ending)
      buffer.slice!(0, ending + 2)
      line
    end

    def fill_chunk_buffer(socket, buffer, length)
      buffer << read_socket(socket, 16_384) while buffer.bytesize < length
    end

    def read_socket(socket, length)
      loop do
        raise EOFError unless @running
        return socket.readpartial(length) if IO.select([socket], nil, nil, 0.1)
      end
    end
  end
end
