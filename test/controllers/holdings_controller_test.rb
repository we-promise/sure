require "test_helper"

class HoldingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @account = accounts(:investment)
    @holding = @account.holdings.first
  end

  test "gets holdings" do
    get holdings_url(account_id: @account.id)
    assert_response :success
  end

  test "gets holding" do
    get holding_path(@holding)

    assert_response :success
  end

  test "shows exact share count without rounding" do
    @holding.update!(qty: 10.374)

    get holding_path(@holding)

    assert_select "##{dom_id(@holding, :shares)}", text: "10.374"
  end

  test "shows the exact stored quantity for a small crypto holding in the holdings list" do
    account = accounts(:crypto)
    security = Security.create!(
      ticker: "CRYPTO:BTC",
      name: "Bitcoin",
      exchange_operating_mic: "XCBS",
      offline: true
    )
    holding = account.holdings.create!(
      security: security,
      date: Date.current,
      qty: BigDecimal("0.000000000000000148"),
      price: 100_000,
      amount: 14.884,
      currency: "USD"
    )

    get holdings_url(account_id: account.id)

    assert_select "##{dom_id(holding)} p", text: "0.000000000000000148 shares"
  end

  test "destroys holding and associated entries" do
    assert_difference -> { Holding.count } => -1,
                      -> { Entry.count } => -1 do
      delete holding_path(@holding)
    end

    assert_redirected_to account_path(@holding.account)
    assert_empty @holding.account.entries.where(entryable: @holding.account.trades.where(security: @holding.security))
  end

  test "updates cost basis with total amount divided by qty" do
    # Given: holding with 10 shares
    @holding.update!(qty: 10, cost_basis: nil, cost_basis_source: nil, cost_basis_locked: false)

    # When: user submits total cost basis of $100 (should become $10 per share)
    patch holding_path(@holding), params: { holding: { cost_basis: "100.00" } }

    # Redirects to account page holdings tab to refresh list
    assert_redirected_to account_path(@holding.account, tab: "holdings")
    @holding.reload

    # Then: cost_basis should be per-share ($10), not total
    assert_equal 10.0, @holding.cost_basis.to_f
    assert_equal "manual", @holding.cost_basis_source
    assert @holding.cost_basis_locked?
  end

  test "updates cost basis with the submitted per-share cost" do
    @holding.update!(qty: 10, cost_basis: nil, cost_basis_source: nil, cost_basis_locked: false)

    # 10 x 0.0049 is 0.049, which a total rounded to cents would turn into 0.005
    patch holding_path(@holding), params: { holding: { per_share_cost_basis: "0.0049" } }

    @holding.reload
    assert_equal BigDecimal("0.0049"), @holding.cost_basis
    assert_equal "manual", @holding.cost_basis_source
    assert @holding.cost_basis_locked?
  end

  test "an empty cost basis is not saved as zero" do
    @holding.update!(qty: 10, cost_basis: nil, cost_basis_source: nil, cost_basis_locked: false)

    patch holding_path(@holding), params: { holding: { per_share_cost_basis: "" } }

    @holding.reload
    assert_nil @holding.cost_basis
    assert_not @holding.cost_basis_locked?
    assert_equal I18n.t("holdings.update.error"), flash[:alert]
  end

  test "cost basis editor shows the stored decimals of a per-share cost below a cent" do
    @holding.update!(qty: 10, cost_basis: 0.0049, cost_basis_locked: true)

    get holding_path(@holding)

    form_id = "#{dom_id(@holding, :drawer_cost_basis)}_holding"
    assert_select "##{form_id}_per_share_cost_basis[value='0.0049']"
    assert_select "##{form_id}_total_cost_basis[value='0.05']"
  end

  test "cost basis editor reads per share times quantity equals total" do
    @holding.update!(qty: 10, cost_basis: 12.5)

    get holding_path(@holding)

    form_id = "#{dom_id(@holding, :drawer_cost_basis)}_holding"
    assert_select "form[data-controller=cost-basis-form]" do |forms|
      rows = forms.first.element_children.select { |node| node.matches?(".form-field, p") }
      assert_equal 3, rows.size
      assert rows[0].at_css("input##{form_id}_per_share_cost_basis[name='holding[per_share_cost_basis]'][value='12.50']")
      assert_equal "× 10 shares", rows[1].text.squish
      assert rows[2].at_css("input##{form_id}_total_cost_basis:not([name])[value='125.00']")
    end
    assert_select "label[for=#{form_id}_per_share_cost_basis]", text: /\A\s*#{I18n.t("holdings.cost_basis_cell.per_share_label")}\s*\*\s*\z/
    assert_select "input##{form_id}_per_share_cost_basis[required]"
    assert_select "label[for=#{form_id}_total_cost_basis]", text: "= #{I18n.t("holdings.cost_basis_cell.total_cost_basis_label")}"
    assert_select "[data-cost-basis-form-target=perShareValue]", count: 0
  end

  test "cost basis editor keeps two decimals for zero-decimal currencies" do
    @holding.update!(qty: 2, cost_basis: 12.2, currency: "JPY")

    get holding_path(@holding)

    form_id = "#{dom_id(@holding, :drawer_cost_basis)}_holding"
    assert_select "##{form_id}_total_cost_basis[value='24.40']"
    assert_select "##{form_id}_per_share_cost_basis[value='12.20']"
  end

  # money_field#pasteAmount leaves pastes unrounded on step="any" fields.
  test "cost basis editor does not round pasted values to its display decimals" do
    get holding_path(@holding)

    assert_select "form[data-controller=cost-basis-form] [data-controller=money-field]", count: 2
    assert_select "form[data-controller=cost-basis-form] input[step=any]", count: 2
  end

  test "cost basis editor blurs its values in privacy mode" do
    get holding_path(@holding)

    assert_select "form[data-controller=cost-basis-form]" do
      assert_select "input.privacy-sensitive.privacy-sensitive-interactive", count: 2
      assert_select "span.privacy-sensitive", text: /shares\z/, count: 1
    end
  end

  test "cost basis editor submits through Turbo so the overwrite confirmation shows" do
    @holding.update!(qty: 10, cost_basis: 12.5, cost_basis_locked: true)

    get holding_path(@holding)

    assert_select "form[data-controller=cost-basis-form][data-turbo-frame=_top][data-turbo-confirm]"
    assert_select "form[data-controller=cost-basis-form][data-turbo=false]", count: 0
  end

  test "cost basis overwrite confirmation labels its button in the user's language" do
    users(:family_admin).update!(locale: "de")
    @holding.update!(qty: 10, cost_basis: 12.5, cost_basis_locked: true)

    get holding_path(@holding)

    form = css_select("form[data-controller=cost-basis-form]").first
    confirmation = JSON.parse(form["data-turbo-confirm"])
    assert_equal I18n.t("holdings.cost_basis_cell.overwrite_confirm_title", locale: :de), confirmation["title"]
    assert_equal I18n.t("shared.custom_confirm.default_btn_text", locale: :de), confirmation["confirmText"]
  end

  test "cost basis editor shows a stored zero basis instead of placeholders" do
    @holding.update!(qty: 10, cost_basis: 0, cost_basis_locked: true)

    get holding_path(@holding)

    form_id = "#{dom_id(@holding, :drawer_cost_basis)}_holding"
    assert_select "##{form_id}_per_share_cost_basis[value='0.00']"
    assert_select "##{form_id}_total_cost_basis[value='0.00']"
  end

  test "cost basis editor leaves the fields empty for an unknown zero basis" do
    # Providers report 0 when they don't know the basis; avg_cost then falls
    # back to the trades, so the editor must not offer 0 for saving.
    @holding.update!(qty: 10, cost_basis: 0, cost_basis_locked: false)

    get holding_path(@holding)

    form_id = "#{dom_id(@holding, :drawer_cost_basis)}_holding"
    assert_select "##{form_id}_per_share_cost_basis:not([value])"
    assert_select "##{form_id}_total_cost_basis:not([value])"
  end

  test "cost basis editor keeps the equation operators readable" do
    get holding_path(@holding)

    assert_select "form[data-controller=cost-basis-form] [aria-hidden]", count: 0
  end

  test "cost basis editor in the holdings list uses its own field ids" do
    holding = @account.current_holdings.first
    holding.update!(cost_basis_locked: false)

    get holdings_url(account_id: @account.id)

    assert_select "##{dom_id(holding, :popover_cost_basis)}_holding_per_share_cost_basis[name='holding[per_share_cost_basis]']", count: 1
    assert_select "[id^=drawer_cost_basis_]", count: 0
  end

  test "unlock_cost_basis removes lock" do
    # Given: locked holding
    @holding.update!(cost_basis: 50.0, cost_basis_source: "manual", cost_basis_locked: true)

    # When: user unlocks
    post unlock_cost_basis_holding_path(@holding)

    # Redirects to account page holdings tab to refresh list
    assert_redirected_to account_path(@holding.account, tab: "holdings")
    assert_equal I18n.t("holdings.unlock_cost_basis.success"), flash[:notice]
    @holding.reload

    # Then: lock is removed but cost_basis and source remain
    assert_not @holding.cost_basis_locked?
    assert_equal 50.0, @holding.cost_basis.to_f
    assert_equal "manual", @holding.cost_basis_source
  end

  test "reset_security restores the provider security and confirms it" do
    @holding.account.update!(plaid_account: plaid_accounts(:one))
    @holding.update!(security: securities(:msft), provider_security: securities(:aapl), security_locked: true)

    post reset_security_holding_path(@holding)

    assert_redirected_to account_path(@holding.account, tab: "holdings")
    assert_equal I18n.t("holdings.reset_security.success"), flash[:notice]
    assert_equal securities(:aapl), @holding.reload.security
  end

  test "remap_security brings offline security back online" do
    # Given: the target security is marked offline (e.g. created by a failed QIF import)
    msft = securities(:msft)
    msft.update!(offline: true, failed_fetch_count: 3)

    # When: user explicitly selects it from the provider search and saves
    patch remap_security_holding_path(@holding), params: { security_id: "MSFT|XNAS" }

    # Then: the security is brought back online and the holding is remapped
    assert_redirected_to account_path(@holding.account, tab: "holdings")
    @holding.reload
    msft.reload
    assert_equal msft.id, @holding.security_id
    assert_not msft.offline?
    assert_equal 0, msft.failed_fetch_count
  end

  test "sync_prices redirects with alert for offline security" do
    @holding.security.update!(offline: true)

    post sync_prices_holding_path(@holding)

    assert_redirected_to account_path(@holding.account, tab: "holdings")
    assert_equal I18n.t("holdings.sync_prices.unavailable"), flash[:alert]
  end

  test "sync_prices syncs market data and redirects with notice" do
    Security.any_instance.expects(:import_provider_prices).with(
      start_date: 31.days.ago.to_date,
      end_date: Date.current,
      clear_cache: true
    ).returns([ 31, nil ])
    Security.any_instance.stubs(:import_provider_details)
    materializer = mock("materializer")
    materializer.expects(:materialize_balances).once
    Balance::Materializer.expects(:new).with(
      @holding.account,
      strategy: :forward,
      security_ids: [ @holding.security_id ]
    ).returns(materializer)

    post sync_prices_holding_path(@holding)

    assert_redirected_to account_path(@holding.account, tab: "holdings")
    assert_equal I18n.t("holdings.sync_prices.success"), flash[:notice]
  end

  test "sync_prices shows provider error inline when provider returns no prices" do
    Security.any_instance.stubs(:import_provider_prices).returns([ 0, "Yahoo Finance rate limit exceeded" ])
    Security.any_instance.stubs(:import_provider_details)

    post sync_prices_holding_path(@holding)

    assert_redirected_to account_path(@holding.account, tab: "holdings")
    assert_equal "Yahoo Finance rate limit exceeded", flash[:alert]
  end
end
