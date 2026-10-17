require "test_helper"
require "tmpdir"
require "timeout"

class FinecoBrowserLoginRuntimeRaceTest < ActiveSupport::TestCase
  Flow = Fineco::BrowserLoginRuntime::Flow
  IDENTITY = { family_id: "family-test", user_id: "user-test", session_id: "session-test" }.freeze
  SESSION = { gsessionid: "synthetic-session", account_index: "2", dossier_index: "5" }.freeze

  test "stop intent cancels a blocked capture and cleanup does not wait for the callback" do
    callback_started = Queue.new
    callback_release = Queue.new
    callback_cancelled = Queue.new
    callback = lambda do |identity:, session:, cancelled:|
      callback_started << [ identity, session ]
      callback_release.pop
      callback_cancelled << cancelled.call
      false
    end

    with_flow(callback) do |flow, profile_path, runtime_lock|
      capture_thread = Thread.new { flow.finish_capture(SESSION) }
      capture_thread.report_on_exception = false

      begin
        assert_equal [ IDENTITY, SESSION ], callback_started.pop
        result = Timeout.timeout(2) { flow.terminate!(:stopped) }

        assert_equal :stopping, result.fetch(:state)
        assert flow.cancellation_requested?
        assert runtime_lock.closed?
        refute File.exist?(profile_path)

        callback_release << true
        capture_result = Timeout.timeout(2) { capture_thread.value }
        assert_equal :stopped, capture_result.fetch(:state)
        assert callback_cancelled.pop
      ensure
        callback_release << true
        capture_thread.join(2)
      end
    end
  end

  test "a capture committed before stop intent remains captured after the callback returns" do
    callback_committed = Queue.new
    callback_started = Queue.new
    callback_release = Queue.new
    callback = lambda do |identity:, session:, cancelled:|
      callback_committed << true
      callback_started << [ identity, session ]
      callback_release.pop
      true
    end

    with_flow(callback) do |flow, _profile_path, _runtime_lock|
      capture_thread = Thread.new { flow.finish_capture(SESSION) }
      capture_thread.report_on_exception = false

      begin
        callback_committed.pop
        assert_equal [ IDENTITY, SESSION ], callback_started.pop
        stop_result = Timeout.timeout(2) { flow.terminate!(:stopped) }

        assert_equal :stopping, stop_result.fetch(:state)
        assert flow.cancellation_requested?

        callback_release << true
        capture_result = Timeout.timeout(2) { capture_thread.value }
        assert_equal :captured, capture_result.fetch(:state)
      ensure
        callback_release << true
        capture_thread.join(2)
      end
    end
  end

  private

    def with_flow(callback)
      Dir.mktmpdir("fineco-runtime-race-") do |directory|
        lock_path = File.join(directory, "runtime.lock")
        runtime_lock = File.open(lock_path, File::RDWR | File::CREAT, 0o600)
        runtime_lock.flock(File::LOCK_EX | File::LOCK_NB)
        profile_path = File.join(directory, "profile")
        Dir.mkdir(profile_path, 0o700)
        flow = Flow.new(
          id: "f" * 32,
          identity: IDENTITY,
          on_capture: callback,
          authorized: ->(identity) { identity == IDENTITY },
          capture_enabled: true,
          runtime_lock: runtime_lock
        )
        flow.instance_variable_set(:@profile, profile_path)
        flow.awaiting_login!
        assert flow.begin_capture

        yield flow, profile_path, runtime_lock
      ensure
        flow&.terminate!(:stopped)
        runtime_lock&.close unless runtime_lock&.closed?
      end
    end
end
