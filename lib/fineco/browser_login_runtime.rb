# frozen_string_literal: true

require "fileutils"
require "net/http"
require "securerandom"
require "socket"
require "time"
require "timeout"

require_relative "browser_login_runtime/capture_observer"
require_relative "browser_login_runtime/security_profile"
require_relative "browser_login_runtime/web_socket_endpoint"
require_relative "browser_login_runtime/asset_endpoint"

module Fineco
  class BrowserLoginRuntime
    STATES = %i[starting awaiting_login setup_verification_required capturing stopping captured stopped expired failed rejected].freeze
    TERMINAL_STATES = %i[captured stopped expired failed rejected].freeze
    MAX_LIFETIME_SECONDS = 20 * 60
    AUTHORIZATION_CHECK_INTERVAL = 15
    DISPLAY = ":99"
    CHROME_DEBUGGING_PORT = 9222
    VNC_PORT = 5900
    RUNTIME_LOCK_PATH = "/tmp/fineco-browser-runtime.lock".freeze
    RUNTIME_LOCK_MODE = 0o600

    class Error < StandardError; end
    class Unavailable < Error; end
    class NotFound < Error; end

    class << self
      def start(identity:, on_capture:, authorized:, capture_enabled:)
        manager.start(identity: identity, on_capture: on_capture, authorized: authorized, capture_enabled: capture_enabled)
      end

      def status(identity:, id:, authorized:)
        manager.status(identity: identity, id: id, authorized: authorized)
      end

      def stop(identity:, id:, reason:, authorized:)
        manager.stop(identity: identity, id: id, reason: reason, authorized: authorized)
      end

      def open_rfb(identity:, id:, authorized:)
        manager.open_rfb(identity: identity, id: id, authorized: authorized)
      end

      def stream_authorized?(identity:, id:, authorized:)
        manager.stream_authorized?(identity: identity, id: id, authorized: authorized)
      end

      def authorization_lost(identity:, id:)
        manager.authorization_lost(identity: identity, id: id)
      end

      def attach_rfb_client(identity:, id:, authorized:, client_io:)
        manager.attach_rfb_client(identity: identity, id: id, authorized: authorized, client_io: client_io)
      end

      def release_rfb(identity:, id:, client_io: nil, backend: nil)
        manager.release_rfb(identity: identity, id: id, client_io: client_io, backend: backend)
      end

      def shutdown!
        @manager&.shutdown!
      end

      private

        def manager
          @manager ||= Manager.new
        end
    end

    at_exit { shutdown! }

    class Manager
      def initialize
        @mutex = Mutex.new
        @start_mutex = Mutex.new
        @flow = nil
      end

      def start(identity:, on_capture:, authorized:, capture_enabled:)
        normalized_identity = BrowserLoginRuntime.normalize_identity(identity)
        raise Unavailable unless capture_enabled == true || capture_enabled == false
        raise Unavailable unless BrowserLoginRuntime.runtime_configuration_available?
        raise Unavailable unless BrowserLoginRuntime.authorization_check(authorized, normalized_identity)
        raise Unavailable unless SecurityProfile.available?

        @start_mutex.synchronize do
          previous_flow = @mutex.synchronize { @flow }
          raise Unavailable if previous_flow&.active?

          raise Unavailable if previous_flow && !previous_flow.wait_for_cleanup
          runtime_lock = acquire_runtime_lock
          raise Unavailable unless runtime_lock

          flow = Flow.new(
            id: SecureRandom.hex(16),
            identity: normalized_identity,
            on_capture: on_capture,
            authorized: authorized,
            capture_enabled: capture_enabled,
            runtime_lock: runtime_lock
          )
          @mutex.synchronize do
            raise Unavailable if @flow&.active?

            @flow = flow
          end
          flow.start!
          flow.result
        rescue StandardError
          runtime_lock&.close unless flow&.runtime_lock == runtime_lock
          raise
        end
      end

      def status(identity:, id:, authorized:)
        flow = owned_flow(identity, id)
        unless BrowserLoginRuntime.authorization_check(authorized, flow.identity)
          flow.terminate!(:rejected)
          return flow.result
        end

        flow.result
      end

      def stop(identity:, id:, reason:, authorized:)
        flow = owned_flow(identity, id)
        unless BrowserLoginRuntime.authorization_check(authorized, flow.identity)
          flow.terminate!(:rejected)
          return flow.result
        end

        flow.terminate!(reason == :user_cancelled ? :stopped : :rejected)
        flow.result
      end

      def open_rfb(identity:, id:, authorized:)
        flow = owned_flow(identity, id)
        unless BrowserLoginRuntime.authorization_check(authorized, flow.identity)
          flow.terminate!(:rejected)
          return
        end

        flow.open_rfb
      end

      def attach_rfb_client(identity:, id:, authorized:, client_io:)
        flow = owned_flow(identity, id)
        return false unless BrowserLoginRuntime.authorization_check(authorized, flow.identity)

        flow.attach_rfb_client(client_io)
      rescue NotFound
        false
      end

      def stream_authorized?(identity:, id:, authorized:)
        flow = owned_flow(identity, id)
        return false unless flow.active? && !flow.cancellation_requested?

        BrowserLoginRuntime.authorization_check(authorized, flow.identity)
      rescue NotFound
        false
      end

      def authorization_lost(identity:, id:)
        flow = owned_flow(identity, id)
        flow.terminate!(:rejected)
      rescue NotFound
        nil
      end

      def release_rfb(identity:, id:, client_io: nil, backend: nil)
        flow = owned_flow(identity, id)
        flow.release_rfb(client_io: client_io, backend: backend)
      rescue NotFound
        nil
      end

      def shutdown!
        flow = @mutex.synchronize { @flow }
        flow&.terminate!(:stopped)
      end

      private

        def owned_flow(identity, id)
          normalized_identity = BrowserLoginRuntime.normalize_identity(identity)
          raise NotFound unless id.to_s.match?(/\A[a-f0-9]{32}\z/)

          flow = @mutex.synchronize { @flow }
          raise NotFound unless flow && flow.id == id && flow.owned_by?(normalized_identity)

          flow
        end

        def acquire_runtime_lock
          flags = File::RDWR | File::CREAT
          flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
          io = File.open(RUNTIME_LOCK_PATH, flags, RUNTIME_LOCK_MODE)
          stat = io.stat
          return io if stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero? && io.flock(File::LOCK_EX | File::LOCK_NB)

          io.close
          nil
        rescue SystemCallError
          io&.close
          nil
        end
    end

    class Flow
      attr_reader :id, :identity

      def initialize(id:, identity:, on_capture:, authorized:, capture_enabled:, runtime_lock:)
        @id = id.freeze
        @identity = identity
        @on_capture = on_capture
        @authorized = authorized
        @capture_enabled = capture_enabled
        @runtime_lock = runtime_lock
        @state = :starting
        @expires_at = Time.now.utc + MAX_LIFETIME_SECONDS
        @started_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @deadline_monotonic = @started_monotonic + MAX_LIFETIME_SECONDS
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @cleanup_mutex = Mutex.new
        @cleaned = false
        @profile = nil
        @supervisor_pid = nil
        @supervisor_exit_success = nil
        @supervisor_control = nil
        @child_pids = []
        @child_process_group = nil
        @callback_running = false
        @cancellation_requested = false
        @requested_terminal_state = nil
        @rfb_open = false
        @rfb_backend = nil
        @rfb_client_io = nil
        @observer_thread = nil
      end

      attr_reader :runtime_lock

      def start!
        @profile = File.join(SecurityProfile::SUPERVISOR_DIR, @id).freeze
        start_supervisor!
        wait_for_unix_socket("/tmp/.X11-unix/X99", 5)
        wait_for_tcp_port(VNC_PORT, 5)
        wait_for_debug_endpoint(10)
        if @capture_enabled
          @observer_thread = Thread.new { CaptureObserver.new(self).run }
        else
          awaiting_login!
          @observer_thread = Thread.new { monitor_diagnostic_flow }
        end
        @observer_thread.report_on_exception = false
        wait_until_ready(15)
      rescue StandardError
        terminate!(:failed)
      end

      def result
        @mutex.synchronize do
          { id: @id, state: @state, expires_at: @expires_at }.freeze
        end
      end

      def active?
        @mutex.synchronize { !TERMINAL_STATES.include?(@state) }
      end

      def wait_for_cleanup(timeout: 5)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          cleaned = @mutex.synchronize { @cleaned }
          return true if cleaned

          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if remaining <= 0

          @mutex.synchronize do
            unless @cleaned
              @condition.wait(@mutex, remaining)
            end
          end
        end
        cleanup! unless active?
        @mutex.synchronize { @cleaned }
      end

      def owned_by?(identity)
        @identity == identity
      end

      def current_state
        @mutex.synchronize { @state }
      end

      def expired?
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @deadline_monotonic
      end

      def cancellation_requested?
        @mutex.synchronize { @cancellation_requested }
      end

      def authorized?
        BrowserLoginRuntime.authorization_check(@authorized, @identity)
      end

      def capture_enabled?
        @capture_enabled
      end

      def processes_alive?
        supervisor_running?
      end

      def awaiting_login!
        @mutex.synchronize do
          return unless @state == :starting

          @state = @capture_enabled ? :awaiting_login : :setup_verification_required
          @condition.broadcast
        end
      end

      def wait_until_ready(timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        ready = @mutex.synchronize do
          while @state == :starting
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if remaining <= 0

            @condition.wait(@mutex, remaining)
          end
          @state != :starting
        end
        terminate!(:failed) unless ready
      end

      def begin_capture
        @mutex.synchronize do
          return false unless @capture_enabled && @state == :awaiting_login && !@cancellation_requested

          @state = :capturing
          true
        end
      end

      def finish_capture(session)
        should_call = @mutex.synchronize do
          if @state == :capturing && !@cancellation_requested
            @callback_running = true
            true
          else
            false
          end
        end
        return result unless should_call

        captured = false
        begin
          captured = authorized? && @on_capture.call(
            identity: @identity,
            session: session,
            cancelled: -> { cancellation_requested? || expired? }
          )
        rescue StandardError
          captured = false
        end
        authorized_after_callback = authorized?

        @mutex.synchronize do
          @callback_running = false
          @state = if captured
            :captured
          elsif @cancellation_requested
            @requested_terminal_state || :stopped
          elsif authorized_after_callback
            :failed
          else
            :rejected
          end
          @condition.broadcast
        end
        cleanup!
        result
      end

      def capture_retryable
        @mutex.synchronize do
          @state = :awaiting_login if @state == :capturing && !@cancellation_requested
          @condition.broadcast
        end
      end

      def terminate!(terminal_state)
        return unless TERMINAL_STATES.include?(terminal_state)

        changed = @mutex.synchronize do
          next false if TERMINAL_STATES.include?(@state) || @state == :stopping

          @cancellation_requested = terminal_state != :captured
          @requested_terminal_state = terminal_state
          @state = @callback_running ? :stopping : terminal_state
          @condition.broadcast
          true
        end
        return result unless changed

        close_rfb_connections
        cleanup!
        result
      end

      def open_rfb
        @mutex.synchronize do
          return unless %i[awaiting_login setup_verification_required].include?(@state) && !@cancellation_requested
          return if @rfb_open

          @rfb_open = true
        end
        socket = Socket.tcp("127.0.0.1", VNC_PORT, connect_timeout: 2)
        accepted = @mutex.synchronize do
          if %i[awaiting_login setup_verification_required].include?(@state) && !@cancellation_requested
            @rfb_backend = socket
            true
          else
            false
          end
        end
        return socket if accepted

        socket.close
        nil
      rescue StandardError
        @mutex.synchronize { @rfb_open = false }
        nil
      end

      def attach_rfb_client(client_io)
        @mutex.synchronize do
          return false unless %i[awaiting_login setup_verification_required].include?(@state) && @rfb_open && !@cancellation_requested

          @rfb_client_io = client_io
          true
        end
      end

      def release_rfb(client_io: nil, backend: nil)
        @mutex.synchronize do
          @rfb_client_io = nil if client_io.nil? || @rfb_client_io.equal?(client_io)
          @rfb_backend = nil if backend.nil? || @rfb_backend.equal?(backend)
          @rfb_open = false if @rfb_backend.nil?
        end
      end

      private

        def start_supervisor!
          control_reader, control_writer = IO.pipe
          status_reader, status_writer = IO.pipe
          spawn_options = {
            unsetenv_others: true,
            close_others: true,
            in: control_reader,
            out: status_writer,
            err: File::NULL
          }
          @supervisor_pid = Process.spawn(
            {},
            SecurityProfile::SUPERVISOR_PATH,
            @id,
            Process.pid.to_s,
            **spawn_options
          )
          @supervisor_control = control_writer
          control_writer = nil
          control_reader.close
          control_reader = nil
          status_writer.close
          status_writer = nil

          raise Error unless IO.select([ status_reader ], nil, nil, 50)

          message = status_reader.gets(128)
          match = message&.match(/\AREADY (\d+) (\d+) (\d+) (\d+) (\d+)\n\z/)
          raise Error unless match

          @child_pids = match.captures.first(4).map(&:to_i).freeze
          @child_process_group = match.captures.last.to_i
          raise Error unless @child_pids.all?(&:positive?) && @child_process_group.positive?
        ensure
          control_reader&.close unless control_reader&.closed?
          status_reader&.close unless status_reader&.closed?
          status_writer&.close unless status_writer&.closed?
          control_writer&.close unless control_writer&.closed?
        end

        def wait_for_unix_socket(path, timeout)
          wait_until(timeout) { File.socket?(path) }
        end

        def wait_for_tcp_port(port, timeout)
          wait_until(timeout) do
            socket = Socket.tcp("127.0.0.1", port, connect_timeout: 0.2)
            socket.close
            true
          rescue SystemCallError, IOError
            false
          end
        end

        def wait_for_debug_endpoint(timeout)
          wait_until(timeout) do
            response = local_http_get("/json/version", 1)
            response.is_a?(Net::HTTPSuccess) && response.body.bytesize <= 32_768
          rescue StandardError
            false
          end
        end

        def monitor_diagnostic_flow
          while active?
            return terminate!(:expired) if expired?
            return terminate!(:rejected) unless authorized?
            return terminate!(:failed) unless processes_alive?

            sleep 1
          end
        rescue StandardError
          terminate!(:failed) if active?
        end

        def wait_until(timeout)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          loop do
            raise Error unless processes_alive?
            return true if yield
            raise Error if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

            sleep 0.1
          end
        end

        def local_http_get(path, timeout)
          http = Net::HTTP.new("127.0.0.1", CHROME_DEBUGGING_PORT, nil)
          http.open_timeout = timeout
          http.read_timeout = timeout
          http.request(Net::HTTP::Get.new(path))
        end

        def cleanup!
          return false unless @cleanup_mutex.try_lock

          begin
            return true if @mutex.synchronize { @cleaned }

            close_rfb_connections
            control = @supervisor_control
            @supervisor_control = nil
            control&.close unless control&.closed?
            callback_running = @mutex.synchronize { @callback_running }
            unless callback_running
              @observer_thread&.join(1) if @observer_thread && @observer_thread != Thread.current
            end
            return false unless wait_for_supervisor_exit(5)

            cleanup_test_profile!
            @runtime_lock.close unless @runtime_lock.closed?
            @mutex.synchronize do
              @cleaned = true
              @condition.broadcast
            end
            true
          ensure
            @cleanup_mutex.unlock if @cleanup_mutex.owned?
          end
        rescue StandardError
          false
        end

        def close_rfb_connections
          sockets = @mutex.synchronize do
            [ @rfb_client_io, @rfb_backend ].compact.tap do
              @rfb_client_io = nil
              @rfb_backend = nil
              @rfb_open = false
            end
          end
          sockets.each { |socket| socket.close rescue nil }
        end

        def wait_for_supervisor_exit(timeout)
          pid, exit_success = @mutex.synchronize { [ @supervisor_pid, @supervisor_exit_success ] }
          return exit_success != false unless pid

          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
            unless supervisor_running?
              return @mutex.synchronize { @supervisor_exit_success == true }
            end

            sleep 0.05
          end
          return false if supervisor_running?

          @mutex.synchronize { @supervisor_exit_success == true }
        end

        def supervisor_running?
          @mutex.synchronize do
            return false unless @supervisor_pid

            begin
              waited, status = Process.waitpid2(@supervisor_pid, Process::WNOHANG)
              return true unless waited
              @supervisor_exit_success = status.success?
            rescue Errno::ECHILD
              @supervisor_exit_success = false
            end
            @supervisor_pid = nil
            @condition.broadcast
            false
          end
        end

        def cleanup_test_profile!
          return unless @profile&.start_with?("/tmp/fineco-runtime-race-")

          stat = File.lstat(@profile)
          return unless stat.directory? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o777) == 0o700

          FileUtils.remove_entry_secure(@profile)
        rescue SystemCallError
          nil
        end
    end

    class << self
      def normalize_identity(identity)
        values = identity.to_h.transform_keys(&:to_sym)
        keys = %i[family_id user_id session_id]
        raise Unavailable unless keys.all? { |key| values[key].to_s.match?(/\A[a-zA-Z0-9_-]{1,128}\z/) }

        keys.to_h { |key| [ key, values.fetch(key).to_s.freeze ] }.freeze
      rescue NoMethodError, TypeError
        raise Unavailable
      end

      def authorization_check(callback, identity)
        check = -> { !!callback.call(identity) }
        if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
          Rails.application.executor.wrap do
            ActiveRecord::Base.connection_pool.with_connection { check.call }
          end
        else
          check.call
        end
      rescue StandardError
        false
      end

      def runtime_configuration_available?
        return false unless ENV["FINECO_BROWSER_ENABLED"] == "true"

        workers = Integer(ENV.fetch("WEB_CONCURRENCY", ENV.fetch("PUMA_WORKERS", "1")))
        workers == 1
      rescue ArgumentError, TypeError
        false
      end
    end
  end
end
