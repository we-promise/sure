# frozen_string_literal: true

require "socket"
require "uri"
require "websocket/driver"

module Fineco
  class BrowserLoginRuntime
    class WebSocketEndpoint
      MAX_QUERY_BYTES = 256
      MAX_FRAME_BYTES = 8 * 1024 * 1024
      IO_CHUNK_BYTES = 64 * 1024
      WRITE_TIMEOUT_SECONDS = 2
      AUTHORIZATION_CHECK_INTERVAL = 15

      class ClientSocket
        attr_reader :env, :url

        def initialize(env, io)
          @env = env
          @io = io
          @url = "ws://127.0.0.1/fineco_login/stream"
        end

        def write(data)
          raise IOError unless data.is_a?(String) && data.bytesize <= MAX_FRAME_BYTES + 64

          write_nonblock_until(@io, data, WRITE_TIMEOUT_SECONDS)
        end

        private

          def write_nonblock_until(io, data, timeout)
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
            offset = 0
            while offset < data.bytesize
              begin
                chunk = data.byteslice(offset, IO_CHUNK_BYTES)
                offset += io.write_nonblock(chunk)
              rescue IO::WaitWritable
                remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
                raise IOError if remaining <= 0 || !IO.select(nil, [ io ], nil, remaining)
              end
            end
          end
      end

      def initialize(runtime:, identity_resolver:, authorized:, expected_origin:)
        @runtime = runtime
        @identity_resolver = identity_resolver
        @authorized = authorized
        @expected_origin = expected_origin
      end

      def call(env)
        return response(404) unless allowed_path?(env)
        return response(405) unless env["REQUEST_METHOD"] == "GET"
        return response(400) unless (id = requested_id(env))
        return response(403) unless valid_origin?(env)
        return response(426) unless WebSocket::Driver.websocket?(env)
        return response(501) unless env["rack.hijack"]

        identity = @identity_resolver.call(env)
        return response(403) unless identity && authorized?(identity)

        backend = @runtime.open_rfb(identity: identity, id: id, authorized: @authorized)
        return response(404) unless backend

        bridge(env, backend, identity, id)
      rescue StandardError
        response(403)
      end

      private

        def allowed_path?(env)
          %w[/ /fineco_login/stream].include?(env.fetch("PATH_INFO", ""))
        end

        def requested_id(env)
          query = env.fetch("QUERY_STRING", "")
          return if query.bytesize > MAX_QUERY_BYTES

          pairs = URI.decode_www_form(query)
          return unless pairs.length == 1 && pairs.first.first == "id"

          value = pairs.first.last
          value if value.match?(/\A[a-f0-9]{32}\z/)
        rescue ArgumentError, EncodingError
          nil
        end

        def valid_origin?(env)
          origin = env["HTTP_ORIGIN"]
          expected = @expected_origin.call(env)
          return false unless origin.is_a?(String) && expected.is_a?(String) && origin == expected
          return false if origin == "null"

          parsed = URI.parse(origin)
          %w[http https].include?(parsed.scheme) && parsed.host && !parsed.host.empty? && parsed.path.empty? && parsed.query.nil? && parsed.fragment.nil?
        rescue URI::InvalidURIError
          false
        end

        def authorized?(identity)
          BrowserLoginRuntime.authorization_check(@authorized, identity)
        end

        def bridge(env, backend, identity, id)
          hijack = env.fetch("rack.hijack")
          client_io = env["rack.hijack_io"] || hijack.call
          return response(403) unless @runtime.attach_rfb_client(
            identity: identity,
            id: id,
            authorized: @authorized,
            client_io: client_io
          )

          client = ClientSocket.new(env, client_io)
          driver = WebSocket::Driver.rack(client, protocols: [ "binary" ], max_length: MAX_FRAME_BYTES)
          driver.on(:message) do |event|
            if event.data.bytesize > MAX_FRAME_BYTES
              driver.close("frame too large", 1009)
            else
              write_nonblock_until(backend, event.data, WRITE_TIMEOUT_SECONDS)
            end
          end
          driver.on(:error) { |_event| nil }
          driver.start

          last_authorization_check = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          loop do
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if now - last_authorization_check >= AUTHORIZATION_CHECK_INTERVAL
              unless @runtime.stream_authorized?(identity: identity, id: id, authorized: @authorized)
                @runtime.authorization_lost(identity: identity, id: id)
                break
              end
              last_authorization_check = now
            end

            readable = IO.select([ client_io, backend ], nil, nil, 1)&.first || []
            if readable.include?(client_io)
              driver.parse(client_io.readpartial(IO_CHUNK_BYTES))
              break if driver.state == :closed
            end
            if readable.include?(backend)
              data = backend.readpartial(IO_CHUNK_BYTES)
              driver.binary(data)
            end
          end
          [ 200, {}, [] ]
        rescue EOFError, IOError, SystemCallError, WebSocket::Driver::ProtocolError
          [ 200, {}, [] ]
        ensure
          backend&.close
          client_io&.close
          @runtime.release_rfb(identity: identity, id: id, client_io: client_io, backend: backend) if identity && id
        end

        def write_nonblock_until(io, data, timeout)
          raise IOError unless data.is_a?(String) && data.bytesize <= MAX_FRAME_BYTES

          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          offset = 0
          while offset < data.bytesize
            begin
              chunk = data.byteslice(offset, IO_CHUNK_BYTES)
              offset += io.write_nonblock(chunk)
            rescue IO::WaitWritable
              remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              raise IOError if remaining <= 0 || !IO.select(nil, [ io ], nil, remaining)
            end
          end
        end

        def response(status)
          [ status, { "Content-Length" => "0", "Cache-Control" => "no-store" }, [] ]
        end
    end
  end
end
