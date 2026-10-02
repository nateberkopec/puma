# frozen_string_literal: true

require_relative '../lib/puma/spinel_http_parser'

parser = Puma::HttpParser.new
request = {}
head = "POST /hello?q=1 HTTP/1.1\r\nHost: example.test\r\nX-Test: one\r\nX-Test: two\r\n\r\n"
data = head + "body"
split = 32

raise "partial request finished" if parser.execute(request, data[0, split], 0) == head.bytesize
raise "request did not finish" unless parser.execute(request, data, split) == head.bytesize
raise "parser state is wrong" unless parser.finished? && !parser.error?
raise "request method is wrong" unless request['REQUEST_METHOD'] == 'POST'
raise "request path is wrong" unless request['REQUEST_PATH'] == '/hello'
raise "query is wrong" unless request['QUERY_STRING'] == 'q=1'
raise "header normalization is wrong" unless request['HTTP_X_TEST'] == 'one, two'
raise "body is wrong" unless parser.body == 'body'

parser.reset
raise "reset did not clear the parser" unless parser.nread == 0
parser.close
puts "Spinel Puma parser OK"
