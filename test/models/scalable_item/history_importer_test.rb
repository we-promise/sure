require "test_helper"
require "digest"
require Rails.root.join("test/support/scalable_test_helper")

class ScalableItem::HistoryImporterTest < ActiveSupport::TestCase
  include ScalableTestHelper

  setup do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    Account.any_instance.stubs(:sync_later).returns(nil)
    @owner = scalable_owner
    @item = scalable_connected_item(owner: @owner)
    @provider_account, @account = create_native_account
  end

  test "imports all history idempotently without changing current cash or total" do
    activities = cash_activities

    assert_equal 4, importer.import(provider_account: @provider_account, normalized: result(activities))
    assert_equal 4, importer.import(provider_account: @provider_account, normalized: result(activities))

    entries = @account.entries.where(source: "scalable", entryable_type: "Transaction").order(:date).to_a
    assert_equal 4, entries.length
    assert_equal [ -1.to_d, -1.to_d, 1.to_d, -50.to_d ], entries.map(&:amount)
    assert_equal [ "funds_movement" ], entries.map { |entry| entry.transaction.kind }.uniq
    assert_equal [ "Transfer", "Transfer", "Withdrawal", "Transfer" ],
      entries.map { |entry| entry.transaction.investment_activity_label }
    assert_equal 51.to_d, @account.reload.cash_balance
    assert_equal 51.to_d, @account.balance
    assert_equal 51.to_d, @account.current_anchor_balance
    assert_equal 4, JSON.parse(@provider_account.reload.raw_metadata).dig("history", "count")
    assert_equal Date.new(2024, 7, 1).iso8601, JSON.parse(@provider_account.raw_metadata).dig("history", "first_date")
  end

  test "rejects a previously imported source id disappearing from complete history" do
    activities = cash_activities
    importer.import(provider_account: @provider_account, normalized: result(activities))

    error = assert_raises(Provider::Scalable::Error) do
      importer.import(provider_account: @provider_account, normalized: result(activities.drop(1)))
    end

    assert_equal "history_changed", error.code
    assert_equal 4, @account.entries.where(source: "scalable", entryable_type: "Transaction").count
  end

  test "older cash activity cannot imply securities values before the first observed holding" do
    importer.import(provider_account: @provider_account, normalized: result(cash_activities))
    add_current_security_snapshot

    balances = Balance::ReverseCalculator.new(@account.reload).calculate

    assert_equal [ Date.current ], balances.map(&:date)
    assert_equal Date.current, @account.history_start_date
    assert_equal Date.current, Balance::LinkedInvestmentSeriesNormalizer.send(:common_supported_history_start_date, [ @account.id ])
    assert_equal 0.to_d, balances.sole.net_market_flows
    assert_equal 4, @account.entries.where(source: "scalable", entryable_type: "Transaction").count
  end

  test "a deposit on the first securities snapshot day does not replace its observed value with zero" do
    importer.import(provider_account: @provider_account, normalized: result([ cash_activities.last ]))
    add_current_security_snapshot
    series = Series.new(
      start_date: Date.current, end_date: Date.current, interval: "1 day",
      values: [ Series::Value.new(date: Date.current, date_formatted: "", value: Money.new(61, "EUR")) ],
      favorable_direction: @account.favorable_direction
    )

    normalized = Balance::LinkedInvestmentSeriesNormalizer.new(account: @account, series: series).normalize

    assert_equal Money.new(61, "EUR"), normalized.values.sole.value
  end

  test "rejects invalid normalized rows before importing any part of the history" do
    activities = cash_activities
    invalid = activity(source_id: "wrong-currency", amount: "-1", type: "DEPOSIT", date: Date.current, currency: "USD")

    error = assert_raises(Provider::Scalable::Error) do
      importer.import(provider_account: @provider_account, normalized: result([ activities.first, invalid ]))
    end

    assert_equal "history_incomplete", error.code
    assert_equal 0, @account.entries.where(source: "scalable").count
    assert_equal 51.to_d, @account.reload.cash_balance
  end

  test "rejects duplicate normalized source ids" do
    activity = cash_activities.first

    error = assert_raises(Provider::Scalable::Error) do
      importer.import(provider_account: @provider_account, normalized: result([ activity, activity ]))
    end

    assert_equal "history_incomplete", error.code
    assert_equal 0, @account.entries.where(source: "scalable", entryable_type: "Transaction").count
  end

  test "rejects an activity id derived for another portfolio" do
    mismatched = activity(
      source_id: "foreign-portfolio-deposit",
      amount: "-1",
      type: "DEPOSIT",
      date: Date.current,
      portfolio_id: "another-portfolio"
    )

    error = assert_raises(Provider::Scalable::Error) do
      importer.import(provider_account: @provider_account, normalized: result([ mismatched ]))
    end

    assert_equal "history_incomplete", error.code
    assert_equal 0, @account.entries.where(source: "scalable", entryable_type: "Transaction").count
  end

  test "rolls back the batch when a source id collides with a different entry type" do
    activities = cash_activities.first(2)
    collision = activities.last
    @account.entries.create!(
      date: collision.date - 1.day,
      name: "Existing valuation",
      amount: 0,
      currency: "EUR",
      source: "scalable",
      external_id: collision.external_id,
      entryable: Valuation.new(kind: "reconciliation")
    )

    error = assert_raises(Provider::Scalable::Error) do
      importer.import(provider_account: @provider_account, normalized: result(activities))
    end

    assert_equal "account_conflict", error.code
    assert_nil @account.entries.find_by(source: "scalable", external_id: activities.first.external_id)
    assert @account.entries.find_by!(source: "scalable", external_id: collision.external_id).valuation?
  end

  test "preserves user-edited, import-locked, and excluded entries" do
    activities = cash_activities.first(3)
    importer.import(provider_account: @provider_account, normalized: result(activities))
    entries = @account.entries.where(source: "scalable", entryable_type: "Transaction").order(:date).to_a

    entries[0].update!(name: "My deposit", amount: -9)
    entries[0].mark_user_modified!
    entries[1].update!(name: "Locked deposit", amount: -8, import_locked: true)
    entries[2].update!(name: "Excluded withdrawal", amount: 7, excluded: true)

    importer.import(provider_account: @provider_account, normalized: result(activities))

    assert_equal [ "My deposit", "Locked deposit", "Excluded withdrawal" ], entries.map { |entry| entry.reload.name }
    assert_equal [ -9.to_d, -8.to_d, 7.to_d ], entries.map(&:amount)
    assert entries.first.user_modified?
    assert entries.second.import_locked?
    assert entries.third.excluded?
  end

  test "rejects imports when the connection generation changes after initialization" do
    stale_importer = importer
    @item.update!(connection_generation: @item.connection_generation + 1)

    error = assert_raises(Provider::Scalable::Error) do
      stale_importer.import(provider_account: @provider_account, normalized: result(cash_activities))
    end

    assert_equal "account_identity_changed", error.code
    assert_equal 0, @account.entries.where(source: "scalable", entryable_type: "Transaction").count
  end

  private

    def add_current_security_snapshot
      @provider_account.account_provider.holdings.create!(
        account: @account, security: securities(:aapl), date: Date.current, currency: "EUR",
        qty: 1, price: 10, amount: 10, external_id: "scalable-position-synthetic"
      )
      @account.set_current_balance(61, date: Date.current, schedule_sync: false)
      @account.update!(balance: 61, cash_balance: 51)
    end

    def importer
      ScalableItem::HistoryImporter.new(@item)
    end

    def result(activities)
      ScalableItem::HistoryNormalizer::Result.new(activities: activities)
    end

    def cash_activities
      [
        activity(source_id: "deposit-july-2024", amount: "-1", type: "DEPOSIT", date: Date.new(2024, 7, 1)),
        activity(source_id: "deposit-december-2025", amount: "-1", type: "DEPOSIT", date: Date.new(2025, 12, 6)),
        activity(source_id: "withdrawal-december-2025", amount: "1", type: "WITHDRAWAL", date: Date.new(2025, 12, 8)),
        activity(source_id: "deposit-today", amount: "-50", type: "DEPOSIT", date: Date.current, status: "CONFIRMED")
      ]
    end

    def activity(source_id:, amount:, type:, date:, currency: "EUR", status: "SETTLED", portfolio_id: @provider_account.uid)
      digest = Digest::SHA256.hexdigest(JSON.generate([ portfolio_id, source_id ]))
      ScalableItem::HistoryNormalizer::Activity.new(
        external_id: "#{ScalableItem::HistoryImporter::EXTERNAL_ID_PREFIX}#{digest}",
        date: date,
        amount: BigDecimal(amount),
        currency: currency,
        name: type == "DEPOSIT" ? "Scalable deposit" : "Scalable withdrawal",
        metadata: {
          "cash_transaction_type" => type,
          "source_id" => source_id,
          "status" => status
        }
      )
    end

    def create_native_account
      provider_account = @item.scalable_accounts.create!(
        uid: "broker-portfolio",
        name: ScalableAccount::BROKER_NAME,
        currency: ScalableAccount::BROKER_CURRENCY,
        kind: ScalableAccount::BROKER_KIND,
        current_balance: 51,
        cash_balance: 51,
        raw_metadata: JSON.generate(
          "portfolio_id" => "broker-portfolio",
          "account_id" => "broker-account",
          "person_identity" => @item.person_identity
        )
      )
      account = @owner.family.accounts.create!(
        accountable: Investment.new(subtype: "brokerage"),
        name: "Scalable Broker",
        balance: 51,
        cash_balance: 51,
        currency: "EUR",
        institution_name: "Scalable Capital",
        institution_domain: "scalable.capital",
        owner: @owner
      )
      AccountProvider.create!(account: account, provider: provider_account)
      account.set_current_balance(51, date: Date.current, schedule_sync: false)

      [ provider_account, account ]
    end
end
