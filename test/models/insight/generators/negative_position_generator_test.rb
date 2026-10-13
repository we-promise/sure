require "test_helper"

class Insight::Generators::NegativePositionGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    # Owned by family_admin; shared below so every active member can see it.
    @account = accounts(:investment)
    @account.account_shares.create!(user: users(:family_member), permission: "read_only")
  end

  test "flags an account whose position went below zero" do
    oversell_msft

    insights = generate

    assert_equal 1, insights.size
    insight = insights.first
    assert_equal "negative_position", insight.insight_type
    assert_equal "medium", insight.priority
    assert_equal "Holdings in Robinhood Brokerage Account went below zero", insight.title
    assert_equal "MSFT", insight.facts[:ticker]
    assert_equal "−3", insight.facts[:qty]
    assert_equal @account.id, insight.metadata[:account_id]
    assert_equal [ securities(:msft).id ], insight.metadata[:security_ids]
    assert_equal "negative_position:#{@account.id}", insight.dedup_key
  end

  test "says nothing about a normal portfolio" do
    assert_empty generate
  end

  test "skips an account that is private to one member" do
    @account.account_shares.destroy_all
    oversell_msft

    assert_empty generate
  end

  test "an existing insight leaves the feed as soon as the account is no longer shared" do
    @family.users.update_all(ai_enabled: false)
    users(:family_admin).update!(preferences: { "preview_features_enabled" => true })
    oversell_msft
    GenerateInsightsJob.perform_now(family_id: @family.id)
    assert @family.insights.visible.exists?(insight_type: "negative_position")

    @account.account_shares.destroy_all

    assert_not @family.insights.visible.exists?(insight_type: "negative_position")
  end

  # A broker's own negative quantity is a short position, not missing data.
  test "ignores negative rows a provider reports" do
    provider = AccountProvider.create!(account: @account, provider: snaptrade_accounts(:fidelity_401k))
    @account.holdings.create!(
      security: securities(:msft), date: Date.current, qty: 1, price: 400, amount: 400, currency: "USD",
      account_provider: provider
    ).update_columns(qty: -1)

    assert_empty generate
  end

  test "writes the template body in German" do
    @family.users.update_all(ai_enabled: false)
    oversell_msft

    generated = I18n.with_locale(:de) { generate.first }
    body = I18n.with_locale(:de) { Insight::BodyWriter.new(@family).write(generated) }

    assert_equal "Bestand in Robinhood Brokerage Account unter null", generated.title
    assert_match "Microsoft (MSFT)", body
    assert_match "bis −3", body
  end

  private
    def generate
      Insight::Generators::NegativePositionGenerator.new(@family).generate
    end

    # An import that records a sale without its purchase, as a provider or CSV can.
    def oversell_msft
      @account.entries.create!(
        name: "Sell 3 shares of MSFT", date: 3.days.ago.to_date, amount: -1200, currency: "USD",
        entryable: Trade.new(security: securities(:msft), qty: -3, price: 400, currency: "USD", investment_activity_label: "Sell")
      )
      Holding::Materializer.new(@account, strategy: :forward).materialize_holdings
    end
end
