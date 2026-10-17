# frozen_string_literal: true

require "json"
require "net/http"
require "timeout"
require "websocket/driver"

module Fineco
  class BrowserLoginRuntime
    class CdpConnection
      MAX_MESSAGE_BYTES = 4 * 1024 * 1024
      MAX_QUEUED_EVENTS = 200
      READ_CHUNK_BYTES = 64 * 1024
      WRITE_TIMEOUT_SECONDS = 5
      WRITE_CHUNK_BYTES = 64 * 1024

      class Error < StandardError; end

      class SocketAdapter
        attr_reader :url

        def initialize(socket, url)
          @socket = socket
          @url = url
        end

        def write(data)
          raise IOError unless data.is_a?(String) && data.bytesize <= MAX_MESSAGE_BYTES + 64

          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WRITE_TIMEOUT_SECONDS
          offset = 0
          while offset < data.bytesize
            begin
              chunk = data.byteslice(offset, WRITE_CHUNK_BYTES)
              offset += @socket.write_nonblock(chunk)
            rescue IO::WaitWritable
              remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              raise IOError if remaining <= 0 || !IO.select(nil, [ @socket ], nil, remaining)
            end
          end
        end
      end

      def initialize(target_url)
        @target_url = target_url
        @socket = nil
        @driver = nil
        @reader_thread = nil
        @events = SizedQueue.new(MAX_QUEUED_EVENTS)
        @pending = {}
        @pending_mutex = Mutex.new
        @write_mutex = Mutex.new
        @next_id = 0
        @closed = false
      end

      def connect(timeout: 5)
        uri = URI.parse(@target_url)
        raise Error unless uri.scheme == "ws" && uri.host == "127.0.0.1" && uri.port == CHROME_DEBUGGING_PORT
        valid_path = uri.path.start_with?("/devtools/page/") || uri.path.start_with?("/devtools/browser/")
        raise Error unless uri.userinfo.nil? && valid_path && uri.query.nil?

        @socket = Socket.tcp("127.0.0.1", CHROME_DEBUGGING_PORT, connect_timeout: timeout)
        adapter = SocketAdapter.new(@socket, @target_url)
        @driver = WebSocket::Driver.client(adapter, max_length: MAX_MESSAGE_BYTES)
        @driver.on(:message) { |event| receive_message(event.data) }
        @driver.on(:error) { |_event| close_socket }
        @driver.start
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        until @driver.state == :open
          raise Error if @closed || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          read_once(timeout: 0.5)
        end
        @reader_thread = Thread.new { read_loop }
        @reader_thread.report_on_exception = false
        self
      rescue StandardError
        close
        raise Error
      end

      def command(method, params = {}, timeout: 5, session_id: nil)
        raise Error if method.to_s.bytesize > 128 || @closed

        id = @pending_mutex.synchronize do
          @next_id += 1
          @pending[@next_id] = Queue.new
          @next_id
        end
        queue = @pending_mutex.synchronize { @pending.fetch(id) }
        command = { id: id, method: method, params: params }
        command[:sessionId] = session_id if session_id
        message = JSON.generate(command)
        raise Error if message.bytesize > 16 * 1024

        @write_mutex.synchronize { @driver.text(message) }
        response = Timeout.timeout(timeout) { queue.pop }
        raise Error if response.key?("error") || !response["result"].is_a?(Hash)

        response.fetch("result")
      rescue Timeout::Error, IOError, SystemCallError, JSON::GeneratorError
        raise Error
      ensure
        @pending_mutex.synchronize { @pending.delete(id) } if id
      end

      def next_event(timeout: 1)
        Timeout.timeout(timeout) { @events.pop }
      rescue Timeout::Error
        nil
      rescue ThreadError
        nil
      end

      def close
        @closed = true
        close_socket
        @reader_thread&.join(1) if @reader_thread && @reader_thread != Thread.current
        @reader_thread&.kill if @reader_thread&.alive? && @reader_thread != Thread.current
      end

      def closed?
        @closed
      end

      private

        def receive_message(data)
          raise Error if data.bytesize > MAX_MESSAGE_BYTES

          message = JSON.parse(data)
          if message.is_a?(Hash) && message.key?("id")
            queue = @pending_mutex.synchronize { @pending[message["id"]] }
            queue << message if queue
          elsif message.is_a?(Hash)
            @events.push(message, true)
          end
        rescue StandardError
          close_socket
        end

        def read_loop
          until @closed
            read_once(timeout: nil)
          end
        rescue EOFError, IOError, SystemCallError
          close_socket
        end

        def read_once(timeout:)
          if timeout
            ready = IO.select([ @socket ], nil, nil, timeout)
            raise Error unless ready
          end
          @driver.parse(@socket.readpartial(READ_CHUNK_BYTES))
        end

        def close_socket
          @closed = true
          @socket&.close
        rescue IOError
          nil
        end
    end
  end
end
