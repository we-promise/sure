require "test_helper"

class SimplefinItem::RelinkServiceTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(family: @family, name: "SF Conn", access_url: "https://example.com/access")

    # Manual target
    @manual = Account.create!(family: @family, name: "Manual QS", currency: "USD", balance: 0, accountable_type: "CreditCard", accountable: CreditCard.create!)

    # SimpleFin upstream
    @sfa = @item.simplefin_accounts.create!(name: "QS", account_id: "sf_qs_service", currency: "USD", current_balance: -10, account_type: "credit")

    # Temporary provider-linked duplicate account that should be removed after relink
    @dup = Account.create!(family: @family, name: "QS dup", currency: "USD", balance: 0, accountable_type: "CreditCard", accountable: CreditCard.create!)
    AccountProvider.create!(account: @dup, provider_type: "SimplefinAccount", provider_id: @sfa.id)
  end

  test "apply! is idempotent and moves provider link to manual" do
    pairs = [ { sfa_id: @sfa.id, manual_id: @manual.id } ]

    # First apply should move provider link and delete duplicate account
    result1 = SimplefinItem::RelinkService.new.apply!(simplefin_item: @item, pairs: pairs, current_family: @family)
    ap = AccountProvider.find_by(provider_type: "SimplefinAccount", provider_id: @sfa.id)
    assert_equal @manual.id, ap.account_id
    assert_raises(ActiveRecord::RecordNotFound) { @dup.reload }
    assert_equal 1, result1.results.size

    # Second apply should be a no-op and not raise
    result2 = SimplefinItem::RelinkService.new.apply!(simplefin_item: @item, pairs: pairs, current_family: @family)
    ap2 = AccountProvider.find_by(provider_type: "SimplefinAccount", provider_id: @sfa.id)
    assert_equal @manual.id, ap2.account_id
    assert_equal 1, result2.results.size
  end
end
