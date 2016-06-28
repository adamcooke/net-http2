require 'socket'
require 'openssl'
require 'uri'
require 'http/2'

module NetHttp2

  DRAFT = 'h2'

  class Client
    attr_reader :uri

    def initialize(url, options={})
      @uri             = URI.parse(url)
      @connect_timeout = options[:connect_timeout] || 60
      @ssl_context     = add_npn_to_context(options[:ssl_context] || OpenSSL::SSL::SSLContext.new)

      @is_ssl = (@uri.scheme == 'https')

      init_vars
    end

    def call(method, path, options={})
      request = prepare_request(method, path, options)
      ensure_open
      new_stream.call_with request
    end

    def call_async(request)
      ensure_open
      new_stream.async_call_with request
    end

    def prepare_request(method, path, options={})
      NetHttp2::Request.new(method, @uri, path, options)
    end

    def ssl?
      @is_ssl
    end

    def close
      exit_thread(@socket_thread)
      init_vars
    end

    def join
      while !@streams.empty? do
        sleep 0.05
      end
    end

    def add_stream_to_monitor(stream)
      @streams[stream.id] = true
    end

    def mark_stream_as_closed(stream)
      @streams.delete(stream.id)
    end

    private

    def init_vars
      @h2              = nil
      @socket          = nil
      @socket_thread   = nil
      @first_data_sent = false
      @mutex           = Mutex.new
      @streams         = {}
    end

    def new_stream
      NetHttp2::Stream.new(client: self, h2_stream: h2.new_stream)
    end

    def ensure_open
      @mutex.synchronize do

        return if @socket_thread

        @socket = new_socket

        @socket_thread = Thread.new do

          begin
            socket_loop
          rescue Exception => e
            # socket closed
            Thread.main.raise e
          ensure
            @socket.close unless @socket.closed?
            @socket        = nil
            @socket_thread = nil
          end
        end
      end
    end

    def socket_loop

      ensure_sent_before_receiving

      loop do

        begin
          data_received = @socket.read_nonblock(1024)
          h2 << data_received
        rescue IO::WaitReadable
          IO.select([@socket])
          retry
        rescue IO::WaitWritable
          IO.select(nil, [@socket])
          retry
        end
      end
    end

    def new_socket
      NetHttp2::Socket.create(@uri, ssl: ssl?, ssl_context: @ssl_context, connect_timeout: @connect_timeout)
    end

    def ensure_sent_before_receiving
      while !@first_data_sent
        sleep 0.01
      end
    end

    def h2
      @h2 ||= HTTP2::Client.new.tap do |h2|
        h2.on(:frame) do |bytes|
          @mutex.synchronize do
            @socket.write(bytes)
            @socket.flush

            @first_data_sent = true
          end
        end
      end
    end

    def add_npn_to_context(ctx)
      ctx.npn_protocols = [DRAFT]
      ctx.npn_select_cb = lambda do |protocols|
        DRAFT if protocols.include?(DRAFT)
      end
      ctx
    end

    def exit_thread(thread)
      return unless thread
      thread.exit
      thread.join
    end
  end
end
