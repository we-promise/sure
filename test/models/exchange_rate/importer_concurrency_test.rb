require "test_helper"
require "timeout"

class ExchangeRate::ImporterConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "opposite currency imports acquire their rate rows in the same order" do
    date = Date.new(2001, 1, 1)
    held = Queue.new
    release = Queue.new
    second_pid = Queue.new
    workers = []
    provider = Object.new
    provider.define_singleton_method(:fetch_exchange_rates) do |from:, to:, **|
      row = Struct.new(:from, :to, :date, :rate).new(from, to, date, from == "XAA" ? 2 : 0.5)
      Provider::Response.new(success?: true, data: [ row ], error: nil)
    end

    ClimateControl.modify("EXCHANGE_RATE_PROVIDER" => "yahoo_finance") do
      [ [ "XAA", "XBB" ], [ "XBB", "XAA" ] ].each do |from, to|
        ExchangeRatePair.for_pair(from: from, to: to)
      end
      first = ExchangeRate::Importer.new(exchange_rate_provider: provider, from: "XAA", to: "XBB",
        start_date: date, end_date: date, clear_cache: true)
      original_upsert = first.method(:upsert_rows)
      paused = false
      first.define_singleton_method(:upsert_rows) do |rows|
        result = original_upsert.call(rows)
        unless paused
          paused = true
          held << true
          Timeout.timeout(10) { release.pop }
        end
        result
      end

      workers << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.execute("SET statement_timeout = '10s'")
          first.import_provider_rates
        ensure
          connection.execute("RESET statement_timeout")
        end
      end
      workers.last.report_on_exception = false
      Timeout.timeout(10) { held.pop }
      workers << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.execute("SET statement_timeout = '10s'")
          second_pid << connection.select_value("SELECT pg_backend_pid()").to_i
          ExchangeRate::Importer.new(exchange_rate_provider: provider, from: "XBB", to: "XAA",
            start_date: date, end_date: date, clear_cache: true).import_provider_rates
        ensure
          connection.execute("RESET statement_timeout")
        end
      end
      workers.last.report_on_exception = false
      pid = Timeout.timeout(10) { second_pid.pop }
      Timeout.timeout(10) do
        ActiveRecord::Base.uncached do
          sleep 0.01 until ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{pid}))").positive?
        end
      end
      release << true
      workers.each(&:value)

      assert_equal 2, ExchangeRate.where(from_currency: %w[XAA XBB], to_currency: %w[XAA XBB], date: date).count
      forward = ExchangeRate.find_by!(from_currency: "XAA", to_currency: "XBB", date: date)
      reverse = ExchangeRate.find_by!(from_currency: "XBB", to_currency: "XAA", date: date)
      assert_equal BigDecimal("2"), forward.rate
      assert_equal BigDecimal("1"), forward.rate * reverse.rate
    end
  ensure
    release << true
    workers.each do |worker|
      worker.kill if worker.alive?
      begin
        worker.join(12)
      rescue StandardError
        raise if worker.alive?
      end
      raise "Exchange rate worker did not stop" if worker.alive?
    end
    ExchangeRate.where(from_currency: %w[XAA XBB], to_currency: %w[XAA XBB]).delete_all
    ExchangeRatePair.where(from_currency: %w[XAA XBB], to_currency: %w[XAA XBB]).delete_all
  end
end
