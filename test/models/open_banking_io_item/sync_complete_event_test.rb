require "test_helper"

# Syncable#broadcast_sync_complete dispatches to this class by constant lookup, and the
# partial name it broadcasts into is load-bearing -- a rename would silently stop the
# connection row from refreshing after a sync.
class OpenBankingIoItem::SyncCompleteEventTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = OpenBankingIoItem.create!(
      family: @family, name: "Test connection",
      api_base_url: "https://open-banking.io", api_key: "k", private_key: "p"
    )
    @provider_account = @item.open_banking_io_accounts.create!(
      account_id: "acc-1", name: "Everyday", currency: "EUR"
    )
    @account = @family.accounts.create!(
      name: "Everyday", balance: 100, currency: "EUR", accountable: Depository.new
    )
    AccountProvider.create!(account: @account, provider: @provider_account)
  end

  test "broadcasts each linked account, the item row and the family" do
    Account.any_instance.expects(:broadcast_sync_complete).once
    Family.any_instance.expects(:broadcast_sync_complete).once
    OpenBankingIoItem.any_instance.expects(:broadcast_replace_to).with(
      @family,
      target: "open_banking_io_item_#{@item.id}",
      partial: "open_banking_io_items/open_banking_io_item",
      locals: { open_banking_io_item: @item }
    ).once

    OpenBankingIoItem::SyncCompleteEvent.new(@item).broadcast
  end

  test "Syncable dispatches to this event class" do
    assert_equal OpenBankingIoItem::SyncCompleteEvent,
                 @item.class.const_get(:SyncCompleteEvent)
  end

  # The partial the event broadcasts into must actually exist.
  test "the broadcast partial exists" do
    assert File.exist?(Rails.root.join("app/views/open_banking_io_items/_open_banking_io_item.html.erb"))
  end
end
