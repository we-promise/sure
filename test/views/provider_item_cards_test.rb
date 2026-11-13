require "test_helper"

# #3630. The accounts index admits a provider card for a member as soon as
# one of its accounts is shared with them, so every card must list the
# accounts it is given, never the connection's own account list. The
# behaviour is tested per provider in AccountsControllerTest; this keeps
# every card, including one added later, on the same path.
class ProviderItemCardsTest < ActiveSupport::TestCase
  # The on-chain wallet's _item partial is its Settings > Providers row; its
  # accounts-page card is _wallet_card, checked separately below.
  NOT_CARDS = %w[app/views/onchain_wallet_items/_onchain_wallet_item.html.erb].freeze

  CARDS = Dir[Rails.root.join("app/views/*_items/_*_item.html.erb")].map { |path| path.delete_prefix("#{Rails.root}/") }.sort - NOT_CARDS

  CARD_PARTIALS = CARDS.map { |card| card.delete_prefix("app/views/").sub(%r{/_}, "/").delete_suffix(".html.erb") }

  RENDER_SOURCES = Dir[Rails.root.join("{app,lib}/**/*.{rb,erb,tt}")].sort

  test "there are cards to check" do
    assert_operator CARDS.size, :>=, 20
  end

  CARDS.each do |card|
    item_local = File.basename(card, ".html.erb").delete_prefix("_").to_sym

    test "#{card} lists only the accounts it is given" do
      source = Rails.root.join(card).read

      assert_match(/locals:.*visible_accounts:/, source, "#{card} must declare a visible_accounts local")
      source.scan(/render "accounts\/index\/account_groups", accounts: ([^%,]+)/).flatten.each do |accounts|
        assert_equal "visible_accounts", accounts.strip, "#{card} renders #{accounts.strip}"
      end
    end

    # Fail closed: a render that forgets visible_accounts must raise, not fall
    # back to every account on the connection.
    test "#{card} refuses to render without visible_accounts" do
      error = assert_raises(StandardError) do
        ApplicationController.render(partial: CARD_PARTIALS[CARDS.index(card)], locals: { item_local => Object.new })
      end

      assert_match(/missing local: :visible_accounts\b/, error.message, "#{card} must require visible_accounts with no default")
    end
  end

  # Every render of a card by partial name, including the provider generator's
  # template. Each must hand the card its accounts explicitly.
  CARD_REFERENCE = Regexp.union(*CARD_PARTIALS.map { |partial| %("#{partial}") }, %("<%= file_name %>_items/<%= file_name %>_item"))

  CARD_NAMES = CARD_PARTIALS.map { |partial| partial.split("/").last }

  test "every render of a provider card passes visible_accounts" do
    sites = RENDER_SOURCES.flat_map do |file|
      source = File.read(file)

      source.enum_for(:scan, CARD_REFERENCE).map do
        offset = Regexp.last_match.begin(0)
        call = source[offset..][/\A[^)]*/]
        site = "#{file.delete_prefix("#{Rails.root}/")}:#{source[0...offset].count("\n") + 1}"

        assert_includes call, "visible_accounts:", "#{site} renders a provider card without visible_accounts"
        site
      end
    end

    # The 12 admin-only controller responses. Sync completions, jobs and the
    # SimpleFIN syncer no longer render a card at all.
    assert_operator sites.size, :>=, 12, "found only #{sites.size} render sites; has the scan stopped matching?"
  end

  test "no provider card is rendered by model, which cannot pass visible_accounts" do
    by_model = /render[ (]+@?(?:#{CARD_NAMES.join("|")})s?\b(?!:)/

    RENDER_SOURCES.each do |file|
      assert_no_match by_model, File.read(file), "#{file.delete_prefix("#{Rails.root}/")} renders a provider card by model"
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
