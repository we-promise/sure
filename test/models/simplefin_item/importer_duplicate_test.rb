require "test_helper"

class SimplefinItem::ImporterDuplicateTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(family: @family, name: "SF Conn", access_url: "https://example.com/access")
    @sync = Sync.create!(syncable: @item) # allow stats persistence
  end

  test "balances-only import treats duplicate save as partial success with friendly error" do
    # Stub provider to return one account
    mock_provider = mock()
    mock_provider.expects(:get_accounts).returns({ accounts: [ { id: "dup1", name: "Dup", balance: 10, currency: "USD" } ] })

    importer = SimplefinItem::Importer.new(@item, simplefin_provider: mock_provider, sync: @sync)

    # Return an SFA whose save! raises RecordNotUnique
    sfa = SimplefinAccount.new(simplefin_item: @item, account_id: "dup1")
    SimplefinAccount.any_instance.stubs(:save!).raises(ActiveRecord::RecordNotUnique).then.returns(true)

    importer.import_balances_only

    stats = @sync.reload.sync_stats
    assert_equal true, stats["balances_only"]
    assert_equal 1, stats["accounts_skipped"], "should count skipped duplicate"
    assert_equal 1, stats["total_errors"], "should increment total_errors"
    assert_includes stats["errors"].last["message"], "Duplicate upstream account detected", "should show friendly duplicate message"
  end

  test "full import path import_account treats duplicate save as partial success with friendly error" do
    importer = SimplefinItem::Importer.new(@item, simplefin_provider: mock(), sync: @sync)

    account_data = { id: "dup2", name: "Dup2", balance: 20, currency: "USD" }

    # For the specific SFA involved in import_account, make save! raise first, then succeed
    SimplefinAccount.any_instance.stubs(:save!).raises(ActiveRecord::RecordNotUnique).then.returns(true)

    # Call the private method directly for focused testing
    importer.send(:import_account, account_data)

    stats = @sync.reload.sync_stats
    assert_equal 1, stats["accounts_skipped"], "should count skipped duplicate"
    assert_equal 1, stats["total_errors"], "should increment total_errors"
    assert_includes stats["errors"].last["message"], "Duplicate upstream account detected", "should show friendly duplicate message"
  end
end
