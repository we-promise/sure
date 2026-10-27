# Server middleware counts execution attempts, including retries and failures.
class DailyJobUsageTracking
  def call(_worker, _job, _queue)
    Usage.capture("job_served_daily")
    yield
  end
end
