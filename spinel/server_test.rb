# frozen_string_literal: true

require 'open3'
require 'socket'
require 'timeout'

def request(port, data)
  TCPSocket.open('127.0.0.1', port) do |socket|
    socket.write(data)
    socket.close_write
    socket.read
  end
end

Open3.popen3(ARGV.fetch(0)) do |_stdin, stdout, stderr, process|
  port = Integer(stdout.gets)

  response = request(port, "GET /hello?q=1 HTTP/1.1\r\nHost: localhost\r\n\r\n")
  raise response unless response.start_with?("HTTP/1.1 200 OK\r\n") && response.end_with?('GET|/hello|q=1|')

  response = request(port, "GET /missing HTTP/1.0\r\n\r\n")
  raise response unless response.start_with?("HTTP/1.0 404 Not Found\r\n") && response.end_with?('GET|/missing||')

  response = request(port, "GET / HTTP/1.1\r\n\r\n")
  raise response unless response.start_with?('HTTP/1.1 400 Bad Request')

  response = request(port, "POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\nbody")
  raise response unless response.end_with?('POST|/upload||body')

  response = request(port, "GET /first HTTP/1.1\r\nHost: localhost\r\n\r\nGET /second HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  raise response unless response.scan('HTTP/1.1 200 ').length == 2 && response.include?('GET|/first||') && response.end_with?('GET|/second||')

  Timeout.timeout(2) do
    TCPSocket.open('127.0.0.1', port) do |socket|
      socket.write("POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\nExpect: 100-continue\r\n\r\n")
      raise 'missing 100 Continue' unless socket.gets == "HTTP/1.1 100 Continue\r\n" && socket.gets == "\r\n"
      socket.write('body')
      socket.close_write
      raise 'continued body missing' unless socket.read.end_with?('POST|/upload||body')
    end
  end

  response = request(port, "HEAD /head HTTP/1.1\r\nHost: localhost\r\n\r\n")
  raise response unless response.include?("content-length: 12\r\n") && response.end_with?("\r\n\r\n")

  response = request(port, "GET /no-content HTTP/1.1\r\nHost: localhost\r\n\r\n")
  raise response unless response.start_with?('HTTP/1.1 204 No Content') && response.end_with?("\r\n\r\n") && !response.include?('ignored')

  response = request(port, "GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n")
  raise response unless response.include?("connection: close\r\n") && response.end_with?("\r\n\r\nfirstsecond")

  response = request(port, "GET /chunked-response HTTP/1.1\r\nHost: localhost\r\n\r\n")
  raise response unless response.include?("transfer-encoding: chunked\r\n") && response.end_with?("\r\n\r\n5\r\nfirst\r\n6\r\nsecond\r\n0\r\n\r\n")

  response = request(port, "GET /chunked-response HTTP/1.1\r\nHost: localhost\r\n\r\nGET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  raise response unless response.scan('HTTP/1.1 200 OK').length == 2 && response.include?("0\r\n\r\nHTTP/1.1 200 OK") && response.end_with?('GET|/hello||')

  response = request(port, "POST /upload HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n2;ext=yes\r\nbo\r\n2\r\ndy\r\n0\r\nX-Trailer: ignored\r\n\r\n")
  raise response unless response.end_with?('POST|/upload||body')

  response = request(port, "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nabc\r\n0\r\n\r\n")
  raise response unless response.start_with?('HTTP/1.1 400 ')

  response = request(port, "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip\r\n\r\n")
  raise response unless response.start_with?('HTTP/1.1 501 ')

  response = request(port, "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 16777217\r\n\r\n")
  raise response unless response.start_with?('HTTP/1.1 413 ')

  idle = TCPSocket.open('127.0.0.1', port)
  status = Timeout.timeout(7) { process.value }
  idle.close
  raise stderr.read unless status.success?
  error_output = stderr.read
  raise error_output unless error_output.empty?
end

puts 'Spinel Puma server OK'
