require "test_helper"

class HoldingsControllerTest < ActionDispatch::IntegrationTest
  include SqlQueryCapture
  include EntriesTestHelper

  setup do
    sign_in users(:family_admin)
    @account = accounts(:investment)
    @holding = @account.holdings.first
  end

  test "gets holdings" do
    get holdings_url(account_id: @account.id)
    assert_response :success
  end

  # Each row shows its average cost, so the list loads them all together
  # rather than running the per-holding fallback once per row.
  test "the holdings list reads every row's average cost together" do
    trade_queries = [ 2, 4 ].map do |count|
      account = @account.family.accounts.create!(name: "Batch #{count}", balance: 0, cash_balance: 0, currency: "USD",
                                                 accountable: Investment.new, cost_basis_method: "fifo")
      count.times do |i|
        security = Security.create!(ticker: "HB#{count}#{i}", name: "HB#{count}#{i}")
        entry = account.entries.create!(name: "Buy", date: 2.days.ago.to_date, amount: 100, currency: "USD",
                                        entryable: Trade.new(security: security, qty: 10, price: 10, currency: "USD"))
        HoldingLot.create!(account: account, security: security, source_entry: entry, qty: 10, unit_cost: 10,
                           currency: "USD", acquired_on: entry.date)
        account.holdings.create!(security: security, date: Date.current, qty: 10, price: 12, amount: 120, currency: "USD")
      end

      queries = capture_sql_queries { get holdings_url(account_id: account.id) }
      assert_response :success
      queries.count { |sql| sql.include?('FROM "trades"') || sql.include?('FROM "holding_lots"') }
    end

    assert_equal trade_queries.first, trade_queries.last
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

  # A remap onto a position with its own opening lot merges the two. The
  # reset restates both securities, as a remap restates its target, so the
  # lots match the holdings straight away rather than at the next sync.
  test "reset_security restates both securities' lots" do
    account = users(:family_admin).family.accounts.create!(name: "Reset lots", balance: 1000, cash_balance: 1000, currency: "USD", accountable: Investment.new)
    item = users(:family_admin).family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    provider = AccountProvider.create!(account: account, provider: item.coinstats_accounts.create!(name: "Provider", currency: "USD"))
    original = Security.create!(ticker: "RSTA", name: "RSTA")
    replacement = Security.create!(ticker: "RSTB", name: "RSTB")
    [ original, replacement ].each do |security|
      Security::Price.insert_all((5.days.ago.to_date..Date.current).map { |date| { security_id: security.id, date: date, price: 30, currency: "USD" } })
    end
    create_trade(original, account: account, qty: 10, price: 40, date: 3.days.ago.to_date)
    provider_row = account.holdings.create!(security: original, date: Date.current, qty: 15, price: 30, amount: 450, currency: "USD", account_provider: provider)
    account.holdings.create!(security: replacement, date: Date.current, qty: 6, price: 30, amount: 180, currency: "USD", account_provider: provider)
    Holding::Materializer.new(account, strategy: :reverse).materialize_holdings
    assert_equal [ 5, 6 ], [ original, replacement ].map { |security| HoldingLot.opening.find_by!(security: security).qty }

    provider_row.remap_security!(replacement)
    Holding::Materializer.new(account.reload, strategy: :reverse).materialize_holdings
    merged = account.holdings.find_by!(security: replacement, date: Date.current)

    post reset_security_holding_path(merged)

    assert_redirected_to account_path(account, tab: "holdings")
    assert_not HoldingLot.exists?(security: replacement), "the replacement holds nothing once its row is reset"
    assert_equal [ [ account.id, original.id ] ].to_set, HoldingLot.in_partition([ account.id ], [ original.id ]),
      "the original's lots add up to its position again"
  end

  # The reset and its restatement are one change: a restatement that fails
  # leaves the holding, its trades and its lots where they were.
  test "a reset whose restatement fails is not applied" do
    @holding.account.update!(plaid_account: plaid_accounts(:one))
    @holding.update!(security: securities(:msft), provider_security: securities(:aapl), security_locked: true)
    Balance::Materializer.any_instance.stubs(:materialize_balances).raises(RuntimeError, "restatement failed")

    assert_raises(RuntimeError) { post reset_security_holding_path(@holding) }

    @holding.reload
    assert_equal [ securities(:msft), securities(:aapl) ], [ @holding.security, @holding.provider_security ]
  end

  test "a remap whose restatement fails is not applied" do
    original = @holding.security
    Balance::Materializer.any_instance.stubs(:materialize_balances).raises(RuntimeError, "restatement failed")

    assert_raises(RuntimeError) { patch remap_security_holding_path(@holding), params: { security_id: "MSFT|XNAS" } }

    assert_equal original, @holding.reload.security
  end

  # Both take the account row lock before any write, as a sync and a lot edit
  # do, so they serialise with them in one lock order.
  test "a reset and a remap lock the account before changing anything" do
    @holding.account.update!(plaid_account: plaid_accounts(:one))
    @holding.update!(security: securities(:msft), provider_security: securities(:aapl), security_locked: true)
    [ [ :reset_security_to_provider!, -> { post reset_security_holding_path(@holding) } ],
      [ :remap_security!, -> { patch remap_security_holding_path(@holding), params: { security_id: "NVDA|XNAS" } } ] ].each do |change, request|
      order = sequence(change.to_s)
      Account.any_instance.expects(:lock!).at_least_once.in_sequence(order).returns(true)
      Holding.any_instance.expects(change).in_sequence(order).returns(true)
      Balance::Materializer.any_instance.expects(:materialize_balances).in_sequence(order)

      request.call
      assert_redirected_to account_path(@holding.account, tab: "holdings")

      Account.any_instance.unstub(:lock!)
      Holding.any_instance.unstub(change)
      Balance::Materializer.any_instance.unstub(:materialize_balances)
    end
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
