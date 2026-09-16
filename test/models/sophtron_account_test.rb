require "test_helper"
require_relative "../support/sophtron_fixture_fence_helper"

class SophtronAccountTest < ActiveSupport::TestCase
  include SophtronFixtureFenceHelper
  test "upsert_sophtron_snapshot stores owning item institution metadata fallback" do
    item = families(:dylan_family).sophtron_items.create!(
      name: "Sophtron Connection",
      user_id: "developer-user",
      access_key: Base64.strict_encode64("secret-key"),
      institution_name: "Apple / Goldman Sachs",
      user_institution_id: "ui-apple"
    )

    account = item.sophtron_accounts.build
    account.upsert_sophtron_snapshot!(
      account_id: "card-1",
      account_name: "Juan",
      currency: "USD",
      balance: "1947.18"
    )

    assert_equal "Apple / Goldman Sachs", account.institution_metadata["name"]
    assert_equal "ui-apple", account.institution_metadata["user_institution_id"]
  end
end
