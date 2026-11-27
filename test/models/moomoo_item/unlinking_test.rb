require "test_helper"

class MoomooItem::UnlinkingTest < ActiveSupport::TestCase
  setup do
    @item = moomoo_items(:connected_item)
    @moomoo_account = moomoo_accounts(:main_account)
    @link = @moomoo_account.ensure_account_provider!(accounts(:investment))
    @holding = holdings(:one)
    @holding.update!(account_provider_id: @link.id)
  end

  test "a dry run lists the links and changes nothing" do
    results = nil

    assert_no_difference -> { AccountProvider.where(provider_type: "MoomooAccount").count } do
      results = @item.unlink_all!(dry_run: true)
    end

    assert_equal [ @link.id ], results.find { |result| result[:provider_account_id] == @moomoo_account.id }[:provider_link_ids]
    assert_equal @link.id, @holding.reload.account_provider_id
  end

  test "unlinking removes the links and detaches the holdings" do
    results = nil

    assert_difference -> { AccountProvider.where(provider_type: "MoomooAccount").count }, -1 do
      results = @item.unlink_all!(dry_run: false)
    end

    assert results.none? { |result| result[:error] }
    assert_nil @holding.reload.account_provider_id
    assert_nil @moomoo_account.reload.current_account
  end
end
