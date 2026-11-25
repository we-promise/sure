# Runs an MCP tool's AI work in the worker and hands the answer back through
# Ai::SharedState. The web thread polls instead of blocking on a Redis list,
# which would hold one of its Sidekiq connections for the whole wait.
class Ai::ToolJob < ApplicationJob
  queue_as { Ai::Routes.queue_for(feature_for(arguments.first)) }

  TIMEOUTS = { "search_family_files" => 30, "import_bank_statement" => 120 }.freeze
  BUSY_MESSAGES = {
    "search_family_files" => "Busy, try again.",
    "import_bank_statement" => "Still extracting; call again with the same pdf_import_id for the result."
  }.freeze
  RESULT_TTL = 2.minutes
  # Longer than the client's wait: a retry must find the running job before its
  # result expires, but nothing here outlives a worker for long.
  INFLIGHT_TTL = 10.minutes
  POLL_INTERVAL = 0.25
  # Each waiter holds a Puma thread, so cap them per web process.
  WAITING = Concurrent::Semaphore.new(2)

  class << self
    def timeout_for(fn_class) = TIMEOUTS.fetch(fn_class.name)

    def run(fn_class, user, arguments, timeout: timeout_for(fn_class))
      return busy_result(fn_class) if ai_queues_unpolled?
      return busy_result(fn_class) unless WAITING.try_acquire

      acquired = true
      inflight = inflight_key(fn_class, arguments)
      if inflight && (running_job_id = Ai::SharedState.read(inflight))
        return wait_for(running_job_id, fn_class, timeout)
      end

      job = new(fn_class.name, user, arguments)
      job.job_id = SecureRandom.uuid
      Ai::SharedState.write(inflight, job.job_id, expires_in: INFLIGHT_TTL) if inflight
      job.enqueue
      wait_for(job.job_id, fn_class, timeout)
    rescue StandardError => error
      # An enqueue failure is a tool failure, not a lost call the client can
      # safely retry: the tool may never have run.
      Rails.logger.error("[Ai::ToolJob] couldn't run #{fn_class.name}: #{error.class}")
      if inflight && job && Ai::SharedState.read(inflight) == job.job_id
        Ai::SharedState.delete(inflight)
      end
      { "success" => false, "error" => "The tool failed to run", "tool" => fn_class.name, "tool_error" => true }
    ensure
      WAITING.release if acquired
    end

    private
      def feature_for(function_name)
        Assistant.function_classes.find { _1.name == function_name }&.ai_feature ||
          raise(ArgumentError, "no such AI tool: #{function_name.inspect}")
      end

      def ai_queues_unpolled?
        SidekiqHealth.current.reason == :ai_queues_not_polled
      rescue StandardError => error
        Rails.logger.warn("[Ai::ToolJob] worker health check failed: #{error.class}")
        false
      end

      def busy_result(fn_class)
        { "success" => false, "error" => "busy", "message" => BUSY_MESSAGES.fetch(fn_class.name), "tool_error" => true }
      end

      # Only an import needs a retry to join a job already running: a search has
      # no lasting side effect, and its retry can wait for a fresh result.
      def inflight_key(fn_class, arguments)
        return unless fn_class.name == "import_bank_statement"

        "ai/tool_inflight/import_bank_statement:#{arguments["pdf_import_id"]}"
      end

      def wait_for(job_id, fn_class, timeout)
        key = "ai/tool_results/#{job_id}"
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

        loop do
          answer = Ai::SharedState.read(key)
          return answer["result"] if answer&.key?("result")
          return answer.merge("tool_error" => true) if answer&.key?("error")
          return busy_result(fn_class) if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep POLL_INTERVAL
        end
      end
  end

  def perform(function_name, user, arguments)
    fn_class = Assistant.function_classes(user).find { _1.name == function_name }
    return write(function_name, error: "Unknown tool") unless fn_class

    write(function_name, result: fn_class.new(user).call(arguments))
  rescue StandardError => error
    # The exception's text is written for logs, not for an external client:
    # a scoped RecordNotFound carries its SQL, and a provider can quote a
    # statement's account number. The correlation id ties the two together.
    Rails.logger.error("[Ai::ToolJob] #{function_name} failed: #{error.class} (correlation: #{Ai::CallContext.correlation_id})")
    Rails.logger.error(error.backtrace.first(10).join("\n")) if error.backtrace
    write(function_name, error: "The tool failed to run", tool: function_name)
  ensure
    clear_inflight(function_name, arguments)
  end

  private
    # The queue_as block runs on the instance; the lookup itself lives with the
    # class-level entry point so both paths name the feature the same way.
    def feature_for(function_name) = self.class.send(:feature_for, function_name)

    def write(function_name, answer)
      Ai::SharedState.write("ai/tool_results/#{job_id}", answer, expires_in: RESULT_TTL)
    end

    def clear_inflight(function_name, arguments)
      return unless function_name == "import_bank_statement"

      key = "ai/tool_inflight/import_bank_statement:#{arguments["pdf_import_id"]}"
      Ai::SharedState.delete(key) if Ai::SharedState.read(key) == job_id
    end
end
