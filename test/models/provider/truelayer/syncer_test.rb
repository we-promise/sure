require "test_helper"

class Provider::Truelayer::SyncerTest < ActiveSupport::TestCase
  setup do
    @connection = provider_connections(:monzo_connection)
    @sync       = @connection.syncs.create!
    @syncer     = Provider::Truelayer::Syncer.new(@connection)
    # Stub stat collection to avoid DB interactions in unit tests
    @syncer.stubs(:collect_setup_stats)
    @syncer.stubs(:collect_health_stats)
    @syncer.stubs(:collect_transaction_stats)
  end

  test "marks connection requires_update when ReauthRequired" do
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token)
                          .raises(Provider::Auth::ReauthRequiredError)
    @syncer.perform_sync(@sync)
    assert @connection.reload.requires_update?
    assert_equal "reauth_required", @connection.read_attribute(:sync_error)
  end

  test "syncs linked accounts even when other accounts are still in pending_setup" do
    # monzo_unlinked fixture leaves connection in pending_setup state, but
    # monzo_current is linked — its transactions should still be fetched.
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_accounts).returns({ accounts: [], partial: false })
    Provider::Truelayer::Adapter.any_instance.expects(:fetch_transactions).at_least_once.returns([])
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_balance).returns(nil)
    Account.any_instance.stubs(:sync_later)
    @syncer.perform_sync(@sync)
    assert @connection.reload.healthy?
  end

  test "marks connection healthy after successful sync" do
    provider_accounts(:monzo_unlinked).update!(account: accounts(:depository))
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_accounts).returns({ accounts: [], partial: false })
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_transactions).returns([])
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_balance).returns(nil)
    Account.any_instance.stubs(:sync_later)
    @syncer.perform_sync(@sync)
    assert @connection.reload.healthy?
  end

  test "anchor_balance sets account balance from current field" do
    pa = provider_accounts(:monzo_current)
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_balance).returns({ "current" => 1234.56, "currency" => "GBP" })
    Account.any_instance.stubs(:sync_later)
    result = @syncer.send(:anchor_balance, "tok", pa)
    assert result
    assert_equal BigDecimal("1234.56"), pa.account.reload.balance
  end

  test "anchor_balance updates available_credit for credit card accounts" do
    pa = provider_accounts(:monzo_current)
    pa.account.update!(accountable_type: "CreditCard", accountable: CreditCard.create!)
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_balance).returns({
      "current" => 500.0, "credit_limit" => 4500.0, "currency" => "GBP"
    })
    Account.any_instance.stubs(:sync_later)
    @syncer.send(:anchor_balance, "tok", pa)
    assert_equal BigDecimal("4500.0"), pa.account.reload.credit_card.available_credit
  end

  test "anchor_balance returns false and warns on fetch error" do
    pa = provider_accounts(:monzo_current)
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_balance).raises(Provider::Truelayer::Error, "timeout")
    Rails.logger.expects(:warn).with { |msg| msg.include?("balance fetch failed") }
    result = @syncer.send(:anchor_balance, "tok", pa)
    assert_not result
  end

  test "sync_later called when balance anchor fails" do
    # Isolate to a single linked provider_account so assertion counts are deterministic.
    # Skip (rather than unlink) monzo_current so pending_setup? stays false.
    provider_accounts(:monzo_current).update!(account: nil, skipped: true)
    provider_accounts(:monzo_unlinked).update!(account: accounts(:depository))
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_accounts).returns({ accounts: [], partial: false })
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_transactions).returns([])
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_balance).returns(nil)
    Account.any_instance.expects(:sync_later).once
    @syncer.perform_sync(@sync)
  end

  test "sync_later not called when balance anchor succeeds" do
    # Isolate to a single linked provider_account so assertion counts are deterministic.
    # Skip (rather than unlink) monzo_current so pending_setup? stays false.
    provider_accounts(:monzo_current).update!(account: nil, skipped: true)
    provider_accounts(:monzo_unlinked).update!(account: accounts(:depository))
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_accounts).returns({ accounts: [], partial: false })
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_transactions).returns([])
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_balance).returns({ "current" => 100.0 })
    Account.any_instance.expects(:sync_later).once  # triggered by set_current_balance, not explicitly
    @syncer.perform_sync(@sync)
  end

  test "re-raises non-auth errors and sets sync_error" do
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_accounts).raises(RuntimeError, "upstream exploded")
    assert_raises(RuntimeError) { @syncer.perform_sync(@sync) }
    assert_equal "upstream exploded", @connection.reload.read_attribute(:sync_error)
  end

  test "transient errors propagate without surfacing to user" do
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_accounts)
                                              .raises(Provider::Auth::TransientError, "TrueLayer API 503")
    @connection.update!(sync_error: nil, status: :healthy)
    assert_raises(Provider::Auth::TransientError) { @syncer.perform_sync(@sync) }
    @connection.reload
    assert @connection.healthy?, "transient errors should not change status"
    assert_nil @connection.read_attribute(:sync_error), "transient errors should not be written to sync_error"
  end

  test "discover_accounts_only discovers without syncing transactions" do
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::Truelayer::Adapter.any_instance.expects(:fetch_accounts).returns({ accounts: [], partial: false }).once
    Provider::Truelayer::Adapter.any_instance.expects(:fetch_transactions).never
    @syncer.discover_accounts_only
  end

  test "discover_accounts upserts provider_accounts from adapter response" do
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_accounts).returns({
      accounts: [ {
        external_id: "new_acc_1",
        name:        "Monzo Plus",
        type:        "depository",
        subtype:     "checking",
        currency:    "GBP",
        raw_payload: { "account_id" => "new_acc_1" }
      } ],
      partial: false
    })
    assert_difference "@connection.provider_accounts.count" do
      @syncer.discover_accounts_only
    end
    pa = @connection.provider_accounts.find_by(external_id: "new_acc_1")
    assert_equal "Monzo Plus", pa.external_name
    assert_equal "GBP", pa.currency
  end

  test "discover_accounts does NOT mark accounts disappeared on partial response" do
    pa = provider_accounts(:monzo_current)
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    # Simulate /cards 5xx — adapter returns whatever /accounts gave plus partial: true.
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_accounts).returns({
      accounts: [], partial: true
    })
    @syncer.discover_accounts_only
    assert_not pa.reload.disappeared?,
      "transient upstream error must not mark existing accounts disappeared"
  end

  test "discover_accounts marks an account disappeared when missing from a complete response" do
    pa = provider_accounts(:monzo_current)
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_accounts).returns({
      accounts: [ {
        external_id: "still_here",
        name:        "Other",
        type:        "depository",
        subtype:     "checking",
        currency:    "GBP",
        raw_payload: {}
      } ],
      partial: false
    })
    @syncer.discover_accounts_only
    assert pa.reload.disappeared?,
      "account no longer in upstream complete response should be flagged"
  end

  test "discover_accounts clears the disappeared flag when an account comes back" do
    pa = provider_accounts(:monzo_current)
    pa.update!(raw_payload: pa.raw_payload.merge("disappeared_at" => 1.day.ago.iso8601))
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_accounts).returns({
      accounts: [ {
        external_id: pa.external_id,
        name:        pa.external_name,
        type:        pa.external_type,
        subtype:     pa.external_subtype,
        currency:    pa.currency,
        raw_payload: { "account_id" => pa.external_id }
      } ],
      partial: false
    })
    @syncer.discover_accounts_only
    assert_not pa.reload.disappeared?
  end

  test "honors connection.sync_start_date when pa.last_synced_at is nil" do
    # Skip the sibling linked account so we only have ONE provider_account
    # in the linked set — keeps the fetch_transactions expectation precise.
    provider_accounts(:monzo_current).update!(account: nil, skipped: true)
    pa = provider_accounts(:monzo_unlinked)
    pa.update!(account: accounts(:depository), last_synced_at: nil)
    @connection.update!(sync_start_date: 30.days.ago.to_date)
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_accounts).returns({ accounts: [], partial: false })
    Provider::Truelayer::Adapter.any_instance.expects(:fetch_transactions)
      .with { |_, _, **opts| opts[:from].to_date == 30.days.ago.to_date }
      .once
      .returns([])
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_balance).returns(nil)
    Account.any_instance.stubs(:sync_later)
    @syncer.perform_sync(@sync)
  end

  test "prefers pa.last_synced_at over sync_start_date for incremental fetches" do
    provider_accounts(:monzo_current).update!(account: nil, skipped: true)
    pa = provider_accounts(:monzo_unlinked)
    pa.update!(account: accounts(:depository), last_synced_at: 5.days.ago)
    @connection.update!(sync_start_date: 30.days.ago.to_date)
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_accounts).returns({ accounts: [], partial: false })
    Provider::Truelayer::Adapter.any_instance.expects(:fetch_transactions)
      .with { |_, _, **opts| opts[:from].to_date == 5.days.ago.to_date }
      .once
      .returns([])
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_balance).returns(nil)
    Account.any_instance.stubs(:sync_later)
    @syncer.perform_sync(@sync)
  end

  test "assigns category_id from TrueLayer classification via shared matcher" do
    provider_accounts(:monzo_current).update!(account: nil, skipped: true)
    pa = provider_accounts(:monzo_unlinked)
    pa.update!(account: accounts(:depository))
    family = pa.account.family
    family.categories.bootstrap!
    # dylan_family fixture has "Restaurants" under "Food & Drink"; matcher
    # correctly hits the more-specific subcategory via direct alias.
    expected_category = family.categories.find_by(name: "Restaurants")
    refute_nil expected_category, "expected fixture-defined Restaurants subcategory"

    txn = {
      external_id:                "tl-cat-1",
      date:                       Date.new(2026, 5, 5),
      amount:                     BigDecimal("-12.50"),
      currency:                   "GBP",
      name:                       "Pret",
      merchant_name:              nil,
      notes:                      nil,
      pending:                    false,
      transaction_category:       "PURCHASE",
      transaction_classification: [ "Food & Dining", "Restaurants" ],
      raw:                        {},
      meta:                       nil
    }
    Provider::Auth::OAuth2.any_instance.stubs(:fresh_access_token).returns("tok")
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_accounts).returns({ accounts: [], partial: false })
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_transactions).returns([ txn ])
    Provider::Truelayer::Adapter.any_instance.stubs(:fetch_balance).returns(nil)
    Account.any_instance.stubs(:sync_later)

    @syncer.perform_sync(@sync)

    entry = pa.account.entries.find_by!(external_id: "tl-cat-1", source: "truelayer")
    assert_equal expected_category.id, entry.transaction.category_id
  end
end
