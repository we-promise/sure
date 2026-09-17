require "test_helper"

class TradeRepublicItemTest < ActiveSupport::TestCase
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

  test "syncable scope requires a stored session" do
    items = TradeRepublicItem.syncable

    assert_includes items, trade_republic_items(:configured_item)
    assert_not_includes items, trade_republic_items(:no_session_item)
  end

  test "syncable scope excludes reauthentication and pending login states" do
    item = trade_republic_items(:configured_item)
    item.update!(status: :requires_update)
    assert_not_includes TradeRepublicItem.syncable, item

    item.update!(status: :good, pending_login_state: "pending")
    assert_not_includes TradeRepublicItem.syncable, item
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

  test "PIN is transient and is not a persisted attribute" do
    item = trade_republic_items(:configured_item)

    assert_not_includes TradeRepublicItem.column_names, "pin"
    item.pin = "1234"

    assert_nil item.reload.pin
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
end
