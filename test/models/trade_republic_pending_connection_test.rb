require "test_helper"

class TradeRepublicPendingConnectionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "a phone number and PIN login needs the phone number, a QR login does not" do
    assert_not @family.trade_republic_pending_connections.build.valid?
    assert @family.trade_republic_pending_connections.build(qr_login: true).valid?
  end

  test "connecting creates the connection with the login's device ID and removes the pending one" do
    pending_connection = @family.trade_republic_pending_connections.create!(phone_number: "+491701234567", currency: "EUR")

    item = pending_connection.connect!(session_blob: "session", brokerage_account_id: "DE4242")

    assert_predicate item, :good?
    assert_equal pending_connection.device_id, item.device_id
    assert_equal "+491701234567", item.phone_number
    assert_equal "DE4242", item.brokerage_account_id
    assert_not TradeRepublicPendingConnection.exists?(pending_connection.id)
  end

  test "a failed connect keeps the pending connection" do
    @family.trade_republic_items.create!(name: "Trade Republic", currency: "EUR", status: :good, session_blob: "session", brokerage_account_id: "DE4242")
    pending_connection = @family.trade_republic_pending_connections.create!(qr_login: true)

    assert_raises(ActiveRecord::RecordNotUnique) do
      pending_connection.connect!(session_blob: "session", brokerage_account_id: "DE4242")
    end
    assert TradeRepublicPendingConnection.exists?(pending_connection.id)
  end

  test "the PIN is not kept" do
    assert_not_includes TradeRepublicPendingConnection.column_names, "pin"
  end

  test "a new connection has its device ID before it is saved" do
    pending_connection = @family.trade_republic_pending_connections.build(qr_login: true)

    assert pending_connection.device_id.present?
    Provider::TradeRepublicClient.expects(:new).with(has_entry(device_id: pending_connection.device_id))
    pending_connection.trade_republic_provider
  end

  test "a family has one pending connection at a time" do
    @family.trade_republic_pending_connections.create!(qr_login: true)

    assert_raises(ActiveRecord::RecordNotUnique) do
      @family.trade_republic_pending_connections.create!(qr_login: true)
    end
  end
end
