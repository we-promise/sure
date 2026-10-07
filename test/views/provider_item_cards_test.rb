require "test_helper"

# #3630. The accounts index admits a provider card for a member as soon as
# one of its accounts is shared with them, so every card must list the
# accounts it is given, never the connection's own account list. The
# behaviour is tested per provider in AccountsControllerTest; this keeps
# every card, including one added later, on the same path.
class ProviderItemCardsTest < ActiveSupport::TestCase
  CARDS = Dir[Rails.root.join("app/views/*_items/_*_item.html.erb")].select do |path|
    File.read(path).include?("accounts/index/account_groups")
  end

  test "there are cards to check" do
    assert_operator CARDS.size, :>=, 20
  end

  CARDS.each do |path|
    card = path.delete_prefix("#{Rails.root}/")

    test "#{card} lists only the accounts it is given" do
      source = File.read(path)

      assert_match(/locals:.*visible_accounts:/, source, "#{card} must declare a visible_accounts local")
      source.scan(/render "accounts\/index\/account_groups", accounts: ([^%,]+)/).flatten.each do |accounts|
        assert_equal "visible_accounts", accounts.strip, "#{card} renders #{accounts.strip}"
      end
    end
  end

  # The on-chain wallet card is rendered by name with a card built in the
  # controller from accounts_visible_to, not from the item's own accounts.
  test "the on-chain wallet card lists only the accounts it is given" do
    source = Rails.root.join("app/views/onchain_wallet_items/_wallet_card.html.erb").read

    assert_includes source, 'render "accounts/index/account_groups", accounts: card[:accounts]'
    assert_no_match(/onchain_wallet_item\.accounts\b/, source)
  end

  test "the accounts index gives every provider card its visible accounts" do
    index = Rails.root.join("app/views/accounts/index.html.erb").read

    assert_no_match(/render @\w+_items/, index)
    assert_equal index.scan(/render item\b/).size, index.scan(/render item, visible_accounts: visible_card_accounts\(item\)/).size
  end
end
