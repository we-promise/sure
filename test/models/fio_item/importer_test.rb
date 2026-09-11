require "test_helper"

class FioItem::ImporterTest < ActiveSupport::TestCase
  PRAGUE_MIDNIGHT_MS = 1_781_474_400_000

  # Raises on its first N requests, then serves the statement. Enough to model both a
  # dead token (always raises) and a window Fio refuses until it is clamped.
  class FakeFioProvider
    attr_reader :calls

    def initialize(statement: nil, error: nil, failing_calls: Float::INFINITY)
      @calls = []
      @statement = statement
      @error = error
      @failing_calls = failing_calls
    end

    def get_statement(from:, to: Date.current)
      @calls << { from: from, to: to }
      raise @error if @error && @calls.size <= @failing_calls

      @statement || {}.with_indifferent_access
    end
  end

  setup do
    @family = families(:empty)
    @fio_item = FioItem.create!(family: @family, name: "Test Fio", token: "fio-token")
  end

  test "discovers the account from the statement header and stores its movements" do
    provider = FakeFioProvider.new(statement: statement(movements: [ movement(id: 1), movement(id: 2) ]))

    result = FioItem::Importer.new(@fio_item, fio_provider: provider).import

    assert result[:success]
    assert_equal 1, result[:accounts_created]
    assert_equal 2, result[:transactions_imported]

    account = @fio_item.fio_accounts.sole
    assert_equal "2400222222", account.fio_account_id
    assert_equal "CZK", account.currency
    assert_equal 195.01, account.current_balance
    assert_equal "CZ7920100000002400222222", account.iban
    assert_equal Date.current, account.transactions_synced_through
    assert_equal 2, account.raw_transactions_payload.size
  end

  # Discovery must not create a Sure account: which account a connection feeds, and
  # whether it feeds one at all, is the user's decision in setup.
  test "does not link the discovered account to a Sure account" do
    provider = FakeFioProvider.new(statement: statement(movements: [ movement(id: 1) ]))

    FioItem::Importer.new(@fio_item, fio_provider: provider).import

    assert_empty @fio_item.accounts
    assert_equal 1, @fio_item.fio_accounts.needs_setup.count
  end

  test "first sync of a new connection reaches back the configured history" do
    provider = FakeFioProvider.new(statement: statement)

    FioItem::Importer.new(@fio_item, fio_provider: provider).import

    assert_equal Date.current - Rails.configuration.x.fio.initial_history_days.days, provider.calls.sole[:from]
    assert_equal Date.current, provider.calls.sole[:to]
  end

  # Fio books a movement under its banking date, which can trail the day it appears, so
  # the window overlaps what was already covered instead of resuming after it.
  test "later syncs re-read an overlap before the last covered day" do
    account = fio_account(
      transactions_synced_through: Date.current - 2.days,
      history_synced_from: Date.current - 90.days
    )
    provider = FakeFioProvider.new(statement: statement)

    FioItem::Importer.new(@fio_item, fio_provider: provider).import

    expected_from = account.transactions_synced_through - Rails.configuration.x.fio.sync_lookback_days.days
    assert_equal expected_from, provider.calls.sole[:from]
  end

  test "never requests movements before the connection's start date" do
    @fio_item.update!(sync_start_date: Date.current - 3.days)
    provider = FakeFioProvider.new(statement: statement)

    FioItem::Importer.new(@fio_item, fio_provider: provider).import

    assert_equal Date.current - 3.days, provider.calls.sole[:from]
  end

  # The whole point of the start date is the initial backfill, so it has to be able to
  # reach further back than the default, not only trim it.
  test "reaches back to a start date older than the default history" do
    @fio_item.update!(sync_start_date: Date.current - 2.years)
    provider = FakeFioProvider.new(statement: statement)

    FioItem::Importer.new(@fio_item, fio_provider: provider).import

    assert_equal Date.current - 2.years, provider.calls.sole[:from]
  end

  # Once the requested range has actually been served there is nothing left to reach
  # back for, so the connection settles into small incremental windows.
  test "stops reaching back once the full range has been served" do
    @fio_item.update!(sync_start_date: Date.current - 2.years)
    provider = FakeFioProvider.new(statement: statement)

    FioItem::Importer.new(@fio_item, fio_provider: provider).import
    FioItem::Importer.new(@fio_item.reload, fio_provider: provider).import

    assert_equal Date.current - 2.years, provider.calls.first[:from]
    assert_equal(
      Date.current - Rails.configuration.x.fio.sync_lookback_days.days,
      provider.calls.last[:from]
    )
  end

  # A backfill Fio refused for want of an unlock must be retried, not silently
  # abandoned: the user unlocks their history and syncs again.
  test "asks for the full range again after a clamped backfill" do
    @fio_item.update!(sync_start_date: Date.current - 2.years)
    provider = FakeFioProvider.new(
      statement: statement(movements: [ movement(id: 1) ]),
      error: Provider::Fio::HistoryLockedError.new("422", failure_code: :history_locked),
      failing_calls: 1
    )

    FioItem::Importer.new(@fio_item, fio_provider: provider).import
    account = @fio_item.reload.fio_accounts.sole
    assert_equal Date.current - (Provider::Fio::UNAUTHORIZED_HISTORY_DAYS - 1).days,
                 account.history_synced_from

    FioItem::Importer.new(@fio_item, fio_provider: provider).import

    assert_equal Date.current - 2.years, provider.calls.last[:from]
  end

  test "merges fetched movements with the ones already stored" do
    account = fio_account(raw_transactions_payload: [ movement(id: 1) ])
    provider = FakeFioProvider.new(statement: statement(movements: [ movement(id: 2) ]))

    FioItem::Importer.new(@fio_item, fio_provider: provider).import

    stored_ids = account.reload.raw_transactions_payload.map { |m| FioEntry::Processor.canonical_external_id(m) }
    assert_equal %w[fio_1 fio_2], stored_ids.sort
  end

  test "a re-read movement replaces its stored copy instead of duplicating it" do
    account = fio_account(raw_transactions_payload: [ movement(id: 1, amount: -100.0) ])
    provider = FakeFioProvider.new(statement: statement(movements: [ movement(id: 1, amount: -120.0) ]))

    FioItem::Importer.new(@fio_item, fio_provider: provider).import

    stored = account.reload.raw_transactions_payload.sole
    assert_equal(-120.0, stored.dig("column1", "value"))
  end

  # One request per 30 seconds per token: a manual sync landing right after a scheduled
  # one collides legitimately. Nothing was fetched, so the cursor must not move, but the
  # connection is healthy and the next sync picks it up.
  test "a throttled request defers to the next sync without failing it" do
    account = fio_account(transactions_synced_through: Date.current - 5.days)
    provider = FakeFioProvider.new(error: Provider::Fio::RateLimitError.new("429", failure_code: :rate_limited))

    result = FioItem::Importer.new(@fio_item, fio_provider: provider).import

    assert result[:success]
    assert_equal 0, result[:transactions_imported]
    assert_equal Date.current - 5.days, account.reload.transactions_synced_through
    assert_equal "good", @fio_item.reload.status
  end

  # Fio serves 90 days without a temporary unlock in internet banking. Rather than
  # failing, take the part it will serve — the user can unlock and re-sync for the rest.
  test "clamps a window Fio refuses to the 90 days it serves unauthorized" do
    @fio_item.update!(sync_start_date: Date.current - 2.years)
    provider = FakeFioProvider.new(
      statement: statement(movements: [ movement(id: 1) ]),
      error: Provider::Fio::HistoryLockedError.new("422", failure_code: :history_locked),
      failing_calls: 1
    )

    result = FioItem::Importer.new(@fio_item, fio_provider: provider).import

    assert result[:success]
    assert_equal 1, result[:transactions_imported]
    assert_equal 2, provider.calls.size
    assert_equal Date.current - (Provider::Fio::UNAUTHORIZED_HISTORY_DAYS - 1).days, provider.calls.last[:from]
  end

  # The same refusal for a window already inside 90 days has no narrower retry to make.
  test "fails when Fio refuses a window it should have served" do
    fio_account(transactions_synced_through: Date.current - 1.day)
    provider = FakeFioProvider.new(error: Provider::Fio::HistoryLockedError.new("422", failure_code: :history_locked))

    result = FioItem::Importer.new(@fio_item, fio_provider: provider).import

    refute result[:success]
    assert_equal 1, provider.calls.size
  end

  test "flags the connection for a new token when Fio rejects it" do
    provider = FakeFioProvider.new(error: Provider::Fio::Error.new("500", failure_code: :unauthorized))

    result = FioItem::Importer.new(@fio_item, fio_provider: provider).import

    refute result[:success]
    assert_equal "requires_update", @fio_item.reload.status
  end

  test "reports a statement too large to fetch as a failure" do
    provider = FakeFioProvider.new(error: Provider::Fio::TooManyItemsError.new("413", failure_code: :too_many_items))

    result = FioItem::Importer.new(@fio_item, fio_provider: provider).import

    refute result[:success]
    assert result[:error].present?
  end

  # An empty body is all Fio returns for a quiet range, so a new connection whose first
  # window has no movements has nothing to describe an account with. Inventing one would
  # put a nameless, currency-less row in front of the user.
  test "does not invent an account when the first window comes back empty" do
    provider = FakeFioProvider.new(statement: {}.with_indifferent_access)

    result = FioItem::Importer.new(@fio_item, fio_provider: provider).import

    assert result[:success]
    assert_empty @fio_item.fio_accounts
  end

  # A quiet range on an established connection still has to advance the cursor, or every
  # later sync keeps re-reading from the same day.
  test "advances the cursor for a known account with no new movements" do
    account = fio_account(transactions_synced_through: Date.current - 10.days)
    provider = FakeFioProvider.new(statement: {}.with_indifferent_access)

    FioItem::Importer.new(@fio_item, fio_provider: provider).import

    assert_equal Date.current, account.reload.transactions_synced_through
  end

  private

    def fio_account(**attributes)
      FioAccount.create!(
        {
          fio_item: @fio_item,
          name: "Fio banka 2400222222",
          fio_account_id: "2400222222",
          currency: "CZK"
        }.merge(attributes)
      )
    end

    def statement(movements: [])
      {
        info: {
          accountId: "2400222222",
          bankId: "2010",
          currency: "CZK",
          iban: "CZ7920100000002400222222",
          bic: "FIOBCZPPXXX",
          closingBalance: 195.01
        },
        transactionList: { transaction: movements }
      }.with_indifferent_access
    end

    def movement(id:, amount: -100.0)
      {
        "column22" => { "value" => id, "id" => 22 },
        "column0" => { "value" => PRAGUE_MIDNIGHT_MS, "id" => 0 },
        "column1" => { "value" => amount, "id" => 1 },
        "column14" => { "value" => "CZK", "id" => 14 }
      }
    end
end
