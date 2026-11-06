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
  # A retry would delete the freshly re-imported data again.
  sidekiq_options retry: false

  ENQUEUE_GUARD_KEY = "market_data_reset_job:enqueued".freeze
  ENQUEUE_GUARD_TTL = 12.hours

  # Queues the reset unless one is already queued or running, so a second
  # click does not delete and re-import everything again. The guard lives in
  # Redis, which every web and worker process shares. Returns :queued,
  # :already_queued or :failed.
  def self.enqueue_once
    return :already_queued unless Sidekiq.redis { |conn| conn.call("SET", guard_key, "1", "NX", "EX", ENQUEUE_GUARD_TTL.to_i) }

    begin
      queued = perform_later
    rescue => e
      Rails.logger.error("MarketDataResetJob could not be queued: #{e.class}: #{e.message}")
    end
    return :queued if queued

    release_guard
    :failed
  end

  def self.guard_key
    ENQUEUE_GUARD_KEY
  end

  # The guard expires on its own, so a failure to release it only delays the
  # next reset.
  def self.release_guard
    Sidekiq.redis { |conn| conn.call("DEL", guard_key) }
  rescue => e
    Rails.logger.error("MarketDataResetJob could not release its enqueue guard: #{e.class}: #{e.message}")
  end

  # Only the run that holds the lock releases the guard; one that finds
  # another reset running leaves it to that run.
  def perform
    with_advisory_lock do
      reset_market_data
    ensure
      self.class.release_guard
    end
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

    # Only one reset runs at a time, also when two were queued.
    def with_advisory_lock
      lock_key = Digest::MD5.hexdigest(self.class.name).to_i(16) % (2**62)
      acquired = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_lock(?)", lock_key ])
      )

      unless acquired
        Rails.logger.warn("MarketDataResetJob skipped: another reset is running")
        return
      end

      begin
        yield
      ensure
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", lock_key ])
        )
      end
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
