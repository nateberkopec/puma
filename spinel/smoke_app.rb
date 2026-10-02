# frozen_string_literal: true

SMOKE_APP = lambda do |env|
  text = [env['REQUEST_METHOD'], env['PATH_INFO'], env['QUERY_STRING'], env['rack.input'].read].join('|')
  case env['PATH_INFO']
  when '/no-content'
    next [204, { 'content-type' => 'text/plain' }, ['ignored']]
  when '/stream'
    next [200, { 'content-type' => 'text/plain' }, ['first', 'second']]
  when '/chunked-response'
    next [200, { 'transfer-encoding' => 'chunked' }, ['first', '', 'second']]
  end
  status = env['PATH_INFO'] == '/missing' ? 404 : 200
  [status, { 'content-type' => 'text/plain', 'content-length' => text.bytesize.to_s }, [text]]
end
