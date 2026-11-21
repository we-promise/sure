require "test_helper"

class TradeRepublicItemTest < ActiveSupport::TestCase
  include TradeRepublicSessionTestHelper, ActiveJob::TestHelper

  test "database enforces one account of each kind per item" do
    item = trade_republic_items(:configured_item)

    assert_raises ActiveRecord::RecordNotUnique do
      item.trade_republic_accounts.create!(
        kind: "portfolio",
        name: "Duplicate portfolio",
        currency: "EUR"
      )
    end
  end

  test "database enforces one active connection per family per brokerage account" do
    family = trade_republic_items(:configured_item).family
    family.trade_republic_items.create!(
      name: "Trade Republic", currency: "EUR", status: :good, session_blob: "a", brokerage_account_id: "DE1234"
    )

    assert_raises ActiveRecord::RecordNotUnique do
      family.trade_republic_items.create!(
        name: "Trade Republic", currency: "EUR", status: :good, session_blob: "b", brokerage_account_id: "DE1234"
      )
    end
  end

  test "a connection scheduled for deletion does not block reconnecting the same brokerage account" do
    family = trade_republic_items(:configured_item).family
    deleted = family.trade_republic_items.create!(
      name: "Trade Republic", currency: "EUR", status: :good, session_blob: "a", brokerage_account_id: "DE1234",
      scheduled_for_deletion: true
    )

    reconnected = family.trade_republic_items.create!(
      name: "Trade Republic", currency: "EUR", status: :good, session_blob: "b", brokerage_account_id: "DE1234"
    )

    assert_not_equal deleted.id, reconnected.id
  end

  test "syncable scope requires a stored session" do
    items = TradeRepublicItem.syncable

    assert_includes items, trade_republic_items(:configured_item)
    assert_not_includes items, trade_republic_items(:no_session_item)
  end

  test "syncable scope excludes reauthentication but not a login pending beside a valid session" do
    item = trade_republic_items(:configured_item)
    item.update!(status: :requires_update)
    assert_not_includes TradeRepublicItem.syncable, item

    item.update!(status: :good, pending_login_state: "pending")
    assert_includes TradeRepublicItem.syncable, item
    assert_predicate item, :ready_for_sync?
  end

  test "syncable scope excludes an ended session but keeps one without a known end" do
    item = trade_republic_items(:configured_item)
    item.update_columns(session_expires_at: 1.minute.ago)
    assert_not_includes TradeRepublicItem.syncable, item

    item.update_columns(session_expires_at: nil)
    assert_includes TradeRepublicItem.syncable, item

    item.update_columns(session_expires_at: 1.hour.from_now)
    assert_includes TradeRepublicItem.syncable, item
  end

  test "session_configured? reflects stored session" do
    assert_predicate trade_republic_items(:configured_item), :session_configured?
    assert_not_predicate trade_republic_items(:no_session_item), :session_configured?
  end

  test "credentials_configured? only needs the phone number" do
    assert_predicate trade_republic_items(:no_session_item), :credentials_configured?
  end

  test "a QR-authenticated item may be good without a phone number" do
    item = TradeRepublicItem.new(
      family: families(:dylan_family),
      name: "Trade Republic QR Connection",
      currency: "EUR",
      status: :good,
      session_blob: "qr-session"
    )

    assert_predicate item, :valid?
    assert_predicate item, :credentials_configured?
  end

  test "PIN is persisted encrypted so scheduled logins can use it" do
    item = trade_republic_items(:configured_item)

    assert_includes TradeRepublicItem.column_names, "pin"
    item.update!(pin: "1234", auto_login_time: "07:30")

    assert_equal "1234", item.reload.pin
    assert_not_equal "1234", item.read_attribute_before_type_cast("pin")
  end

  test "the PIN is never stored unencrypted" do
    item = trade_republic_items(:configured_item)
    ActiveRecordEncryptionConfig.stubs(:ready?).returns(false)

    item.update!(pin: "1234")

    assert_nil item.reload.pin
  end

  test "the PIN is not stored under keys derived from a known compromised secret" do
    item = trade_republic_items(:configured_item)
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)
    ActiveRecordEncryptionConfig.stubs(:using_known_compromised_secret_key_base?).returns(true)

    item.pin = "1234"
    item.auto_login_time = "07:30"

    assert_not item.valid?
    assert_predicate item.errors[:auto_login_time], :present?
  end

  test "the PIN is only kept while auto login is on" do
    item = trade_republic_items(:configured_item)

    item.update!(pin: "1234")
    assert_nil item.reload.pin

    item.update!(pin: "1234", auto_login_time: "07:30")
    assert_equal "1234", item.reload.pin

    item.update!(auto_login_time: nil)
    assert_nil item.reload.pin
  end

  test "an item stored without a PIN has none" do
    assert_nil trade_republic_items(:configured_item).pin
  end

  test "sync_status_summary counts linked and unlinked accounts" do
    item = trade_republic_items(:configured_item)
    item.trade_republic_accounts.destroy_all

    assert_match(/discovered yet/i, item.sync_status_summary)
    assert_equal 0, item.total_accounts_count

    linked = item.trade_republic_accounts.create!(
      name: "Summary Linked",
      trade_republic_account_id: "DESUMM",
      currency: "EUR"
    )
    item.trade_republic_accounts.create!(
      kind: "cash",
      name: "Summary Unlinked",
      trade_republic_account_id: "DESUMM2",
      currency: "EUR"
    )
    family_account = item.family.accounts.create!(
      name: "Summary Linked Account",
      balance: 0,
      currency: "EUR",
      accountable: Investment.new
    )
    linked.ensure_account_provider!(family_account)
    linked.reload

    assert_match(/1 linked, 1 need setup/i, item.reload.sync_status_summary)
  end

  test "data_quality_summary dedupes portfolio and cash timeline events" do
    item = trade_republic_items(:configured_item)
    item.trade_republic_accounts.destroy_all

    shared = {
      "id" => "evt_shared",
      "eventType" => "CARD_TRANSACTION",
      "category" => "POC_CREATED",
      "status" => "EXECUTED"
    }
    cash_only = {
      "id" => "evt_cash_only",
      "eventType" => "PAYMENT_INBOUND",
      "category" => "PAYMENT_RECEIVED"
    }
    admin = {
      "id" => "evt_admin",
      "eventType" => "CARD_VERIFICATION",
      "title" => "Card verification"
    }
    legal_docs = {
      "id" => "evt_legal",
      "title" => "Legal documents",
      "subtitle" => "Accepted"
    }
    order_created = {
      "id" => "evt_order_created",
      "eventType" => "TRADING_ORDER_CREATED",
      "title" => "SanDisk",
      "subtitle" => "Limit buy created"
    }
    mapping_gap = {
      "id" => "evt_gap",
      "eventType" => "BRAND_NEW_MAPPING_GAP",
      "title" => "Mystery"
    }

    item.trade_republic_accounts.create!(
      kind: "portfolio",
      name: "Portfolio",
      trade_republic_account_id: "DE-DQ-P",
      currency: "EUR",
      raw_timeline_payload: [ shared, admin, legal_docs, order_created, mapping_gap ]
    )
    item.trade_republic_accounts.create!(
      kind: "cash",
      name: "Cash",
      trade_republic_account_id: "DE-DQ-C",
      currency: "EUR",
      raw_timeline_payload: [ shared, cash_only, admin ]
    )

    summary = item.data_quality_summary

    assert_equal 6, summary[:events]
    assert_equal 1, summary[:unknown_events]
  end

  test "process_accounts processes portfolio before cash even when cash was created first" do
    item = trade_republic_items(:configured_item)
    item.trade_republic_accounts.destroy_all

    cash = item.trade_republic_accounts.create!(
      kind: "cash",
      name: "Cash First",
      trade_republic_account_id: "DE-ORD-C",
      currency: "EUR"
    )
    portfolio = item.trade_republic_accounts.create!(
      kind: "portfolio",
      name: "Portfolio Second",
      trade_republic_account_id: "DE-ORD-P",
      currency: "EUR"
    )

    cash_sure = item.family.accounts.create!(
      name: "TR Cash Order",
      balance: 0,
      cash_balance: 0,
      currency: "EUR",
      accountable: Depository.new
    )
    portfolio_sure = item.family.accounts.create!(
      name: "TR Portfolio Order",
      balance: 0,
      cash_balance: 0,
      currency: "EUR",
      accountable: Investment.new
    )
    cash.ensure_account_provider!(cash_sure)
    portfolio.ensure_account_provider!(portfolio_sure)

    processed_kinds = []
    fake_processor = Object.new
    fake_processor.define_singleton_method(:process) { true }
    TradeRepublicAccount::Processor.stubs(:new).with { |tr_account|
      processed_kinds << tr_account.kind
      true
    }.returns(fake_processor)

    item.process_accounts

    assert_equal %w[portfolio cash], processed_kinds
  end

  test "gives each connection its own device ID" do
    assert_not_equal trade_republic_items(:configured_item).device_id, trade_republic_items(:requires_update_item).device_id
  end

  test "a new connection logs in with its device ID right away" do
    item = TradeRepublicItem.create!(family: families(:dylan_family), phone_number: "+491700000000")

    assert item.device_id.present?
    Provider::TradeRepublicClient.expects(:new).with(has_entry(device_id: item.device_id))
    item.trade_republic_provider(pin: "1234")
  end

  test "a new session records when it expires and plans a sync before then" do
    item = trade_republic_items(:configured_item)
    expires_at = 23.hours.from_now.change(usec: 0)

    assert_enqueued_with job: TradeRepublicPreExpirySyncJob, at: expires_at - TradeRepublicPreExpirySyncJob::LEAD_TIME do
      item.update!(session_blob: trade_republic_session_blob(expires_at: expires_at))
    end
    assert_equal expires_at, item.reload.session_expires_at
  end

  test "a refreshed session with the same expiry plans no extra sync" do
    item = trade_republic_items(:configured_item)
    expires_at = 23.hours.from_now.change(usec: 0)
    item.update!(session_blob: trade_republic_session_blob(expires_at: expires_at))

    assert_no_enqueued_jobs only: TradeRepublicPreExpirySyncJob do
      item.update!(session_blob: trade_republic_session_blob(expires_at: expires_at).sub("session", "renewed"))
    end
  end

  test "an expired session needs a new login" do
    item = trade_republic_items(:configured_item)
    item.update!(session_blob: trade_republic_session_blob(expires_at: 1.minute.ago))

    assert item.good?
    assert item.session_expired?
    assert item.needs_login?
    assert_not item.ready_for_sync?
  end

  test "clearing the session forgets its expiry" do
    item = trade_republic_items(:configured_item)
    item.update!(session_blob: trade_republic_session_blob(expires_at: 5.hours.from_now))

    item.update!(session_blob: nil, status: :requires_update)

    assert_nil item.reload.session_expires_at
  end
  test "setting an auto login time plans the daily login and stores the schedule token" do
    item = trade_republic_items(:configured_item)

    assert_enqueued_with(job: TradeRepublicReloginJob) do
      item.update!(pin: "1234", auto_login_time: "07:30")
    end

    assert_predicate item.reload.auto_login_token, :present?
  end

  test "changing the auto login time replaces the schedule so earlier jobs go stale" do
    item = trade_republic_items(:configured_item)
    item.update!(pin: "1234", auto_login_time: "07:30")
    first_token = item.reload.auto_login_token

    item.update!(auto_login_time: "08:00")

    assert_not_equal first_token, item.reload.auto_login_token
  end

  test "clearing the auto login time cancels the schedule and plans nothing" do
    item = trade_republic_items(:configured_item)
    item.update!(pin: "1234", auto_login_time: "07:30")

    assert_no_enqueued_jobs only: TradeRepublicReloginJob do
      item.update!(auto_login_time: "")
    end

    assert_nil item.reload.auto_login_time
    assert_nil item.auto_login_token
  end

  test "a new session no longer plans a login by itself" do
    item = trade_republic_items(:configured_item)

    assert_no_enqueued_jobs only: TradeRepublicReloginJob do
      item.update!(session_blob: trade_republic_session_blob(expires_at: 24.hours.from_now))
    end
  end

  test "the auto login time must be a time of day" do
    item = trade_republic_items(:configured_item)
    item.pin = "1234"

    item.auto_login_time = "25:00"
    assert_not item.valid?

    item.auto_login_time = "7:30"
    assert_not item.valid?

    item.auto_login_time = "07:30"
    assert_predicate item, :valid?
  end

  test "duplicate cleanup leaves a login alone that replaced the pending state meanwhile" do
      item = trade_republic_items(:configured_item)
      item.update!(pending_login_state: "newer-b64")

      assert_not item.discard_duplicate_connection!("older-b64")

      item.reload
      assert_equal "newer-b64", item.pending_login_state
      assert_predicate item, :session_configured?
    end

  test "auto login needs a phone number" do
    item = trade_republic_items(:configured_item)
    item.update_columns(phone_number: nil)
    item.pin = "1234"
    item.auto_login_time = "07:30"

    assert_not item.valid?
    assert_predicate item.errors[:auto_login_time], :present?

    item.auto_login_time = nil
    assert_predicate item, :valid?
  end

  test "auto login needs a stored PIN" do
    item = trade_republic_items(:configured_item)
    item.update!(pin: nil)

    item.auto_login_time = "07:30"

    assert_not item.valid?
    assert_predicate item.errors[:auto_login_time], :present?
  end

  test "the next auto login is at the time of day in the family's zone" do
    families(:dylan_family).update!(timezone: "Europe/Berlin")
    item = trade_republic_items(:configured_item)
    item.pin = "1234"
    item.auto_login_time = "07:30"

    travel_to Time.utc(2026, 11, 17, 5, 0) do
      assert_equal Time.utc(2026, 11, 17, 6, 30), item.next_auto_login_at
    end
    travel_to Time.utc(2026, 11, 17, 7, 0) do
      assert_equal Time.utc(2026, 11, 18, 6, 30), item.next_auto_login_at
    end
  end

  test "the next auto login keeps the local time across the change to summer time" do
    families(:dylan_family).update!(timezone: "Europe/Berlin")
    item = trade_republic_items(:configured_item)
    item.pin = "1234"
    item.auto_login_time = "07:30"

    travel_to Time.utc(2027, 3, 27, 12, 0) do
      assert_equal Time.utc(2027, 3, 28, 5, 30), item.next_auto_login_at
    end
  end

  test "a time that does not exist on the day the clocks go forward moves to the next valid time" do
    families(:dylan_family).update!(timezone: "Europe/Berlin")
    item = trade_republic_items(:configured_item)
    item.pin = "1234"
    item.auto_login_time = "02:30"

    travel_to Time.utc(2027, 3, 27, 12, 0) do
      assert_equal Time.utc(2027, 3, 28, 1, 30), item.next_auto_login_at
    end
  end

  test "an unknown family zone falls back to the app's zone" do
    families(:dylan_family).update_columns(timezone: "Nowhere/Land")
    item = trade_republic_items(:configured_item)
    item.update_columns(auto_login_time: "07:30")

    travel_to Time.utc(2026, 11, 17, 5, 0) do
      assert_equal Time.zone.local(2026, 11, 17, 7, 30), item.reload.next_auto_login_at
    end
  end
end
