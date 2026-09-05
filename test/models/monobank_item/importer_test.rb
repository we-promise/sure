require "test_helper"

class MonobankItem::ImporterTest < ActiveSupport::TestCase
  MIDDAY_UNIX = 1_767_960_000

  class FakeMonobankProvider
    attr_reader :statement_calls, :client_info_calls

    def initialize(accounts: nil, jars: nil, statements: nil, statement_error: nil, statement_error_after: 0)
      @statement_calls = []
      @client_info_calls = 0
      @accounts = accounts
      @jars = jars
      @statements = statements
      @statement_error = statement_error
      # Lets a test fail only the backward window: the first N statement requests
      # succeed, everything after that raises.
      @statement_error_after = statement_error_after
    end

    def get_client_info
      @client_info_calls += 1

      {
        "clientId" => "client_1",
        "name" => "Іван Мазепа",
        "accounts" => @accounts || [ default_account ],
        "jars" => @jars || []
      }.with_indifferent_access
    end

    # Mirrors Provider::Monobank#get_accounts: cards and jars in one list, tagged by kind.
    def get_accounts(client_info: nil)
      payload = (client_info || get_client_info).with_indifferent_access

      Array(payload[:accounts]).map { |a| a.merge(kind: "card") } +
        Array(payload[:jars]).map { |j| j.merge(kind: "jar") }
    end

    def get_statement(account_id:, from:, to: nil)
      @statement_calls << { account_id: account_id, from: from, to: to }
      raise @statement_error if @statement_error && @statement_calls.count > @statement_error_after

      @statements || [ settled_transaction ]
    end

    private

      def default_account
        {
          "id" => "acc_1",
          "type" => "black",
          "balance" => 150_00,
          "creditLimit" => 100_00,
          "currencyCode" => 980,
          "maskedPan" => [ "537541******1234" ]
        }
      end

      def settled_transaction
        {
          "id" => "tx_1",
          "time" => MIDDAY_UNIX,
          "description" => "Сільпо",
          "mcc" => 5411,
          "hold" => false,
          "amount" => -4_000,
          "operationAmount" => -4_000,
          "currencyCode" => 980
        }
      end
  end

  setup do
    @family = families(:empty)
    @family.update!(timezone: "Europe/Kyiv")
    @monobank_item = MonobankItem.create!(family: @family, name: "Test Monobank", access_token: "mono-token")
    @monobank_account = MonobankAccount.create!(
      monobank_item: @monobank_item,
      name: "Old name",
      account_id: "acc_1",
      currency: "UAH"
    )
    @account = Account.create!(
      family: @family,
      name: "Card",
      accountable: Depository.new(subtype: "checking"),
      balance: 0,
      currency: "UAH"
    )
    AccountProvider.create!(account: @account, provider: @monobank_account)
  end

  test "imports the account snapshot and stores the statement" do
    provider = FakeMonobankProvider.new

    result = MonobankItem::Importer.new(@monobank_item, monobank_provider: provider).import

    assert result[:success]
    assert_equal 1, result[:accounts_updated]
    assert_equal 1, result[:transactions_imported]
    assert_equal 1, provider.client_info_calls, "client-info is fetched once per sync"

    @monobank_account.reload
    assert_equal "Black card ·1234", @monobank_account.name
    assert_equal BigDecimal("50"), @monobank_account.current_balance
    assert_equal [ "tx_1" ], @monobank_account.raw_transactions_payload.map { |tx| tx["id"] }
    assert_not_nil @monobank_account.statement_synced_through
    assert_not_nil @monobank_account.history_synced_from
  end

  test "does not persist the client's personal name" do
    MonobankItem::Importer.new(@monobank_item, monobank_provider: FakeMonobankProvider.new).import

    @monobank_item.reload
    assert_equal "client_1", @monobank_item.institution_id
    assert_nil @monobank_item.raw_payload["name"]
  end

  test "discovers jars as unlinked accounts awaiting setup" do
    provider = FakeMonobankProvider.new(
      jars: [ { "id" => "jar_1", "title" => "На тепловізор", "balance" => 5_000_00, "currencyCode" => 980, "goal" => 10_000_00 } ]
    )

    result = MonobankItem::Importer.new(@monobank_item, monobank_provider: provider).import

    assert_equal 1, result[:accounts_created]
    jar = @monobank_item.monobank_accounts.find_by(account_id: "jar_1")
    assert jar.jar?
    assert_includes @monobank_item.monobank_accounts.needs_setup, jar
  end

  # The forward window must always re-read the last few days so an unsettled hold stays
  # in the payload instead of being pruned as stale.
  test "forward window always re-covers the pending lookback period" do
    @monobank_account.update!(statement_synced_through: Time.current)
    provider = FakeMonobankProvider.new

    MonobankItem::Importer.new(@monobank_item, monobank_provider: provider).import

    call = provider.statement_calls.first
    lookback_days = Rails.configuration.x.monobank.pending_lookback_days
    assert_in_delta lookback_days, (Time.current - call[:from]) / 1.day, 0.1
  end

  test "walks older history backwards one window at a time" do
    @monobank_item.update!(sync_start_date: 120.days.ago.to_date)
    @monobank_account.update!(
      statement_synced_through: Time.current,
      history_synced_from: 60.days.ago.to_date
    )
    provider = FakeMonobankProvider.new

    MonobankItem::Importer.new(@monobank_item, monobank_provider: provider).import

    assert_equal 2, provider.statement_calls.count, "one forward window plus one history window"

    history_call = provider.statement_calls.last
    assert_equal 60.days.ago.to_date.in_time_zone, history_call[:to]
    assert_equal 60.days.ago.to_date.in_time_zone - Provider::Monobank::MAX_STATEMENT_WINDOW, history_call[:from]

    # The cursor records exactly what was requested, to the second: rounding it down to
    # a date would claim the untouched first 23 hours of that day as covered.
    @monobank_account.reload
    assert_equal history_call[:from], @monobank_account.history_synced_from
  end

  # Each backward step starts where the previous one stopped. Monobank's window is 31
  # days *plus an hour*, so a step rarely lands on midnight; a day-granular cursor left
  # a 23-hour hole at every boundary.
  test "consecutive history windows are contiguous" do
    @monobank_item.update!(sync_start_date: 200.days.ago.to_date)
    @monobank_account.update!(
      statement_synced_through: Time.current,
      history_synced_from: 60.days.ago.to_date
    )

    first = FakeMonobankProvider.new
    MonobankItem::Importer.new(@monobank_item, monobank_provider: first).import

    second = FakeMonobankProvider.new
    MonobankItem::Importer.new(@monobank_item, monobank_provider: second).import

    assert_equal first.statement_calls.last[:from], second.statement_calls.last[:to],
                 "the second window must resume exactly where the first one stopped"
  end

  # A window wider than Monobank's 31-day cap gets clamped, so the interval between the
  # old cursor and the clamped start is never requested. It has to be handed to the
  # backward walk instead of being reported as covered by both cursors.
  test "a clamped forward window hands the skipped interval to the history walk" do
    MonobankItem::Importer.stubs(:max_statement_requests_per_sync).returns(1)
    @monobank_item.update!(sync_start_date: 200.days.ago.to_date)
    @monobank_account.update!(
      statement_synced_through: 40.days.ago,
      history_synced_from: 200.days.ago.to_date
    )
    provider = FakeMonobankProvider.new

    MonobankItem::Importer.new(@monobank_item, monobank_provider: provider).import

    requested_from = provider.statement_calls.first[:from]
    assert_operator requested_from, :>, 40.days.ago, "the window was clamped to the 31 day cap"

    @monobank_account.reload
    assert_equal requested_from.floor(6), @monobank_account.history_synced_from,
                 "the interval the clamp skipped has to be re-walked from below"
  end

  test "stops backfilling once the configured start date is reached" do
    @monobank_item.update!(sync_start_date: 45.days.ago.to_date)
    @monobank_account.update!(
      statement_synced_through: Time.current,
      history_synced_from: 45.days.ago.to_date
    )
    provider = FakeMonobankProvider.new

    MonobankItem::Importer.new(@monobank_item, monobank_provider: provider).import

    assert_equal 1, provider.statement_calls.count, "history is already covered"
  end

  # Each statement request costs a minute of throttled waiting, so a sync spends a fixed
  # budget and leaves the rest for the next run.
  test "defers accounts that do not fit in the statement request budget" do
    second_account = MonobankAccount.create!(
      monobank_item: @monobank_item, name: "Second", account_id: "acc_2", currency: "UAH"
    )
    other = Account.create!(
      family: @family, name: "Second card",
      accountable: Depository.new(subtype: "checking"), balance: 0, currency: "UAH"
    )
    AccountProvider.create!(account: other, provider: second_account)

    MonobankItem::Importer.stubs(:max_statement_requests_per_sync).returns(1)
    provider = FakeMonobankProvider.new(
      accounts: [
        { "id" => "acc_1", "type" => "black", "balance" => 0, "currencyCode" => 980 },
        { "id" => "acc_2", "type" => "white", "balance" => 0, "currencyCode" => 980 }
      ]
    )

    result = MonobankItem::Importer.new(@monobank_item, monobank_provider: provider).import

    assert_equal 1, provider.statement_calls.count
    assert_equal 1, result[:accounts_skipped]
    assert result[:success], "a deferred account is not a failure"
  end

  # A statement response that hits Monobank's per-response item cap only covers part of
  # the window. Coverage that is still contiguous with what was already stored must not
  # throw away backfill progress.
  test "a truncated window keeps existing backfill progress when coverage stays contiguous" do
    MonobankItem::Importer.stubs(:max_statement_requests_per_sync).returns(1)
    @monobank_account.update!(
      statement_synced_through: 1.day.ago,
      history_synced_from: 100.days.ago.to_date
    )
    provider = FakeMonobankProvider.new(statements: full_page(oldest: 2.days.ago))

    MonobankItem::Importer.new(@monobank_item, monobank_provider: provider).import

    @monobank_account.reload
    assert_equal 100.days.ago.to_date.in_time_zone, @monobank_account.history_synced_from
  end

  test "a truncated window moves the history cursor up when it leaves a gap" do
    MonobankItem::Importer.stubs(:max_statement_requests_per_sync).returns(1)
    # Bound once: evaluating 10.days.ago separately for the fixture and the assertion
    # races the wall clock and disagrees by a second whenever the two calls straddle a
    # second boundary.
    oldest = 10.days.ago
    @monobank_item.update!(sync_start_date: 31.days.ago.to_date)
    provider = FakeMonobankProvider.new(statements: full_page(oldest: oldest))

    MonobankItem::Importer.new(@monobank_item, monobank_provider: provider).import

    @monobank_account.reload
    assert_equal Time.at(oldest.to_i), @monobank_account.history_synced_from,
                 "the gap below the oldest record received has to be re-walked, from its exact time"
  end

  test "treats a rate limit as a skip rather than a failure" do
    provider = FakeMonobankProvider.new(
      statement_error: Provider::Monobank::RateLimitError.new("throttled", failure_code: :rate_limited)
    )

    result = MonobankItem::Importer.new(@monobank_item, monobank_provider: provider).import

    assert result[:success]
    assert_equal 1, result[:accounts_skipped]
    assert_equal 0, result[:transactions_failed]
    @monobank_item.reload
    assert @monobank_item.good?, "throttling must not mark the connection as needing attention"
  end

  # fetch_window captures provider errors itself. What lands in the outer rescue is a
  # persistence failure, which used to increment a counter and leave nothing an operator
  # could find in /settings/debug.
  test "a failure while storing a statement is captured in the debug log" do
    provider = FakeMonobankProvider.new
    MonobankItem::Importer.any_instance.stubs(:store_transactions).raises(StandardError, "cursor would not save")

    result = nil
    assert_difference "DebugLogEntry.count", 1 do
      result = MonobankItem::Importer.new(@monobank_item, monobank_provider: provider).import
    end

    assert_equal 1, result[:transactions_failed]

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "monobank", entry.provider_key
    assert_equal @family, entry.family
    assert_equal @monobank_account.account_provider, entry.account_provider
    assert_equal "StandardError", entry.metadata["error_class"]
  end

  # An unauthorized response flips the connection to requires_update. If that update
  # fails, the connection keeps rendering as healthy, so the failure must reach
  # /settings/debug rather than only the application log.
  test "a failure while flagging the connection for re-authorization is captured in the debug log" do
    importer = MonobankItem::Importer.new(@monobank_item, monobank_provider: FakeMonobankProvider.new)
    @monobank_item.stubs(:update!).raises(ActiveRecord::RecordInvalid)

    assert_difference "DebugLogEntry.count", 1 do
      assert_nothing_raised { importer.send(:mark_requires_update!) }
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "monobank", entry.provider_key
    assert_equal @family, entry.family
    assert_equal "ActiveRecord::RecordInvalid", entry.metadata["error_class"]
  end

  test "a hard failure on the history window is reported rather than swallowed" do
    MonobankItem::Importer.stubs(:max_statement_requests_per_sync).returns(2)
    @monobank_item.update!(sync_start_date: 90.days.ago.to_date)
    @monobank_account.update!(history_synced_from: 40.days.ago)
    provider = FakeMonobankProvider.new(
      statement_error: Provider::Monobank::Error.new("boom", failure_code: :server_error),
      statement_error_after: 1
    )

    result = MonobankItem::Importer.new(@monobank_item, monobank_provider: provider).import

    assert_equal 2, provider.statement_calls.count, "the backward window must still be attempted"
    assert_equal 1, result[:transactions_failed],
                 "configured history was not fetched, so the sync cannot report success"
    assert_equal 0, result[:accounts_skipped], "a server error is not a soft skip"
  end

  test "a hard failure on the history window still persists the forward window" do
    MonobankItem::Importer.stubs(:max_statement_requests_per_sync).returns(2)
    @monobank_item.update!(sync_start_date: 90.days.ago.to_date)
    @monobank_account.update!(history_synced_from: 40.days.ago)
    provider = FakeMonobankProvider.new(
      statement_error: Provider::Monobank::Error.new("boom", failure_code: :server_error),
      statement_error_after: 1
    )

    MonobankItem::Importer.new(@monobank_item, monobank_provider: provider).import

    @monobank_account.reload
    assert @monobank_account.raw_transactions_payload.present?,
           "new activity already in hand must not be thrown away because the backfill failed"
  end

  test "a rate limit on the history window stays a success" do
    MonobankItem::Importer.stubs(:max_statement_requests_per_sync).returns(2)
    @monobank_item.update!(sync_start_date: 90.days.ago.to_date)
    @monobank_account.update!(history_synced_from: 40.days.ago)
    provider = FakeMonobankProvider.new(
      statement_error: Provider::Monobank::RateLimitError.new("throttled", failure_code: :rate_limited),
      statement_error_after: 1
    )

    result = MonobankItem::Importer.new(@monobank_item, monobank_provider: provider).import

    assert result[:success], "the backfill just resumes next sync, exactly as on budget exhaustion"
    assert_equal 0, result[:transactions_failed]
  end

  test "marks the connection as requiring update when the token is rejected" do
    provider = FakeMonobankProvider.new
    provider.stubs(:get_client_info).raises(
      Provider::Monobank::Error.new("Invalid Monobank access token", failure_code: :unauthorized)
    )

    result = MonobankItem::Importer.new(@monobank_item, monobank_provider: provider).import

    assert_not result[:success]
    assert @monobank_item.reload.requires_update?
  end

  test "keeps settled history but drops holds that disappear from the latest window" do
    hold = { "id" => "tx_hold", "time" => MIDDAY_UNIX, "description" => "Hold", "hold" => true, "amount" => -800, "operationAmount" => -800, "currencyCode" => 980 }
    settled = { "id" => "tx_settled", "time" => MIDDAY_UNIX, "description" => "Settled", "hold" => false, "amount" => -800, "operationAmount" => -800, "currencyCode" => 980 }

    MonobankItem::Importer.new(@monobank_item, monobank_provider: FakeMonobankProvider.new(statements: [ hold ])).import
    assert_equal [ "tx_hold" ], @monobank_account.reload.raw_transactions_payload.map { |tx| tx["id"] }

    MonobankItem::Importer.new(@monobank_item, monobank_provider: FakeMonobankProvider.new(statements: [ settled ])).import

    stored_ids = @monobank_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
    assert_equal [ "tx_settled" ], stored_ids, "the hold is gone, the settled record remains"
  end

  # A pre-authorization (hotel, car hire, fuel) can stay held for longer than the
  # pending lookback, so the window has to keep reaching back to it. Otherwise the hold
  # simply leaves the payload and its entry is pruned while the funds are still blocked.
  test "the forward window reaches back to the oldest hold still on file" do
    hold = held_transaction(id: "tx_hotel", at: 7.days.ago)
    @monobank_account.update!(
      raw_transactions_payload: [ hold ],
      statement_synced_through: 1.hour.ago,
      history_synced_from: 31.days.ago.to_date
    )
    # Monobank still reports the hold, because it is still unsettled.
    provider = FakeMonobankProvider.new(statements: [ hold ])

    MonobankItem::Importer.new(@monobank_item, monobank_provider: provider).import

    assert_operator provider.statement_calls.first[:from], :<=, Time.at(hold["time"]),
                    "the forward window must cover the oldest hold still stored"
    assert_equal [ "tx_hotel" ], @monobank_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
  end

  # A response at the item cap only accounts for its newest part, so a hold below that
  # point was not reported on because Monobank was never asked, not because it settled.
  test "keeps a hold the truncated response never reached" do
    hold = held_transaction(id: "tx_hotel", at: 5.days.ago)
    @monobank_account.update!(
      raw_transactions_payload: [ hold ],
      statement_synced_through: 1.hour.ago,
      history_synced_from: 31.days.ago.to_date
    )
    MonobankItem::Importer.stubs(:max_statement_requests_per_sync).returns(1)
    provider = FakeMonobankProvider.new(statements: full_page(oldest: 1.day.ago))

    MonobankItem::Importer.new(@monobank_item, monobank_provider: provider).import

    stored_ids = @monobank_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
    assert_includes stored_ids, "tx_hotel", "the hold is still blocking funds upstream"
  end

  # Monobank throttles client-info to one request per minute and the timer is per client
  # instance, so a manual sync landing in the same minute as a scheduled one collides
  # legitimately. That is a deferral, not a broken connection.
  test "treats a throttled client-info as a skip rather than a failure" do
    provider = FakeMonobankProvider.new
    provider.stubs(:get_client_info).raises(
      Provider::Monobank::RateLimitError.new("throttled", failure_code: :rate_limited)
    )

    result = MonobankItem::Importer.new(@monobank_item, monobank_provider: provider).import

    assert result[:success], "throttling must not fail the sync"
    assert_equal 1, result[:accounts_skipped]
    assert_equal 0, result[:accounts_failed]
    assert @monobank_item.reload.good?, "throttling must not mark the connection as needing attention"
  end

  private

    # An unsettled authorization at +at+.
    def held_transaction(id:, at:)
      {
        "id" => id,
        "time" => at.to_i,
        "description" => "Hotel",
        "hold" => true,
        "amount" => -50_000,
        "operationAmount" => -50_000,
        "currencyCode" => 980
      }
    end

    # A response at Monobank's per-response item cap, oldest record at +oldest+.
    def full_page(oldest:)
      Array.new(Provider::Monobank::MAX_STATEMENT_ITEMS) do |index|
        {
          "id" => "tx_page_#{index}",
          "time" => (oldest + index.minutes).to_i,
          "description" => "Purchase #{index}",
          "hold" => false,
          "amount" => -100,
          "operationAmount" => -100,
          "currencyCode" => 980
        }
      end
    end
end
