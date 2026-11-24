# Instance-wide counterpart to DataCacheClearJob, reserved for super admins.
#
# Exchange rates and security prices are shared by every family, so after
# deleting them we re-import everything the instance needs before the accounts
# rebuild. Otherwise parallel account syncs race to re-import the same pairs and
# other families see unconverted (1:1) totals until the next scheduled import.
#
# Only data the import fetches again is deleted: the windows MarketDataImporter
# requests, clamped to how far back each provider reaches. Prices and rates
# outside them (offline securities, providers without history, dates nothing
# needs) stay as they are.
class MarketDataResetJob < ApplicationJob
  queue_as :scheduled
  # A retry would delete the freshly re-imported data again. ApplicationJob's
  # deadlock retry stays: a deadlock can only come from the deletes, before
  # anything is imported.
  sidekiq_options retry: false

  ENQUEUE_GUARD_KEY = "market_data_reset_job:enqueued".freeze
  ENQUEUE_GUARD_TTL = 12.hours
  ADVISORY_LOCK_KEY = Digest::MD5.hexdigest(name).to_i(16) % (2**62)
  # Deletes the guard only while it still holds the caller's token, so a run
  # whose guard expired cannot release the guard of a reset queued later.
  RELEASE_GUARD_SCRIPT = <<~LUA.freeze
    if redis.call("GET", KEYS[1]) == ARGV[1] then return redis.call("DEL", KEYS[1]) else return 0 end
  LUA

  # Queues the reset unless one is already queued or running, so a second
  # click does not delete and re-import everything again. The guard lives in
  # Redis, which every web and worker process shares. Returns :queued,
  # :already_queued or :failed.
  def self.enqueue_once
    token = SecureRandom.uuid
    return :already_queued unless Sidekiq.redis { |conn| conn.call("SET", guard_key, token, "NX", "EX", ENQUEUE_GUARD_TTL.to_i) }

    return :queued if perform_later(token)

    release_guard(token)
    :failed
  rescue => e
    Rails.logger.error("MarketDataResetJob could not be queued: #{e.class}: #{e.message}")
    release_guard(token)
    :failed
  end

  def self.guard_key
    ENQUEUE_GUARD_KEY
  end

  # The guard expires on its own, so a failure to release it only delays the
  # next reset. Without a token (a job queued before guards had one, a run
  # from the console) the guard is released whoever set it.
  def self.release_guard(token)
    Sidekiq.redis do |conn|
      token ? conn.call("EVAL", RELEASE_GUARD_SCRIPT, 1, guard_key, token) : conn.call("DEL", guard_key)
    end
  rescue => e
    Rails.logger.error("MarketDataResetJob could not release its enqueue guard: #{e.class}: #{e.message}")
  end

  # The guard is released after the advisory lock, so a reset queued in
  # between always finds the lock free. A run that finds another reset running
  # leaves the guard to that run. A run Sidekiq requeues for a shutdown, or
  # that ApplicationJob retries after a deadlock, keeps it for the next
  # attempt, which carries the same token.
  def perform(guard_token = nil)
    release = with_advisory_lock { reset_market_data }
  rescue Sidekiq::Shutdown, ActiveRecord::Deadlocked
    release = false
    raise
  rescue
    release = true
    raise
  ensure
    self.class.release_guard(guard_token) if release
  end

  private
    def reset_market_data
      # clear_cache ignores the stored coverage of the old data, so the
      # provider is asked for the whole window again.
      importer = MarketDataImporter.new(mode: :full, clear_cache: true)
      price_windows = importer.required_security_price_windows
      rate_pairs = importer.required_exchange_rate_pairs

      delete_security_prices(price_windows)
      delete_exchange_rates(rate_pairs, end_date: importer.end_date)

      # Import each kind on its own so a failure in one still leaves the other
      # in place before the accounts rebuild.
      import_step(:security_prices) { importer.import_security_prices }
      import_step(:exchange_rates) { importer.import_exchange_rates }

      # Account syncs fetch any rates and prices still missing (also the
      # currencies of foreign security prices) and rebuild balances and
      # holdings. They are queued per account, not through the family syncs,
      # which skip the accounts of a connection whose provider fails.
      Account.find_each do |account|
        account.sync_later
      rescue => e
        Rails.logger.error("MarketDataResetJob failed to sync account #{account.id}: #{e.message}")
      end
    end

    def delete_security_prices(windows)
      Security.online.where(id: windows.keys).find_each do |security|
        provider = security.price_data_provider
        next unless provider

        window = windows.fetch(security.id)
        start_date = history_start(window.start_date, provider.max_history_days)
        next if start_date > window.end_date

        security.prices.where(date: start_date..window.end_date).delete_all
      end
    end

    def delete_exchange_rates(pairs, end_date:)
      provider = exchange_rate_provider
      return unless provider

      pairs.each do |pair|
        start_date = history_start(pair[:start_date], provider.max_history_days)
        next if start_date > end_date

        ExchangeRate.where(from_currency: pair[:source], to_currency: pair[:target], date: start_date..end_date).delete_all
      end
    end

    # A provider with a limited history (or none, like a latest-quote-only API)
    # cannot restore older rows, so those are kept.
    def history_start(start_date, max_history_days)
      return start_date if max_history_days.nil?

      [ start_date, Date.current - max_history_days.days ].max
    end

    def exchange_rate_provider
      ExchangeRate.provider
    rescue Provider::Registry::Error
      nil
    end

    # Only one reset runs at a time, also when two were queued. Returns false
    # when another reset holds the lock.
    def with_advisory_lock
      lock_key = ADVISORY_LOCK_KEY

      unless try_advisory_lock(lock_key)
        Rails.logger.warn("MarketDataResetJob skipped: another reset is running")
        return false
      end

      begin
        yield
        true
      ensure
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", lock_key ])
        )
      end
    end

    def try_advisory_lock(lock_key)
      ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_lock(?)", lock_key ])
      )
    end

    # A failed import must not stop the account syncs: they fetch any rates and
    # prices that are still missing.
    def import_step(step)
      yield
    rescue => e
      Rails.logger.error("MarketDataResetJob #{step} import failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      DebugLogEntry.capture(
        category: "market_data",
        level: "error",
        message: "Market data re-import after reset failed; continuing with account syncs",
        source: self.class.name,
        metadata: { step: step, error_class: e.class.name }
      )
    end
end
