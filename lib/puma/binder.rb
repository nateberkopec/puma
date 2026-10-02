# frozen_string_literal: true

require_relative 'binding'

module Puma
  class Binder
    include Puma::Const

    RACK_VERSION = [1,6].freeze

    def initialize(log_writer, options, env: nil)
      @log_writer = log_writer
      @options = options
      @bindings = []
      @inherited_fds = {}
      @activated_sockets = {}
      @env = env

      @proto_env = {
        "rack.version".freeze => RACK_VERSION,
        "rack.errors".freeze => log_writer.stderr,
        "rack.multithread".freeze => options[:max_threads] > 1,
        "rack.multiprocess".freeze => options[:workers] >= 1,
        "rack.run_once".freeze => false,
        RACK_URL_SCHEME => options[:rack_url_scheme],
        "SCRIPT_NAME".freeze => (env ? env['SCRIPT_NAME'] : ENV['SCRIPT_NAME']) || "",

        # I'd like to set a default CONTENT_TYPE here but some things
        # depend on their not being a default set and inferring
        # it from the content. And so if i set it here, it won't
        # infer properly.

        "QUERY_STRING".freeze => "",
        SERVER_SOFTWARE => PUMA_SERVER_STRING,
        GATEWAY_INTERFACE => CGI_VER,

        RACK_AFTER_REPLY => nil,
        RACK_RESPONSE_FINISHED => nil,
      }

      @envs = {}
    end

    # @version 5.0.0
    attr_reader :activated_sockets, :inherited_fds, :proto_env

    def ios = @bindings.flat_map(&:ios)
    def listeners = @bindings.filter_map(&:listener_entry)

    def env(sock)
      @envs.fetch(sock, @proto_env)
    end

    def close
      @bindings.each(&:close)
    end

    # @!attribute [r] connected_ports
    # @version 5.0.0
    def connected_ports
      t = ios.map { |io| io.addr[1] }; t.uniq!; t
    end

    # @version 5.0.0
    def create_inherited_fds(env_hash)
      env_hash.select {|k,v| k =~ /PUMA_INHERIT_\d+/}.each do |_k, v|
        fd, url = v.split(":", 2)
        @inherited_fds[url] = fd.to_i
      end.keys # pass keys back for removal
    end

    # systemd socket activation.
    # LISTEN_FDS = number of listening sockets. e.g. 2 means accept on 2 sockets w/descriptors 3 and 4.
    # LISTEN_PID = PID of the service process, aka us
    # @see https://www.freedesktop.org/software/systemd/man/systemd-socket-activate.html
    # @version 5.0.0
    #
    def create_activated_fds(env_hash)
      @log_writer.debug { "ENV['LISTEN_FDS'] #{(@env ? @env['LISTEN_FDS'] : ENV['LISTEN_FDS']).inspect}  env_hash['LISTEN_PID'] #{env_hash['LISTEN_PID'].inspect}" }
      return [] unless env_hash['LISTEN_FDS'] && env_hash['LISTEN_PID'].to_i == $$
      env_hash['LISTEN_FDS'].to_i.times do |index|
        key, sock = Binding.activate socket_activation_fd(index)
        @activated_sockets[key] = sock
        @log_writer.debug { "Registered #{key.join ':'} for activation from LISTEN_FDS" }
      end
      ["LISTEN_FDS", "LISTEN_PID"] # Signal to remove these keys from ENV
    end

    # Synthesize binds from systemd socket activation
    #
    # When systemd socket activation is enabled, it can be tedious to keep the
    # binds in sync. This method can synthesize any binds based on the received
    # activated sockets. Any existing matching binds will be respected.
    #
    # When only_matching is true in, all binds that do not match an activated
    # socket is removed in place.
    #
    # It's a noop if no activated sockets were received.
    def synthesize_binds_from_activated_fs(binds, only_matching)
      return binds unless activated_sockets.any?

      activated_binds = activated_sockets.keys.map { |key| Binding.activated_url key, binds }

      return activated_binds if only_matching

      binds | activated_binds
    end

    def before_parse(&block)
      @before_parse ||= []
      @before_parse << block if block
      @before_parse
    end

    def parse(binds, log_writer = nil, log_msg = 'Listening')
      before_parse.each(&:call)
      log_writer ||= @log_writer
      binds.each do |str|
        binding = Binding.parse(str, @options, @log_writer) { localhost_authority_context }
        unless binding
          log_writer.error "Invalid URI: #{str}"
          next
        end
        acquire(binding) { |item| item.bind str, @inherited_fds, @activated_sockets }
        binding.log log_writer, log_msg
      end
      close_unused_inherited log_writer
      close_unused_activated log_writer
    end

    def localhost_authority
      @localhost_authority ||= Localhost::Authority.fetch if defined?(Localhost::Authority) && !Puma::IS_JRUBY
    end

    def localhost_authority_context
      Binding.authority_context localhost_authority, @log_writer
    end

    def add(binding)
      acquire(binding, &:add)
    end

    def close_listeners
      @bindings.each(&:close_listener)
    end

    def redirects_for_restart
      redirects = listeners.map { |a| [a[1].to_i, a[1].to_i] }.to_h
      redirects[:close_others] = true
      redirects
    end

    # @version 5.0.0
    def redirects_for_restart_env
      listeners.each_with_object({}).with_index do |(listen, memo), i|
        memo["PUMA_INHERIT_#{i}"] = "#{listen[1].to_i}:#{listen[0]}"
      end
    end

    private

    def acquire(binding)
      yield binding
      binding.listener
    ensure
      register_binding binding
    end

    def register_binding(binding)
      binding.freeze
      @bindings << binding
      return unless additions = binding.env
      binding.ios.each { |io| @envs[io] = @proto_env.merge additions }
    end

    def close_unused_inherited(log_writer)
      @inherited_fds.each do |url, fd|
        log_writer.log "* Closing unused inherited connection: #{url}"
        close_quietly fd
        Binding.remove_unused_url url
      end
    end

    def close_unused_activated(log_writer)
      return if @activated_sockets.empty?
      used_fds = ios.map { |io| io.to_io.to_i }
      @activated_sockets.each do |key, socket|
        next if used_fds.include? socket.to_i
        log_writer.log "* Closing unused activated socket: #{Binding.activated_url key, []}"
        close_quietly socket
        Binding.remove_unused_activation key
      end
    end

    def close_quietly(io)
      io = IO.for_fd(io) if Integer === io
      io.close
    rescue SystemCallError
    end

    # @version 5.0.0
    def socket_activation_fd(int)
      int + 3 # 3 is the magic number you add to follow the SA protocol
    end
  end
end
