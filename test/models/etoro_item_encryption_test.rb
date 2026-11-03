require "test_helper"

# Kept apart from EtoroItemTest: CI reruns every file that checks
# encryption_ready? with encryption keys set, and the eToro fixtures hold
# their encrypted columns as plain text.
class EtoroItemEncryptionTest < ActiveSupport::TestCase
  test "encrypts the keys and the instrument metadata when active record encryption is configured" do
    skip "Encryption not configured" unless EtoroItem.encryption_ready?

    item = EtoroItem.create!(
      family: families(:dylan_family),
      name: "eToro",
      api_key: "test_public_key",
      user_key: "test_user_key",
      raw_instruments_payload: { "1001" => { "symbol" => "AAPL" } }
    )

    raw = EtoroItem.connection.select_one(
      "SELECT api_key, user_key, raw_instruments_payload FROM etoro_items WHERE id = #{EtoroItem.connection.quote(item.id)}"
    )
    assert_not_includes raw["api_key"].to_s, "test_public_key"
    assert_not_includes raw["user_key"].to_s, "test_user_key"
    assert_not_includes raw["raw_instruments_payload"].to_s, "AAPL"

    item.reload
    assert_equal [ "test_public_key", "test_user_key" ], [ item.api_key, item.user_key ]
    assert_equal "AAPL", item.instruments_map.dig("1001", "symbol")
  end
end
