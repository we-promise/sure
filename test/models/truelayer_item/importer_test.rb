require "test_helper"

class TruelayerItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @item = TruelayerItem.create!(
      family: @family, name: "Acme Bank", client_id: "sure-test", client_secret: "secret",
      access_token: "token", refresh_token: "refresh", access_token_expires_at: 1.hour.from_now,
      last_authorized_at: 1.day.ago
    )
    @provider = mock("truelayer")
    @item.stubs(:truelayer_provider).returns(@provider)
    @provider.stubs(:get_me).returns({})
  end

  test "stores new accounts and cards unlinked" do
    @provider.expects(:get_accounts).returns([ account_snapshot("a1", "EVERYDAY ACCOUNT") ])
    @provider.expects(:get_cards).returns([ account_snapshot("c1", "REWARDS CARD").merge(partial_card_number: "4242") ])
    @provider.expects(:get_transactions).never

    result = TruelayerItem::Importer.new(@item).import

    assert result[:success]
    assert_equal 2, result[:accounts_created]
    card = @item.truelayer_accounts.find_by(account_id: "c1")
    assert card.card?
    assert_equal "Acme Bank - REWARDS CARD ••4242", card.name
  end

  test "fetches transactions and balance for linked accounts within the unattended window" do
    linked = link(@item.truelayer_accounts.create!(account_id: "a1", name: "Acc", currency: "GBP"))
    @item.truelayer_accounts.create!(account_id: "a2", name: "Unlinked", currency: "GBP")
    @provider.stubs(:get_accounts).returns([ account_snapshot("a1", "Acc"), account_snapshot("a2", "Unlinked") ])
    @provider.stubs(:get_cards).returns([])

    @provider.expects(:get_transactions).once.with do |_token, kind:, account_id:, from:, to:|
      kind == "account" && account_id == "a1" && from >= 90.days.ago && to > 1.minute.ago
    end.returns([ { transaction_id: "t1", amount: -5, timestamp: "2026-01-01T00:00:00Z", currency: "GBP", description: "x" } ])
    @provider.expects(:get_balance).once.with("token", kind: "account", account_id: "a1").returns(current: 123.45, currency: "GBP")

    result = TruelayerItem::Importer.new(@item).import

    assert result[:success]
    linked.reload
    assert_equal 123.45, linked.current_balance
    assert_equal [ "t1" ], linked.raw_transactions_payload.map { |t| t["transaction_id"] }
  end

  test "right after consent, backfills every account a year at a time until the bank refuses" do
    @item.update!(last_authorized_at: 1.minute.ago)
    @item.truelayer_accounts.create!(account_id: "a1", name: "Unlinked", currency: "GBP")
    @provider.stubs(:get_accounts).returns([ account_snapshot("a1", "Unlinked") ])
    @provider.stubs(:get_cards).returns([])
    @provider.stubs(:get_balance).returns(current: 1, currency: "GBP")

    sequence = sequence("backfill")
    @provider.expects(:get_transactions).in_sequence(sequence).returns([ txn("recent") ])
    @provider.expects(:get_transactions).in_sequence(sequence).returns([ txn("older") ])
    @provider.expects(:get_transactions).in_sequence(sequence)
      .raises(Provider::Truelayer::TruelayerError.new("sca_exceeded", :bad_request, status: 400))

    result = TruelayerItem::Importer.new(@item).import

    assert result[:success]
    ids = @item.truelayer_accounts.find_by(account_id: "a1").raw_transactions_payload.map { |t| t["transaction_id"] }
    assert_equal %w[older recent].sort, ids.sort
    @item.reload
    assert @item.good?
    assert_not_nil @item.history_backfilled_at
  end

  test "a 403 sca_exceeded on an older year ends the backfill without flagging the connection" do
    @item.update!(last_authorized_at: 1.minute.ago)
    @item.truelayer_accounts.create!(account_id: "a1", name: "Unlinked", currency: "GBP")
    @provider.stubs(:get_accounts).returns([ account_snapshot("a1", "Unlinked") ])
    @provider.stubs(:get_cards).returns([])
    @provider.stubs(:get_balance).returns(current: 1, currency: "GBP")

    sequence = sequence("backfill")
    @provider.expects(:get_transactions).in_sequence(sequence).returns([ txn("recent") ])
    @provider.expects(:get_transactions).in_sequence(sequence)
      .raises(Provider::Truelayer::TruelayerError.new("SCA exemption has expired", :consent_expired, status: 403, code: "sca_exceeded"))

    result = TruelayerItem::Importer.new(@item).import

    assert result[:success]
    @item.reload
    assert @item.good?
    assert_not_nil @item.history_backfilled_at
    assert_equal [ "recent" ], @item.truelayer_accounts.find_by(account_id: "a1").raw_transactions_payload.map { |t| t["transaction_id"] }
  end

  test "a rate limit on an older year keeps the rows fetched, reports the failure and leaves the backfill to retry" do
    @item.update!(last_authorized_at: 1.minute.ago)
    @item.truelayer_accounts.create!(account_id: "a1", name: "Unlinked", currency: "GBP")
    @provider.stubs(:get_accounts).returns([ account_snapshot("a1", "Unlinked") ])
    @provider.stubs(:get_cards).returns([])
    @provider.stubs(:get_balance).returns(current: 1, currency: "GBP")

    sequence = sequence("backfill")
    @provider.expects(:get_transactions).in_sequence(sequence).returns([ txn("recent") ])
    @provider.expects(:get_transactions).in_sequence(sequence)
      .raises(Provider::Truelayer::TruelayerError.new("rate limited", :rate_limited, status: 429))

    result = assert_difference -> { DebugLogEntry.with_provider_key("truelayer").count }, 1 do
      TruelayerItem::Importer.new(@item).import
    end

    assert_not result[:success]
    assert_equal 1, result[:transactions_failed]
    assert_nil @item.reload.history_backfilled_at
    assert_equal [ "recent" ], @item.truelayer_accounts.find_by(account_id: "a1").raw_transactions_payload.map { |t| t["transaction_id"] }
  end

  test "does not repeat a completed backfill while the window is still open" do
    @item.update!(last_authorized_at: 1.minute.ago, history_backfilled_at: 30.seconds.ago)
    link(@item.truelayer_accounts.create!(account_id: "a1", name: "Acc", currency: "GBP"))
    @item.truelayer_accounts.create!(account_id: "a2", name: "Unlinked", currency: "GBP")
    @provider.stubs(:get_accounts).returns([ account_snapshot("a1", "Acc"), account_snapshot("a2", "Unlinked") ])
    @provider.stubs(:get_cards).returns([])
    @provider.stubs(:get_balance).returns(current: 1, currency: "GBP")

    @provider.expects(:get_transactions).once.with do |_token, kind:, account_id:, from:, to:|
      kind == "account" && account_id == "a1" && from >= 90.days.ago
    end.returns([])

    assert TruelayerItem::Importer.new(@item).import[:success]
  end

  test "records once when the first import runs after the consent window has closed" do
    @item.update!(last_authorized_at: 10.minutes.ago)
    link(@item.truelayer_accounts.create!(account_id: "a1", name: "Acc", currency: "GBP"))
    @provider.stubs(:get_accounts).returns([ account_snapshot("a1", "Acc") ])
    @provider.stubs(:get_cards).returns([])
    @provider.stubs(:get_balance).returns(current: 1, currency: "GBP")
    @provider.stubs(:get_transactions).returns([])

    assert_difference -> { DebugLogEntry.with_provider_key("truelayer").count }, 1 do
      TruelayerItem::Importer.new(@item).import
    end
    assert @item.reload.history_backfill_missed?

    @item.stubs(:last_synced_at).returns(1.second.ago)
    assert_no_difference -> { DebugLogEntry.with_provider_key("truelayer").count } do
      TruelayerItem::Importer.new(@item).import
    end
  end

  test "a reauth error flags the connection and stops the import" do
    @provider.expects(:get_accounts).raises(Provider::Truelayer::TruelayerError.new("expired", :consent_expired, status: 403))
    @provider.stubs(:get_cards).returns([])

    assert_raises(Provider::Truelayer::TruelayerError) { TruelayerItem::Importer.new(@item).import }
    assert @item.reload.requires_update?
  end

  test "a 401 mid-import refreshes the token once and retries the request" do
    link(@item.truelayer_accounts.create!(account_id: "a1", name: "Acc", currency: "GBP"))
    @provider.stubs(:get_cards).returns([])
    @provider.stubs(:get_transactions).returns([])
    @provider.stubs(:get_balance).returns(current: 1, currency: "GBP")
    @provider.expects(:refresh_access_token).with("refresh").returns(access_token: "fresh", refresh_token: "refresh2", expires_in: 3600)

    sequence = sequence("retry")
    @provider.expects(:get_accounts).with("token").in_sequence(sequence)
      .raises(Provider::Truelayer::TruelayerError.new("expired", :unauthorized, status: 401))
    @provider.expects(:get_accounts).with("fresh").in_sequence(sequence).returns([ account_snapshot("a1", "Acc") ])

    assert TruelayerItem::Importer.new(@item).import[:success]
    @item.reload
    assert @item.good?
    assert_equal "refresh2", @item.refresh_token
  end

  test "prunes unlinked accounts the bank no longer returns and keeps linked ones" do
    link(@item.truelayer_accounts.create!(account_id: "linked-gone", name: "Old", currency: "GBP"))
    @item.truelayer_accounts.create!(account_id: "unlinked-gone", name: "Closed", currency: "GBP")
    @provider.stubs(:get_accounts).returns([ account_snapshot("a1", "Acc") ])
    @provider.stubs(:get_cards).returns([])
    @provider.stubs(:get_transactions).returns([])
    @provider.stubs(:get_balance).returns(current: 1, currency: "GBP")

    TruelayerItem::Importer.new(@item).import

    assert_equal %w[a1 linked-gone], @item.truelayer_accounts.pluck(:account_id).sort
  end

  test "does not prune when the bank returns no accounts at all" do
    @item.truelayer_accounts.create!(account_id: "a1", name: "Unlinked", currency: "GBP")
    @provider.stubs(:get_accounts).returns([])
    @provider.stubs(:get_cards).returns([])

    TruelayerItem::Importer.new(@item).import

    assert_equal [ "a1" ], @item.truelayer_accounts.pluck(:account_id)
  end

  test "a token refused again after a refresh stops the import and asks for a reconnect" do
    link(@item.truelayer_accounts.create!(account_id: "a1", name: "Acc", currency: "GBP"))
    @provider.expects(:refresh_access_token).once.returns(access_token: "fresh", refresh_token: "refresh2", expires_in: 3600)
    @provider.expects(:get_accounts).twice.raises(Provider::Truelayer::TruelayerError.new("nope", :unauthorized, status: 401))
    @provider.expects(:get_cards).never
    @provider.expects(:get_transactions).never

    assert_raises(Provider::Truelayer::TruelayerError) { TruelayerItem::Importer.new(@item).import }

    @item.reload
    assert @item.requires_update?
    assert_equal "token_rejected", @item.reauth_reason
  end

  test "a dead refresh token discovered while retrying a 401 flags the connection" do
    @provider.expects(:get_accounts).once.raises(Provider::Truelayer::TruelayerError.new("expired", :unauthorized, status: 401))
    @provider.expects(:refresh_access_token).raises(Provider::Truelayer::TruelayerError.new("invalid_grant", :invalid_grant, status: 400))

    assert_raises(Provider::Truelayer::TruelayerError) { TruelayerItem::Importer.new(@item).import }

    @item.reload
    assert @item.requires_update?
    assert_equal "invalid_grant", @item.reauth_reason
  end

  test "a failed cards fetch on the first sync keeps the accounts and leaves the backfill to retry" do
    @item.update!(last_authorized_at: 1.minute.ago)
    @provider.stubs(:get_accounts).returns([ account_snapshot("a1", "Acc") ])
    @provider.stubs(:get_cards).raises(Provider::Truelayer::TruelayerError.new("rate limited", :rate_limited, status: 429))
    @provider.stubs(:get_transactions).returns([])
    @provider.stubs(:get_balance).returns(current: 1, currency: "GBP")

    result = TruelayerItem::Importer.new(@item).import

    assert_not result[:success]
    assert_equal 1, result[:accounts_failed]
    assert_equal [ "a1" ], @item.truelayer_accounts.pluck(:account_id)
    assert_nil @item.reload.history_backfilled_at
  end

  test "a provider without a cards endpoint does not lose the cards already known" do
    @item.truelayer_accounts.create!(account_id: "c1", account_kind: "card", name: "Card", currency: "GBP")
    @item.truelayer_accounts.create!(account_id: "gone", name: "Closed", currency: "GBP")
    @provider.stubs(:get_accounts).returns([ account_snapshot("a1", "Acc") ])
    @provider.stubs(:get_cards).returns(nil)

    TruelayerItem::Importer.new(@item).import

    assert_equal %w[a1 c1], @item.truelayer_accounts.pluck(:account_id).sort
  end

  test "fetches the regular range when the consent window closes before the backfill's first request" do
    @item.update!(last_authorized_at: 10.minutes.ago)
    @item.stubs(:full_history_available?).returns(true)
    link(@item.truelayer_accounts.create!(account_id: "a1", name: "Acc", currency: "GBP"))
    @provider.stubs(:get_accounts).returns([ account_snapshot("a1", "Acc") ])
    @provider.stubs(:get_cards).returns([])
    @provider.stubs(:get_balance).returns(current: 1, currency: "GBP")
    @provider.expects(:get_transactions).once.with { |_token, kind:, account_id:, from:, to:| from >= 90.days.ago }.returns([ txn("recent") ])

    assert_difference -> { DebugLogEntry.with_provider_key("truelayer").count }, 1 do
      TruelayerItem::Importer.new(@item).import
    end

    assert_nil @item.reload.history_backfilled_at
    assert_equal [ "recent" ], @item.truelayer_accounts.find_by(account_id: "a1").raw_transactions_payload.map { |t| t["transaction_id"] }
  end

  test "the backfill stops at the chosen start date" do
    @item.update!(last_authorized_at: 1.minute.ago, sync_start_date: 500.days.ago.to_date)
    @item.truelayer_accounts.create!(account_id: "a1", name: "Unlinked", currency: "GBP")
    @provider.stubs(:get_accounts).returns([ account_snapshot("a1", "Unlinked") ])
    @provider.stubs(:get_cards).returns([])
    @provider.stubs(:get_balance).returns(current: 1, currency: "GBP")
    ranges = []
    @provider.stubs(:get_transactions).with { |_token, kind:, account_id:, from:, to:| ranges << [ from, to ] }.returns([])

    result = TruelayerItem::Importer.new(@item).import

    assert result[:success]
    assert_equal 2, ranges.size
    assert_equal ranges.first.first, ranges.last.last
    assert_equal @item.sync_start_date.beginning_of_day, ranges.last.first
    assert_not_nil @item.reload.history_backfilled_at
  end

  test "the regular sync never fetches before the chosen start date" do
    @item.update!(sync_start_date: 30.days.ago.to_date)
    link(@item.truelayer_accounts.create!(account_id: "a1", name: "Acc", currency: "GBP"))
    @provider.stubs(:get_accounts).returns([ account_snapshot("a1", "Acc") ])
    @provider.stubs(:get_cards).returns([])
    @provider.stubs(:get_balance).returns(current: 1, currency: "GBP")
    @provider.expects(:get_transactions).once
      .with { |_token, kind:, account_id:, from:, to:| from == @item.sync_start_date.beginning_of_day }
      .returns([])

    assert TruelayerItem::Importer.new(@item).import[:success]
  end

  private

    def account_snapshot(id, name)
      { account_id: id, display_name: name, currency: "GBP", account_type: "TRANSACTION", provider: { display_name: "Acme Bank", provider_id: "ob-acme" } }
    end

    def txn(id)
      { transaction_id: id, amount: -1, timestamp: "2025-01-01T00:00:00Z", currency: "GBP", description: "x" }
    end

    def link(truelayer_account)
      account = Account.create!(family: @family, name: "Acc", balance: 0, currency: "GBP", accountable: Depository.new)
      AccountProvider.create!(account: account, provider: truelayer_account)
      truelayer_account
    end
end
