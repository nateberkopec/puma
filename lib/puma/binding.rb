# frozen_string_literal: true

require 'socket'
require 'uri'

require_relative 'const'
require_relative 'util'

module Puma
  class Binding
    include Puma::Const

    class << self
      def parse(url, options = nil, log_writer = nil)
        uri = URI.parse url
        binding_class = [TCPBinding, UnixBinding, SSLBinding].find { |type| type.scheme == uri.scheme }
        binding_class&.from_uri(uri, url, options, log_writer) { yield }
      end

      def tcp(...) = TCPBinding.new(...)
      def unix(...) = UnixBinding.new(...)

      def ssl(host, port, context, optimize_for_latency = true, backlog = 1024, query = nil)
        ensure_ssl
        SSLBinding.new(host, port, context, optimize_for_latency, backlog, query)
      end

      def activate(fd)
        socket = TCPServer.for_fd fd
        [activation_key(socket), socket]
      end

      def activation_key(socket)
        path = Socket.unpack_sockaddr_un socket.getsockname
        path = "@#{path.delete_prefix("\0")}" if path.start_with?("\0")
        [:unix, path]
      rescue ArgumentError
        port, address = Socket.unpack_sockaddr_in socket.getsockname
        address = "[#{address}]" if address&.include? ':'
        [:tcp, address, port]
      end

      def activated_url(key, binds)
        protocol, address, port = key
        return "#{protocol}://#{address}" unless port

        tcp_url = "#{protocol}://#{address}:#{port}"
        ssl_url = "ssl://#{address}:#{port}"
        binds.find do |bind|
          bind == tcp_url || bind == ssl_url || bind.start_with?("#{ssl_url}?")
        end || tcp_url
      end

      def remove_unused_url(url)
        uri = URI.parse url
        File.unlink path_from_uri(uri) if uri.scheme == "unix" && !url.start_with?('unix://@')
      end

      def remove_unused_activation(key)
        File.unlink key[1] if key.first == :unix && !key[1].start_with?('@')
      end

      def build_ssl_context(params, options, log_writer)
        cert_key = %w[cert key]
        context = nil
        if params['cert'].to_s.empty? && params['key'].to_s.empty?
          context = yield
        end
        return context if context

        cert_key.each do |name|
          next unless params[name]&.start_with?('store:')
          index = Integer(params.delete(name).split('store:').last)
          params["#{name}_pem"] = options[:store][index]
        end
        MiniSSL::ContextBuilder.new(params, log_writer).context
      end

      def authority_context(authority, log_writer)
        return unless authority
        ensure_ssl

        key_path, cert_path = if [:key_path, :certificate_path].all? { |method| authority.respond_to?(method) }
          [authority.key_path, authority.certificate_path]
        else
          path = File.expand_path("~/.localhost")
          [File.join(path, "localhost.key"), File.join(path, "localhost.crt")]
        end
        MiniSSL::ContextBuilder.new({ "key" => key_path, "cert" => cert_path }, log_writer).context
      end

      def path_from_uri(uri) = "#{uri.host}#{uri.path}".gsub("%20", " ")

      private

      def ensure_ssl
        raise "Puma compiled without SSL support" unless defined?(Puma::HAS_SSL) && Puma::HAS_SSL
      end
    end

    attr_reader :env, :ios, :listener

    def initialize(activation_key, listener_class, env = nil, &decorator)
      @activation_key, @listener_class, @env = activation_key, listener_class, env
      @decorator = decorator
      @ios = []
    end

    def bind(url, inherited_fds, activated_sockets)
      @url = url
      if fd = inherited_fds.delete(url)
        @source = :inherited
        inherit fd
      elsif socket = activated_socket(activated_sockets)
        @source = :activated
        inherit socket
      else
        @source = :new
        add
      end
    end

    def inherit(fd)
      if RUBY_ENGINE == "spinel"
        raise NotImplementedError, "inherited listeners are unavailable on Spinel"
      else
        register fd.kind_of?(::TCPServer) ? fd : @listener_class.for_fd(fd)
      end
    end

    def log(log_writer, log_msg)
      return log_writer.log "* #{@source.capitalize} #{@url}" unless @source == :new
      @ios.each { |io| log_writer.log "* #{log_msg} on #{log_url(io)}" }
    end

    def listener_entry
      [@url, @listener] if @url && @listener
    end

    def freeze
      @env&.freeze
      @ios.freeze
      super
    end

    def close
      @ios.each { |io| io.close unless io.closed? }
    end

    def close_listener
      return unless @url && @listener
      @listener.close unless @listener.closed?
      File.unlink @path_to_unlink if @path_to_unlink && File.exist?(@path_to_unlink)
    rescue Errno::EBADF
    end

    protected

    def listen(server)
      server.listen @backlog
      register server
    end

    def register(server)
      @listener = server
      @ios << (@decorator ? @decorator.call(server) : server)
      server
    end

    def activated_socket(sockets) = sockets.delete(@activation_key)
    def log_url(_io) = @url
  end

  class TCPBinding < Binding
    attr_reader :host, :port

    def self.scheme = 'tcp'

    def self.from_uri(uri, _url, _options, _log_writer)
      params = Util.parse_query uri.query
      new uri.host, uri.port,
        params.key?('low_latency') && params['low_latency'] != 'false',
        params.fetch('backlog', 1024).to_i
    end

    def initialize(host, port, optimize_for_latency = true, backlog = 1024,
                   env: nil, log_scheme: "http", log_suffix: "", &decorator)
      super([:tcp, host, port], ::TCPServer, env, &decorator)
      @host, @port = host, port
      @optimize_for_latency, @backlog = optimize_for_latency, backlog
      @log_scheme, @log_suffix = log_scheme, log_suffix
    end

    def add
      return add_server(@host) unless @host == "localhost"
      loopback_addresses.each { |host| add_server host }
      @listener = nil
    end

    protected

    def add_server(host)
      host = host[1..-2] if host&.start_with? '['
      server = TCPServer.new(host, @port)
      server.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1) if @optimize_for_latency
      server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
      listen server
    end

    def log_url(io)
      socket = io.respond_to?(:to_io) ? io.to_io : io
      port = socket.addr[1]
      address = socket.addr[3]
      host_port = address.include?(':') ? "[#{address}]:#{port}" : "#{address}:#{port}"
      "#{@log_scheme}://#{host_port}#{@log_suffix}"
    end

    def loopback_addresses
      Socket.ip_address_list.filter_map do |address|
        address.ip_address if address.ipv6_loopback? || address.ipv4_loopback?
      end.uniq
    end
  end

  class UnixBinding < Binding
    def self.scheme = 'unix'

    def self.from_uri(uri, url, _options, _log_writer)
      params = Util.parse_query uri.query
      path = Binding.path_from_uri uri
      if url.start_with? 'unix://@'
        raise "OS does not support abstract UNIXSockets" unless Puma.abstract_unix_socket?
        path = "@#{path}"
      end
      new path, (Integer(params['umask']) if params['umask']),
        (Integer('0' + params['mode']) if params['mode']),
        (Integer(params['backlog']) if params['backlog']) || 1024
    end

    def initialize(path, umask = nil, mode = nil, backlog = 1024)
      super([:unix, path], ::UNIXServer, REMOTE_ADDR => "127.0.0.1")
      @path, @umask, @mode, @backlog = path, umask || 0, mode, backlog
      @path_to_unlink = path unless path.start_with?('@') || File.exist?(path)
    end

    def add
      old_mask = File.umask(@umask)
      if File.exist? @path
        begin
          old = UNIXSocket.new @path
        rescue SystemCallError, IOError
          File.unlink @path
        else
          old.close
          raise "There is already a server bound to: #{@path}"
        end
      end
      listen UNIXServer.new(@path.sub(/\A@/, "\0"))
    ensure
      File.umask old_mask
      File.chmod @mode, @path if @mode && @listener
    end

    protected

    def activated_socket(sockets)
      sockets.delete(@activation_key) ||
        !@path.start_with?('@') && sockets.delete([:unix, File.realdirpath(@path)])
    end
  end

  class SSLBinding < TCPBinding
    def self.scheme = 'ssl'

    def self.from_uri(uri, _url, options, log_writer)
      raise "Puma compiled without SSL support" unless Puma::HAS_SSL

      params = Util.parse_query uri.query
      context = Binding.build_ssl_context(params, options, log_writer) { yield }
      Binding.ssl uri.host, uri.port, context, params['low_latency'] != 'false',
        params.fetch('backlog', 1024).to_i, uri.query
    end

    def initialize(host, port, context, optimize_for_latency = true, backlog = 1024, query = nil)
      @context = context
      env = { Puma::Const::HTTPS_KEY => Puma::Const::HTTPS }
      super(host, port, optimize_for_latency, backlog,
        env: env, log_scheme: "ssl", log_suffix: "?#{query}") do |server|
        MiniSSL::Server.new server, @context
      end
    end
  end
end
