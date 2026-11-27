require "test_helper"

class Family::TruelayerConnectableTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @credentials = @family.truelayer_items.create!(name: "TrueLayer Connection", client_id: "test-client", client_secret: "secret")
  end

  test "there is nothing to connect with before credentials are saved" do
    assert_nil families(:dylan_family).truelayer_item_for_new_connection
  end

  test "each consent flow started gets its own connection with the shared credentials" do
    first = @family.truelayer_item_for_new_connection
    second = @family.truelayer_item_for_new_connection

    assert_not_equal first, second
    assert_equal [ "test-client", "secret" ], [ second.client_id, second.client_secret ]
    assert_not second.connected?
  end

  test "a connection whose flow was abandoned is reused instead of piling up" do
    abandoned = @family.truelayer_item_for_new_connection

    travel Family::TruelayerConnectable::PENDING_CONSENT_TIMEOUT + 1.minute do
      assert_no_difference -> { @family.truelayer_items.count } do
        # The credentials row is unconnected too, so it is just as reusable.
        assert_includes [ @credentials, abandoned ], @family.truelayer_item_for_new_connection
      end
    end
  end

  test "a reused connection is reserved again for the new flow" do
    abandoned = @family.truelayer_item_for_new_connection
    travel Family::TruelayerConnectable::PENDING_CONSENT_TIMEOUT + 1.minute do
      @credentials.update!(refresh_token: "r")

      assert_equal abandoned, @family.truelayer_item_for_new_connection
      assert_not_equal abandoned, @family.truelayer_item_for_new_connection, "the row was just handed out, so it is reserved"
    end
  end

  test "a connected row is never handed out again" do
    connected = @family.truelayer_item_for_new_connection
    connected.update!(refresh_token: "r")

    travel Family::TruelayerConnectable::PENDING_CONSENT_TIMEOUT + 1.minute do
      assert_not_equal connected, @family.truelayer_item_for_new_connection
    end
  end
end
