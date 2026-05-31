require "test_helper"

class SophtronItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = @family.sophtron_items.create!(
      name: "Sophtron",
      user_id: "developer-user",
      access_key: Base64.strict_encode64("secret-key"),
      customer_id: "cust-1",
      user_institution_id: "ui-1"
    )
    @syncer = SophtronItem::Syncer.new(@item)
  end

  test "pluralizes transaction import failures as transactions, not accounts" do
    errors = @syncer.send(:import_errors_for, { success: false, transactions_failed: 2 })
    message = errors.find { |e| e[:category] == "transaction_import" }[:message]

    assert_equal "2 transactions failed to import transactions", message
  end

  test "uses the singular form for a single transaction import failure" do
    errors = @syncer.send(:import_errors_for, { success: false, transactions_failed: 1 })
    message = errors.find { |e| e[:category] == "transaction_import" }[:message]

    assert_equal "1 transaction failed to import transactions", message
  end
end
