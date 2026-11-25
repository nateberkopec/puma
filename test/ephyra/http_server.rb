$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "puma"
require "puma/server"
require "puma/log_writer"
require "tempfile"
require "rack"
require "rack/lint"
require "puma/dsl"
require "uri"

class EachBody
  def initialize(parts)
    @parts = parts
  end

  def each(&block)
    @parts.each(&block)
  end
end

class PathBody < EachBody
  def initialize(parts, path)
    super(parts)
    @path = path
  end

  def to_path
    @path
  end
end

FILES = {}

def file_for(content)
  FILES[content] ||= begin
    file = Tempfile.new("puma-ephyra")
    file.binmode
    file.write content
    file.flush
    file
  end
end

def planned(plan)
  status, kind, count, size, length = plan.split(".").map(&:to_i)
  parts = Array.new(count) { |i| (i.even? ? "x" : "yz") * size }
  content = parts.join
  headers = {"content-type" => "text/plain"}
  headers["content-length"] = content.bytesize.to_s if length == 1
  body =
    case kind
    when 0 then parts
    when 1 then EachBody.new(parts)
    when 2 then File.open(file_for(content).path, "rb")
    else PathBody.new(parts, file_for(content).path)
    end
  [status, headers, body]
end

ENV_APP = Rack::Lint.new(lambda do |env|
  text = env.values_at("SERVER_PORT", "SERVER_NAME", "PATH_INFO", "QUERY_STRING").join("|")
  [200, {"content-type" => "text/plain"}, [text]]
end)

def hints(plan)
  count, array = plan.split(".").map(&:to_i)
  values = Array.new(count) { |i| "</#{i}.css>; rel=preload" }
  {"link" => array == 1 ? values : values.join("\n")}
end

SSL_KEYS = %i[ssl_cipher_filter ssl_ciphersuites cert key ca]

def ssl_params(header)
  values = header.split(".", -1).map { |hex| [hex].pack("H*").force_encoding("UTF-8") }
  opts = SSL_KEYS.zip(values).to_h.reject { |_, v| v.nil? || v.empty? }
  bind = Puma::DSL.ssl_bind_str("127.0.0.1", 9292, opts.merge(verify_mode: "peer"))
  params = Puma::Util.parse_query(URI.parse(bind).query)
  text = SSL_KEYS.map { |k| params[k.to_s].to_s.unpack1("H*") }.join(".")
  [200, {"content-type" => "text/plain"}, [text]]
rescue => e
  [200, {"content-type" => "text/plain"}, ["error #{e.class}"]]
end

def custom_header(env)
  key, value, kind = env["HTTP_X_HDR"].split(".", -1)
  key = [key].pack("H*").force_encoding("UTF-8")
  value = [value].pack("H*").force_encoding("UTF-8")
  value = [value, value] if kind == "1"
  env["rack.early_hints"].call(key => value)
  [200, {key => value}, ["hi"]]
end

def echo_headers(env)
  text = env.select { |k, _| k.start_with?("HTTP_X") && k != "HTTP_X_ECHO" }.sort.map { |k, v| "#{k}=#{v}" }.join(";")
  [200, {"content-type" => "text/plain"}, [text]]
end

app = lambda do |env|
  next planned(env["HTTP_X_PLAN"]) if env["HTTP_X_PLAN"]
  next custom_header(env) if env["HTTP_X_HDR"]
  next [200, {"content-length" => [env["HTTP_X_LEN"]]}, ["x" * env["HTTP_X_LEN"].to_i]] if env["HTTP_X_LEN"]
  next echo_headers(env) if env["HTTP_X_ECHO"]
  next ssl_params(env["HTTP_X_SSL"]) if env["HTTP_X_SSL"]
  next ENV_APP.call(env) if env["HTTP_X_ENV"]

  env["rack.early_hints"].call(hints(env["HTTP_X_HINTS"])) if env["HTTP_X_HINTS"]

  body = env["rack.input"].read
  text = [env["REQUEST_METHOD"], env["PATH_INFO"], env["QUERY_STRING"], body.unpack1("H*")].join("|")
  [200, {"content-type" => "text/plain"}, [text]]
end

options = {log_writer: Puma::LogWriter.strings, early_hints: true}
ARGV.each do |arg|
  key, value = arg.split("=", 2)
  options[key.to_sym] = Integer(value)
end
server = Puma::Server.new(app, nil, options)
server.add_tcp_listener "127.0.0.1", 0
server.run
puts server.connected_ports.first
$stdout.flush
$stdin.read
