require "test_helper"

class ReportsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper
  include SqlQueryCapture

  TAGGED_MONTH = Date.new(2021, 3, 1)
  BIGGEST_MONTH = Date.new(2020, 6, 1)

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
  end

  test "renders sections in the order and collapse state stored under the reports keys" do
    @user.update_columns(preferences: (@user.preferences || {}).merge(
      "reports_section_order" => %w[transactions_breakdown trends_insights],
      "reports_collapsed_sections" => { "trends_insights" => true }
    ))

    get reports_path

    assert_response :success
    keys = css_select("[data-section-key]").map { |node| node["data-section-key"] }
    assert_equal %w[transactions_breakdown trends_insights], keys.first(2)
    assert_select "[data-section-key=trends_insights][data-reports-section-collapsed-value=?]", "true"
    assert_select "[data-section-key=transactions_breakdown][data-reports-section-collapsed-value=?]", "false"
    assert_select "[data-section-key=trends_insights] > details:not([open])"
    assert_select "[data-section-key=transactions_breakdown] > details[open]"
  end

  # Reports renders the shared section list with its own endpoint, param and
  # labels, and leaves the collapse control on its default endpoint.
  test "the section list posts to the reports endpoint under the reports keys" do
    get reports_path

    assert_response :success
    assert_select "[data-controller~=sortable-list][data-sortable-list-url-value=?][data-sortable-list-param-value=?][aria-label=?]",
                  update_preferences_reports_path, "preferences.reports_section_order", I18n.t("reports.index.sections_aria")
    assert_select "[data-section-key=net_worth][aria-label=?]",
                  "#{I18n.t("reports.net_worth.title")} section. Press Enter or Space to grab for reordering, then use arrow keys to move."
    assert_select "[data-section-key=net_worth] > details > summary h2", text: I18n.t("reports.net_worth.title")
    assert_select "[data-reports-section-url-value], [data-reports-section-preference-key-value]", count: 0
  end

  test "the reports preferences endpoint stores order and collapse under the reports keys" do
    @user.update_columns(preferences: (@user.preferences || {}).merge("reports_collapsed_sections" => { "net_worth" => true }))

    patch update_preferences_reports_path,
      params: { preferences: { reports_section_order: %w[trends_insights net_worth], reports_collapsed_sections: { trends_insights: true } } },
      as: :json

    assert_response :ok
    @user.reload
    assert_equal %w[trends_insights net_worth], @user.preferences["reports_section_order"]
    assert_equal({ "net_worth" => true, "trends_insights" => true }, @user.preferences["reports_collapsed_sections"])
  end

  test "a scalar section order is not stored and the page still renders" do
    @user.update_columns(preferences: (@user.preferences || {}).merge("reports_section_order" => %w[trends_insights net_worth]))

    patch update_preferences_reports_path, params: { preferences: { reports_section_order: "x" } }, as: :json

    assert_response :ok
    assert_equal %w[trends_insights net_worth], @user.reload.preferences["reports_section_order"]

    get reports_path
    assert_response :success
  end

  test "a scalar collapsed set is not stored" do
    @user.update_columns(preferences: (@user.preferences || {}).merge("reports_collapsed_sections" => { "net_worth" => true }))

    patch update_preferences_reports_path, params: { preferences: { reports_collapsed_sections: "net_worth" } }, as: :json

    assert_response :ok
    assert_equal({ "net_worth" => true }, @user.reload.preferences["reports_collapsed_sections"])
  end

  test "a preferences body that is not an object is refused and writes nothing" do
    before = @user.reload.preferences

    patch update_preferences_reports_path, params: { preferences: "x" }, as: :json

    assert_response :bad_request
    assert_equal before, @user.reload.preferences
  end

  # The per-trade line under the realised-gains card rendered
  # `Money.new(gain.value, Current.family.currency)` -- taking the number out of
  # the Trend and re-labelling it as family currency with no conversion at all.
  #
  # The fixture has to be a FOREIGN ACCOUNT for that to show: a gain is carried
  # in the currency its position is held in, so for a USD account under a USD
  # family the re-labelling is accidentally correct and a test built on one
  # passes either way.
  #
  # A USD family, a EUR account, a EUR-listed security: basis 100 EUR/share, 2
  # sold at 150 EUR/share, EUR->USD 1.5 that day. The gain is 100 EUR, and the
  # line must read $150.00. Re-labelled rather than converted it reads $100.00.
  test "a foreign-account disposal is listed in family currency, not re-labelled" do
    date = Date.current.beginning_of_month
    account = @family.accounts.create!(name: "Brokerage EUR", balance: 10_000,
                                       currency: "EUR", accountable: Investment.new)
    security = Security.create!(ticker: "EUX#{SecureRandom.hex(3)}", name: "Euro Listed")

    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: date, rate: 1.5)
    account.holdings.create!(security: security, date: date, qty: 5, price: 150,
                             amount: BigDecimal(750), currency: "EUR", cost_basis: 100)
    create_trade(security, account: account, qty: -2, date: date, price: 150, currency: "EUR")

    get reports_path
    assert_response :ok

    line = css_select("[data-testid='realized-gain-line']").map(&:text)
                                                           .find { |text| text.include?(security.ticker) }

    assert line, "the disposal must be listed at all, or this proves nothing"
    assert_match "$150.00", line, "converted at the trade's own rate"
    assert_no_match(/\$100\.00/, line, "$100.00 is the EUR figure printed with a dollar sign")
  end

  # A position carried in a THIRD currency -- not the disposal's, not the
  # account's. 300 EUR of proceeds at 0.8 is 240 GBP, less 200 GBP of basis, so
  # 40 GBP and $50.00 at 1.25. GBP is in neither currency set the card used to
  # enumerate, and a currency it does not enumerate converts at the `|| 1`
  # parity fallback: the line would read $40.00.
  test "a disposal carried in a third currency is converted, not passed through at parity" do
    date = Date.current.beginning_of_month
    account = @family.accounts.create!(name: "Brokerage USD", balance: 10_000,
                                       currency: "USD", accountable: Investment.new)
    security = Security.create!(ticker: "EUX#{SecureRandom.hex(3)}", name: "Euro Listed")

    # The fixtures already hold EUR->GBP for today and yesterday, so on the 1st
    # and 2nd of a month a fresh row for its first day breaks uniqueness.
    ExchangeRate.find_or_initialize_by(from_currency: "EUR", to_currency: "GBP", date: date).update!(rate: 0.8)
    ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", date: date, rate: 1.25)
    account.holdings.create!(security: security, date: date, qty: 5, price: 150,
                             amount: BigDecimal(750), currency: "GBP", cost_basis: 100)
    create_trade(security, account: account, qty: -2, date: date, price: 150, currency: "EUR")

    get reports_path
    assert_response :ok

    line = css_select("[data-testid='realized-gain-line']").map(&:text)
                                                           .find { |text| text.include?(security.ticker) }

    assert line, "the disposal must be listed at all, or this proves nothing"
    assert_match "$50.00", line
    assert_no_match(/\$40\.00/, line, "$40.00 is the GBP figure converted at parity")
  end

  # No JPY->USD rate for the day of a disposal in a JPY account. The gain is
  # ¥100,000 and there is nothing to convert it with: converted at 1 it read
  # as $100,000.00 (#3640). It is left out of the total, its own line shows no
  # figure, and the card says a gain is missing.
  test "a disposal with no rate into family currency is left out and the card says so" do
    ExchangeRate.stubs(:provider).returns(nil)
    date = Date.current.beginning_of_month
    account = @family.accounts.create!(name: "Brokerage JPY", balance: 1_000_000,
                                       currency: "JPY", accountable: Investment.new)
    security = Security.create!(ticker: "JPX#{SecureRandom.hex(3)}", name: "Tokyo Listed")
    ExchangeRate.where(from_currency: "JPY", to_currency: "USD").delete_all

    account.holdings.create!(security: security, date: date, qty: 5, price: 150_000,
                             amount: BigDecimal(750_000), currency: "JPY", cost_basis: 100_000)
    create_trade(security, account: account, qty: -2, date: date, price: 150_000, currency: "JPY")

    get reports_path
    assert_response :ok

    line = css_select("[data-testid='realized-gain-line']").map(&:text)
                                                           .find { |text| text.include?(security.ticker) }

    assert line, "the disposal must be listed at all, or this proves nothing"
    assert_no_match(/\$100,000\.00/, line, "$100,000.00 is the yen figure converted at parity")
    assert_select "[data-testid='unconverted-gains-note']", text: /no exchange rate to USD/
    assert_no_match(/\$100,000\.00/, response.body, "nor is it in any total")
  end

  # A sale priced in EUR from a USD position, with no EUR->USD rate on any
  # date: Trade has no figure for it. The card used to skip it as though it
  # had no cost basis, so its total was partial without saying so.
  test "a sale with no rate between its own currencies is counted as left out" do
    ExchangeRate.stubs(:provider).returns(nil)
    date = Date.current.beginning_of_month
    account = @family.accounts.create!(name: "Brokerage USD", balance: 10_000,
                                       currency: "USD", accountable: Investment.new)
    security = Security.create!(ticker: "EUX#{SecureRandom.hex(3)}", name: "Euro Listed")
    ExchangeRate.where(from_currency: "EUR", to_currency: "USD").delete_all

    account.holdings.create!(security: security, date: date, qty: 5, price: 150,
                             amount: BigDecimal(750), currency: "USD", cost_basis: 100)
    create_trade(security, account: account, qty: -2, date: date, price: 150, currency: "EUR")

    get reports_path
    assert_response :ok

    assert_select "[data-testid='unconverted-gains-note']", text: /1 gain is not included/
  end

  # The same for an open position: a JPY holding showing a ¥250,000 gain with
  # no JPY->USD rate is not $250,000 of unrealised gain. At parity the gains
  # card and the Total Return card both read $250,010.00, the yen figure plus
  # the fixtures' $10, and Portfolio Value read $1,020,000.00.
  test "a holding with no rate into family currency is left out of unrealised gains" do
    ExchangeRate.stubs(:provider).returns(nil)
    account = @family.accounts.create!(name: "Brokerage JPY", balance: 1_000_000,
                                       currency: "JPY", accountable: Investment.new)
    security = Security.create!(ticker: "JPX#{SecureRandom.hex(3)}", name: "Tokyo Listed")
    ExchangeRate.where(from_currency: "JPY", to_currency: "USD").delete_all

    account.holdings.create!(security: security, date: Date.current, qty: 5, price: 150_000,
                             amount: BigDecimal(750_000), currency: "JPY", cost_basis: 100_000)

    get reports_path
    assert_response :ok

    assert_no_match(/\$250,0\d\d\.\d\d/, response.body, "the yen gain is in a total, converted at parity")
    assert_no_match(/\$1,020,000\.00/, response.body, "the yen account is in Portfolio Value, converted at parity")
    assert_select "[data-testid='unconverted-gains-note']", text: /1 gain is not included/
    assert_select "[data-testid='missing-exchange-rates']", text: /No exchange rate from JPY to USD is stored yet, so some totals may leave out amounts in JPY/
  end

  # Each holding's line under the card is the same arithmetic as the card's
  # total: converted into family currency, or "no data" without a rate. It
  # used to re-label the yen figure as dollars.
  test "a holding's gain line is converted, or shows no data without a rate" do
    ExchangeRate.stubs(:provider).returns(nil)
    account = @family.accounts.create!(name: "Brokerage JPY", balance: 1_000_000,
                                       currency: "JPY", accountable: Investment.new)
    security = Security.create!(ticker: "JPL#{SecureRandom.hex(3)}", name: "Tokyo Listed")
    account.holdings.create!(security: security, date: Date.current, qty: 5, price: 150_000,
                             amount: BigDecimal(750_000), currency: "JPY", cost_basis: 100_000)
    ExchangeRate.where(from_currency: "JPY", to_currency: "USD").delete_all

    get reports_path
    line = css_select("div.pl-2").find { |div| div.text.include?(security.ticker) }
    assert line, "the holding is listed"
    assert_match(/#{Regexp.escape(I18n.t("reports.investment_performance.no_data"))}/, line.text)
    assert_no_match(/\$250,000\.00/, line.text, "the yen gain re-labelled as dollars")

    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: Date.current, rate: 0.0067)
    get reports_path
    line = css_select("div.pl-2").find { |div| div.text.include?(security.ticker) }
    assert_match(/\$1,675\.00/, line.text, "250,000 JPY at 0.0067")
  end

  # The rates a page of disposals needs come from one query, not one per
  # foreign disposal. The conversion itself is covered in TradeTest, which
  # counts the queries directly; what has to hold HERE is that the card asks
  # for the preload at all -- the page's own rate lookups share a SQL shape
  # with `ExchangeRate.find_or_fetch_rate`, so counting them measures the rest
  # of the page rather than this.
  test "the card preloads the rates its disposals need" do
    account = @family.accounts.create!(name: "Brokerage USD", balance: 50_000,
                                       currency: "USD", accountable: Investment.new)
    seed_foreign_disposals(account, 3)

    Trade.expects(:preload_exchange_rates).at_least_once.with do |trades|
      trades.any? { |trade| trade.currency == "EUR" }
    end

    get reports_path

    assert_response :ok
  end

  # Under fifo each sale's basis is read from what it took from each lot. The
  # card reads those for every sale in one query, not one per sale.
  test "the card preloads the lot disposals its fifo sales read" do
    date = Date.current.beginning_of_month
    account = @family.accounts.create!(name: "Brokerage FIFO", balance: 10_000, currency: "USD",
                                       cost_basis_method: "fifo", accountable: Investment.new)
    security = Security.create!(ticker: "FIF#{SecureRandom.hex(3)}", name: "Fifo Listed")
    create_trade(security, account: account, qty: 60, date: date - 20, price: 12)
    create_trade(security, account: account, qty: 40, date: date - 10, price: 20)
    create_trade(security, account: account, qty: -10, date: date, price: 25)
    create_trade(security, account: account, qty: -60, date: date, price: 25)
    Holding::Materializer.new(account, strategy: :forward).materialize_holdings

    queries = capture_sql_queries { get reports_path }

    assert_response :ok
    lines = css_select("[data-testid='realized-gain-line']").map(&:text).select { |text| text.include?(security.ticker) }
    assert_equal 2, lines.size, "both sales must be listed, or this proves nothing"
    assert lines.any? { |text| text.include?("$130.00") }, "10 x (25 - 12), the oldest lot"
    assert_equal 1, queries.count { |sql| sql.include?(%("holding_lot_disposals")) }, "one preload, not one per sale"
  end

  test "index renders successfully" do
    get reports_path
    assert_response :ok
  end

  test "index sections keep data-section-key next to the sortable id" do
    get reports_path
    assert_response :ok

    assert_select "section[data-sortable-list-id]" do |sections|
      assert sections.any?
      sections.each do |section|
        assert_equal section["data-sortable-list-id"], section["data-section-key"]
      end
    end
  end

  test "spending vs normal is a preview section" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))
    get reports_path
    assert_select "section[data-section-key='spending_vs_normal']", count: 0

    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    # The treemap only draws spending inside the period, which for the current
    # month runs up to today; fixture transactions are dated a few days ago, so
    # on the 1st there would be nothing to draw.
    create_transaction(date: Date.current, amount: 50, category: categories(:food_and_drink))
    get reports_path
    assert_response :ok
    assert_select "section[data-section-key='spending_vs_normal']" do
      assert_select "[data-controller='spending-treemap']"
    end
  end

  test "the spending baseline starts at the first transaction in the user's own finances" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family.entries.where(entryable_type: "Transaction").destroy_all
    hidden = Account.create!(family: @family, owner: users(:family_member), name: "Not shared", currency: @family.currency, balance: 0, accountable: Depository.new)
    create_transaction(account: hidden, date: 200.days.ago.to_date, amount: 10)
    own_first = 100.days.ago.to_date
    create_transaction(account: accounts(:depository), date: own_first, amount: 10)

    get reports_path

    baseline = controller.instance_variable_get(:@spending_comparison).baseline_period
    assert_equal own_first, baseline.start_date
  end

  # The desktop app clones these into the tray when a download such as the CSV
  # export ends, since it has no download list of its own, and reads their data
  # attributes for its native notification.
  test "index provides the download toasts the desktop app shows" do
    get reports_path

    assert_response :ok
    scope = "layouts.shared.notification_tray"
    assert_select "template#desktop-download-complete", 1
    assert_select "template#desktop-download-failed", 1
    assert_select "template#desktop-download-complete[data-message=?][data-description=?]",
      I18n.t("#{scope}.download_complete"), I18n.t("#{scope}.download_location")
    assert_select "template#desktop-download-failed[data-message=?]", I18n.t("#{scope}.download_failed")
    assert_includes response.body, I18n.t("#{scope}.download_complete")
    assert_includes response.body, I18n.t("#{scope}.download_location")
    assert_includes response.body, I18n.t("#{scope}.download_failed")
  end

  test "index with monthly period" do
    get reports_path(period_type: :monthly)
    assert_response :ok
    assert_select "h1", text: I18n.t("reports.index.title")
  end

  test "index with quarterly period" do
    get reports_path(period_type: :quarterly)
    assert_response :ok
  end

  test "index with ytd period" do
    get reports_path(period_type: :ytd)
    assert_response :ok
  end

  test "index with custom period and date range" do
    get reports_path(
      period_type: :custom,
      start_date: 1.month.ago.to_date.to_s,
      end_date: Date.current.to_s
    )
    assert_response :ok
  end

  test "a body warmed outside a request is what the page serves" do
    with_memory_cache do
      assert ReportsController.warm_body_cache(user: @user, query: { period_type: :ytd })
      assert_not ReportsController.warm_body_cache(user: @user, query: { period_type: :ytd }), "already warm"

      ReportsController.any_instance.expects(:setup_report_data).never
      get reports_path(period_type: :ytd)

      assert_response :ok
      assert_select "[data-sortable-list-target=item]"
    end
  end

  test "a built body is kept for as many days as the page cache setting says" do
    with_env_overrides PAGE_CACHE_DAYS: nil do
      Setting.stubs(:page_cache_days).returns(30)
      store = ActiveSupport::Cache::MemoryStore.new
      Rails.stubs(:cache).returns(store)
      store.stubs(:write).returns(true)
      store.expects(:write).with(regexp_matches(/\Areports_body\//), anything, expires_in: 30.days).returns(true)

      assert ReportsController.warm_body_cache(user: @user, query: { period_type: :ytd })
    end
  end

  test "after the data changes, the old build is served while a rebuild is queued" do
    with_memory_cache do
      get reports_path(period_type: :ytd)
      assert_select "[data-testid=report-built-at]", text: /#{I18n.t("reports.index.updating")}/, count: 0

      travel Setting.page_cache_cooldown + 1.minute do
        @family.entries.first.touch
        ReportsController.any_instance.expects(:render_report_body).never

        assert_enqueued_with(job: RebuildReportJob, args: [ @user, { period_type: "ytd" }, "en" ]) do
          get reports_path(period_type: :ytd)
        end
        assert_response :ok
        assert_select "[data-sortable-list-target=item]"
        assert_select "[data-testid=report-built-at]", text: /#{I18n.t("reports.index.updating")}/

        assert_no_enqueued_jobs(only: RebuildReportJob) { get reports_path(period_type: :ytd) }
      end
    end
  end

  test "a stale build is not rebuilt again within the cooldown" do
    with_memory_cache do
      get reports_path(period_type: :ytd)
      @family.entries.first.touch

      assert_no_enqueued_jobs(only: RebuildReportJob) { get reports_path(period_type: :ytd) }
      assert_select "[data-testid=report-built-at]", text: /#{I18n.t("reports.index.updating")}/
    end
  end

  test "refresh rebuilds the report straight away and drops itself from the URL" do
    with_memory_cache do
      get reports_path(period_type: :ytd)
      @family.entries.first.touch

      ReportsController.any_instance.expects(:render_report_body).once
        .returns({ notes: "", has_transactions: true, summary: "<p id=rebuilt></p>", sections: [] })
      get reports_path(period_type: :ytd, refresh: 1)
      assert_redirected_to reports_path(period_type: :ytd)

      follow_redirect!
      assert_select "#rebuilt"
      assert_select "[data-testid=report-built-at]", text: /#{I18n.t("reports.index.updating")}/, count: 0
    end
  end

  test "refresh shows a report too big to keep as built, without building it again" do
    with_memory_cache do
      PageCache.stubs(:max_bytes).returns(0)

      ReportsController.any_instance.expects(:render_report_body).once
        .returns({ notes: "", has_transactions: true, summary: "<p id=rebuilt></p>", sections: [] })
      get reports_path(period_type: :ytd, refresh: 1)

      assert_response :ok
      assert_select "#rebuilt"
    end
  end

  test "a default period keeps its cached build from one day to the next" do
    with_memory_cache do
      get reports_path(period_type: :all_time)

      travel 1.day do
        ReportsController.any_instance.expects(:render_report_body).never
        get reports_path(period_type: :all_time)

        assert_response :ok
        assert_select "[data-testid=report-built-at]", text: /#{I18n.t("reports.index.updating")}/
      end
    end
  end

  test "arranging the sections reorders the cached report rather than rebuilding it" do
    with_memory_cache do
      ReportsController.warm_body_cache(user: @user, query: { period_type: :ytd })
      @user.update!(preferences: (@user.preferences || {}).merge(
        "reports_section_order" => %w[transactions_breakdown trends_insights],
        "reports_collapsed_sections" => { "trends_insights" => true }
      ))

      ReportsController.any_instance.expects(:render_report_body).never
      get reports_path(period_type: :ytd)

      keys = css_select("[data-sortable-list-target=item]").map { |node| node["data-section-key"] }
      assert_equal %w[transactions_breakdown trends_insights], keys.first(2)
      assert_select "section[data-section-key=trends_insights] details:not([open])"
    end
  end

  test "warming several members builds each one's report from their own accounts" do
    member = users(:family_member)
    @family.accounts.create!(name: "Admin only", balance: 0, currency: "USD", accountable: Depository.new, owner: @user)
    assert_not_equal @user.accessible_accounts.pluck(:id).sort, member.accessible_accounts.pluck(:id).sort

    seen = {}
    ReportsController.any_instance.stubs(:render_report_body).with do
      seen[Current.user.id] = Current.accessible_accounts.map(&:id).sort
      true
    end.returns({ notes: "", has_transactions: false, summary: "", sections: [] })

    with_memory_cache do
      ReportsController.warm_body_cache(user: @user, query: { period_type: :ytd })
      ReportsController.warm_body_cache(user: member, query: { period_type: :ytd })
    end

    assert_equal @user.accessible_accounts.pluck(:id).sort, seen[@user.id]
    assert_equal member.accessible_accounts.pluck(:id).sort, seen[member.id]
  end

  test "losing access to an account is never answered with a report built before" do
    member = users(:family_member)
    sign_in member

    with_memory_cache do
      get reports_path(period_type: :ytd)
      assert_response :ok

      account_shares(:depository_shared_with_member).destroy!
      ReportsController.any_instance.expects(:render_report_body).once
        .returns({ notes: "", has_transactions: true, summary: "<p id=rebuilt></p>", sections: [] })
      get reports_path(period_type: :ytd)

      assert_select "#rebuilt"
      assert_select "[data-testid=report-built-at]", text: /#{I18n.t("reports.index.updating")}/, count: 0
    end
  end

  test "each sort and filter of the breakdown is its own cached report" do
    with_memory_cache do
      get reports_path(period_type: :ytd)

      ReportsController.any_instance.expects(:render_report_body).twice
        .returns({ notes: "", has_transactions: true, summary: "<p id=rebuilt></p>", sections: [] })
      get reports_path(period_type: :ytd, sort_by: "count", sort_direction: "asc")
      assert_select "#rebuilt"
      get reports_path(period_type: :ytd, filter_account_id: accounts(:depository).id)
      assert_select "#rebuilt"
    end
  end

  test "a background rebuild repeats the page's sort and filters" do
    with_memory_cache do
      get reports_path(period_type: :ytd, sort_by: "count", filter_account_id: accounts(:depository).id)

      travel Setting.page_cache_cooldown + 1.minute do
        @family.entries.first.touch
        assert_enqueued_with(job: RebuildReportJob,
          args: [ @user, { filter_account_id: accounts(:depository).id, period_type: "ytd", sort_by: "count" }, "en" ]) do
          get reports_path(period_type: :ytd, sort_by: "count", filter_account_id: accounts(:depository).id)
        end
      end
    end
  end

  test "a report warmed in the background is in the member's own language" do
    @user.update!(locale: "de")

    with_memory_cache do
      ReportsController.warm_body_cache(user: @user, query: { period_type: :ytd })

      ReportsController.any_instance.expects(:render_report_body).never
      get reports_path(period_type: :ytd)
      assert_response :ok
    end
  end

  test "a stale build in the language the page asked for is rebuilt in that language" do
    with_memory_cache do
      get reports_path(period_type: :ytd, locale: "de")

      travel Setting.page_cache_cooldown + 1.minute do
        @family.entries.first.touch
        assert_enqueued_with(job: RebuildReportJob, args: [ @user, { period_type: "ytd" }, "de" ]) do
          get reports_path(period_type: :ytd, locale: "de")
        end
        perform_enqueued_jobs(only: RebuildReportJob)

        ReportsController.any_instance.expects(:render_report_body).never
        get reports_path(period_type: :ytd, locale: "de")
        assert_select "[data-testid=report-built-at]", text: /#{I18n.t("reports.index.updating", locale: :de)}/, count: 0
      end
    end
  end

  test "the plain Reports page is served from the build warmed for this month" do
    with_memory_cache do
      ReportsController.warm_body_cache(user: @user, query: { period_type: :monthly })

      ReportsController.any_instance.expects(:render_report_body).never
      get reports_path
      assert_response :ok
    end
  end

  test "a blank period is this month's report, so the plain page can be served from it" do
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current.beginning_of_month)
    budget.budget_categories.find_or_initialize_by(category: @family.categories.expenses.first)
          .update!(budgeted_spending: Money.new(50000, @family.currency))

    with_memory_cache do
      get reports_path(period_type: "")
      assert_select "p", text: I18n.t("reports.summary.of_budget_used")

      ReportsController.any_instance.expects(:render_report_body).never
      get reports_path
      assert_select "p", text: I18n.t("reports.summary.of_budget_used")
    end
  end

  test "changing whether investment contributions count as spending builds the report again" do
    with_memory_cache do
      get reports_path(period_type: :ytd)
      @family.update!(investment_contributions_as_spending: !@family.investment_contributions_as_spending)

      ReportsController.any_instance.expects(:render_report_body).once.returns({ notes: "", has_transactions: false, summary: "", sections: [] })
      get reports_path(period_type: :ytd)
    end
  end

  test "assigning a tag marks the cached report stale" do
    with_memory_cache do
      get reports_path(period_type: :ytd)

      travel Setting.page_cache_cooldown + 1.minute do
        transactions(:one).update!(tag_ids: [ tags(:one).id ])
        assert_enqueued_with(job: RebuildReportJob) { get reports_path(period_type: :ytd) }
      end
    end
  end

  test "a new month's report is built, not served from last month's" do
    with_memory_cache do
      travel_to Date.new(2026, 11, 30).noon do
        get reports_path
      end

      travel_to Date.new(2026, 12, 1).noon do
        ReportsController.any_instance.expects(:render_report_body).once.returns({ notes: "", has_transactions: false, summary: "", sections: [] })
        get reports_path
      end
    end
  end

  test "year to date keeps its build from one day to the next, though it ends today" do
    with_memory_cache do
      travel_to Date.new(2026, 11, 20).noon do
        get reports_path(period_type: :ytd)
      end

      travel_to Date.new(2026, 11, 21).noon do
        ReportsController.any_instance.expects(:render_report_body).never
        get reports_path(period_type: :ytd)
        assert_response :ok
      end
    end
  end

  test "editing a holding's cost basis marks the cached report stale" do
    with_memory_cache do
      get reports_path(period_type: :ytd)

      travel Setting.page_cache_cooldown + 1.minute do
        holdings(:one).set_manual_cost_basis!(80)
        assert_enqueued_with(job: RebuildReportJob) { get reports_path(period_type: :ytd) }
      end
    end
  end

  test "each member gets their own cached body" do
    with_memory_cache do
      ReportsController.warm_body_cache(user: @user, query: { period_type: :ytd })
      other = @family.users.where.not(id: @user.id).first
      assert other, "fixtures need a second member"

      assert ReportsController.warm_body_cache(user: other, query: { period_type: :ytd })
    end
  end

  test "all time runs from the member's first transaction or trade to today" do
    first = @family.earliest_activity_date
    assert first, "fixtures need a transaction or trade"

    get reports_path(period_type: :all_time)

    assert_response :ok
    assert_select "a[aria-current]", text: I18n.t("reports.index.periods.all_time")
    assert_includes @response.body, I18n.t("reports.index.period_label.all_time",
      start: I18n.l(first, format: :short_month_year), end: I18n.l(Date.current, format: :short_month_year))
    assert_includes @response.body, first.strftime("%b %Y")
    assert_not_includes @response.body, (first - 1.month).strftime("%b %Y")
  end

  test "all time doesn't start at activity in an account the member can't see" do
    member = users(:family_member)
    hidden = @family.accounts.create!(name: "Admin's old account", balance: 0, currency: "USD",
      accountable: Depository.new, owner: @user)
    hidden.entries.create!(date: Date.new(2001, 2, 3), name: "Old", amount: 10, currency: "USD", entryable: Transaction.new)
    assert_not member.finance_accounts.include?(hidden), "the member must not see the account"

    sign_in member
    get reports_path(period_type: :all_time)

    assert_response :ok
    assert_not_includes @response.body, "2001-02-03"
    assert_not_includes @response.body, I18n.l(Date.new(2001, 2, 3), format: :short_month_year)
  end

  test "all time ignores scheduled entries after today" do
    @family.entries.where(entryable_type: %w[Transaction Trade]).delete_all
    account = @family.accounts.first
    account.entries.create!(date: 1.month.from_now.to_date, name: "Scheduled", amount: 10, currency: "USD", entryable: Transaction.new)

    get reports_path(period_type: :all_time)

    assert_response :ok
    assert_nil flash[:alert]
    assert_includes @response.body, I18n.t("reports.index.period_label.all_time",
      start: I18n.l(Date.current.beginning_of_month, format: :short_month_year), end: I18n.l(Date.current, format: :short_month_year))
  end

  test "all time has no previous period to compare with" do
    get reports_path(period_type: :all_time)

    assert_response :ok
    assert_not_includes @response.body, I18n.t("reports.summary.vs_previous")
  end

  test "index with last 6 months period" do
    get reports_path(period_type: :last_6_months)
    assert_response :ok

    expected_end   = Date.current.end_of_month
    expected_start = (expected_end + 1.day - 6.months).beginning_of_month

    # Should show exactly 6 months, not 7
    assert_equal 6, (expected_end.year * 12 + expected_end.month) - (expected_start.year * 12 + expected_start.month) + 1

    # Page should include both boundary months
    assert_includes @response.body, expected_start.strftime("%b %Y")
    assert_includes @response.body, expected_end.strftime("%b %Y")

    # Page should NOT include the months immediately outside the window
    prev_month = expected_start - 1.month
    next_month = expected_end + 1.month
    assert_not_includes @response.body, prev_month.strftime("%b %Y")
    assert_not_includes @response.body, next_month.strftime("%b %Y")
  end

  test "last 12 months uses a twelve month window" do
    get reports_path(period_type: :last_12_months)
    assert_response :ok

    expected_end   = Date.current.end_of_month
    expected_start = (expected_end + 1.day - 12.months).beginning_of_month

    assert_includes @response.body, expected_start.strftime("%b %Y")
    assert_includes @response.body, expected_end.strftime("%b %Y")
  end

  test "last 12 months navigation shifts by twelve months" do
    latest_start = (Date.current.end_of_month + 1.day - 12.months).beginning_of_month
    start_date   = latest_start - 24.months
    end_date     = start_date + 12.months - 1.day

    get reports_path(period_type: :last_12_months, start_date: start_date, end_date: end_date)
    assert_response :ok

    prev_end = start_date - 1.day
    next_start = start_date + 12.months
    next_end = next_start + 12.months - 1.day

    assert_select "a[href*='start_date=#{(start_date - 12.months).iso8601}'][href*='end_date=#{prev_end.iso8601}']", minimum: 1
    assert_select "a[href*='start_date=#{next_start.iso8601}'][href*='end_date=#{next_end.iso8601}']", minimum: 1
  end

  test "last 12 months next link clamps at the latest window" do
    latest_start = (Date.current.end_of_month + 1.day - 12.months).beginning_of_month
    # A start inside the latest window: a plain twelve-month step would end
    # after today, so the link has to clamp.
    start_date = latest_start - 5.months
    end_date   = start_date + 12.months - 1.day

    get reports_path(period_type: :last_12_months, start_date: start_date, end_date: end_date)
    assert_response :ok

    unclamped_start = start_date + 12.months
    unclamped_end = unclamped_start + 12.months - 1.day

    assert_select "a[href*='start_date=#{latest_start.iso8601}'][href*='end_date=#{Date.current.end_of_month.iso8601}']", minimum: 1
    assert_select "a[href*='start_date=#{unclamped_start.iso8601}'][href*='end_date=#{unclamped_end.iso8601}']", count: 0
  end

  test "last 6 months default start date is consistent with navigation" do
    # First load (no params) should produce the same start/end as the navigation arrows would
    get reports_path(period_type: :last_6_months)
    assert_response :ok

    expected_end   = Date.current.end_of_month
    expected_start = (expected_end + 1.day - 6.months).beginning_of_month

    # Navigate forward from one window back — should land on the same default window
    prev_start = expected_start - 6.months
    prev_end   = prev_start + 6.months - 1.day

    get reports_path(period_type: :last_6_months, start_date: prev_start, end_date: prev_end)
    assert_response :ok

    # The next-window link should point to the same dates as the default
    assert_select "a[href=?]",
      reports_path(period_type: :last_6_months, start_date: expected_start, end_date: expected_end)
  end

  test "index shows empty state when no transactions" do
    # Delete all transactions for the family by deleting from accounts
    @family.accounts.each { |account| account.entries.destroy_all }

    get reports_path
    assert_response :ok
    assert_select "h3", text: I18n.t("reports.empty_state.title")
  end

  test "index shows the share of this month's allocation already spent" do
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current.beginning_of_month)
    category = @family.categories.expenses.first
    budget.budget_categories.find_by!(category: category).update!(budgeted_spending: 500)
    budget.current_user = @user
    expected = (budget.actual_spending / budget.allocated_spending * 100).round(1)

    # A category created after the budget has no line in it yet: it counts as
    # nothing allocated.
    @family.categories.create!(name: "Added after the budget", color: "#123456")

    get reports_path(period_type: :monthly)

    assert_response :ok
    assert_select "p", text: "#{expected}%"
  end

  test "the share of the household budget spent counts only the accounts the member can see" do
    member = users(:family_member)
    category = @family.categories.expenses.first
    create_transaction(account: accounts(:connected), category: category, amount: 300)
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current.beginning_of_month)
    budget.budget_categories.find_by!(category: category).update!(budgeted_spending: 500)
    percent_used = ->(viewer) do
      seen = Budget.find(budget.id).tap { |b| b.current_user = viewer }
      (seen.actual_spending / seen.allocated_spending * 100).round(1)
    end
    expected = percent_used.call(member)
    assert_not_equal expected, percent_used.call(nil), "setup: the member must see less spending than the family"

    sign_in member
    get reports_path(period_type: :monthly)

    assert_response :ok
    assert_select "p", text: "#{expected}%"
  end

  test "index shows nothing used when this month has no budget" do
    @family.budgets.destroy_all

    get reports_path(period_type: :monthly)

    assert_response :ok
    assert_select "p", text: "0%"
    assert_select "p", text: I18n.t("reports.summary.of_budget_used")
  end

  # Opening Reports must not change the data its cache version is drawn from:
  # a body that bootstraps this month's budget is stale as soon as it is built.
  test "building this month's report creates no budget or budget line" do
    @family.categories.create!(name: "Not budgeted yet", color: "#123456")

    assert_no_difference [ "Budget.count", "BudgetCategory.count" ] do
      get reports_path(period_type: :monthly)
      ReportsController.warm_body_cache(user: @user, query: { period_type: :monthly })
    end
  end

  test "this month's body warmed twice is built once" do
    @family.categories.create!(name: "Not budgeted yet", color: "#123456")

    with_memory_cache do
      assert ReportsController.warm_body_cache(user: @user, query: { period_type: :monthly })
      assert_not ReportsController.warm_body_cache(user: @user, query: { period_type: :monthly }), "already warm"
    end
  end

  test "index calculates summary metrics correctly" do
    get reports_path(period_type: :monthly)
    assert_response :ok
    assert_select "h3", text: I18n.t("reports.summary.total_income")
    assert_select "h3", text: I18n.t("reports.summary.total_expenses")
    assert_select "h3", text: I18n.t("reports.summary.net_savings")
  end

  test "index builds trends data" do
    get reports_path(period_type: :monthly)
    assert_response :ok
    assert_select "h2", text: I18n.t("reports.trends.title")
    assert_select "thead" do
      assert_select "th", text: I18n.t("reports.trends.month")
    end
  end

  test "monthly breakdown month names link to that month's report with the selected tags" do
    tag = @family.tags.create!(name: "Breakdown tag")

    get reports_path(period_type: :custom, start_date: Date.new(2024, 1, 15), end_date: Date.new(2024, 3, 12), filter_tag_ids: [ tag.id ])

    assert_response :ok
    [ Date.new(2024, 1, 1), Date.new(2024, 2, 1), Date.new(2024, 3, 1) ].each do |month|
      href = reports_path(period_type: :monthly, start_date: month, end_date: month.end_of_month, filter_tag_ids: [ tag.id ])
      assert_select "[data-section-key=trends_insights] a[href=?][data-turbo-frame=_top]", href, text: month.strftime("%b %Y")
    end
  end

  test "index handles invalid date parameters gracefully" do
    get reports_path(
      period_type: :custom,
      start_date: "invalid-date",
      end_date: "also-invalid"
    )
    assert_response :ok # Should not crash, uses defaults
  end

  test "index swaps dates when end_date is before start_date" do
    start_date = Date.current
    end_date = 1.month.ago.to_date

    get reports_path(
      period_type: :custom,
      start_date: start_date.to_s,
      end_date: end_date.to_s
    )

    assert_response :ok
    assert_equal I18n.t("reports.invalid_date_range"), flash[:alert]
    assert_includes @response.body, end_date.strftime("%b %Y")
    assert_includes @response.body, start_date.strftime("%b %Y")
  end

  test "spending patterns returns data when expense transactions exist" do
    # Create expense category
    expense_category = @family.categories.create!(
      name: "Test Groceries"
    )

    # Create account
    account = @family.accounts.first

    # Create expense transaction on a weekday (Monday)
    weekday_date = Date.current.beginning_of_month + 2.days
    weekday_date = weekday_date.next_occurring(:monday)

    entry = account.entries.create!(
      name: "Grocery shopping",
      date: weekday_date,
      amount: 50.00,
      currency: "USD",
      entryable: Transaction.new(
        category: expense_category,
        kind: "standard"
      )
    )

    # Create expense transaction on a weekend (Saturday)
    weekend_date = weekday_date.next_occurring(:saturday)

    weekend_entry = account.entries.create!(
      name: "Weekend shopping",
      date: weekend_date,
      amount: 75.00,
      currency: "USD",
      entryable: Transaction.new(
        category: expense_category,
        kind: "standard"
      )
    )

    get reports_path(period_type: :monthly)
    assert_response :ok

    # Verify spending patterns shows data (not the "no data" message)
    assert_select ".text-center.py-8.text-subdued", { text: /No spending data/, count: 0 }, "Should not show 'No spending data' message when transactions exist"
  end

  test "index avoids residual category lazy loads" do
    account = accounts(:depository)

    4.times do |idx|
      parent = @family.categories.create!(
        name: "Reports Parent #{idx}",
        color: "#000000",
        lucide_icon: "folder"
      )
      child = @family.categories.create!(
        name: "Reports Child #{idx}",
        color: "#111111",
        lucide_icon: "folder",
        parent: parent
      )
      entry = account.entries.create!(
        name: "Reports transaction #{idx}",
        date: Date.current,
        amount: 10 + idx,
        currency: "USD",
        entryable: Transaction.new(
          category: child,
          kind: "standard"
        )
      )
      assert entry.persisted?
    end

    queries = capture_sql_queries { get reports_path(period_type: :monthly) }

    assert_response :ok
    assert_empty queries.grep(/SELECT "categories"\.\* FROM "categories" WHERE "categories"\."id" = \$1 LIMIT \$2/)
  end

  test "export transactions with API key authentication" do
    # Use an active API key with read permissions
    api_key = api_keys(:active_key)

    # Make sure the API key has the correct source
    api_key.update!(source: "web") unless api_key.source == "web"

    get export_transactions_reports_path(
      format: :csv,
      period_type: :ytd,
      start_date: Date.current.beginning_of_year,
      end_date: Date.current,
      api_key: api_key.plain_key
    )

    assert_response :ok
    assert_equal "text/csv", @response.media_type
    assert_match /Category/, @response.body
  end

  test "export transactions with API key does not inherit web session impersonation" do
    support_user = users(:sure_support_staff)
    support_user.api_keys.active.destroy_all
    token_value = ApiKey.generate_secure_key
    export_credential = support_user.api_keys.build(
      name: "Support Export Credential",
      scopes: [ "read" ],
      source: "web"
    )
    export_credential.key = token_value
    export_credential.save!

    impersonation_session = impersonation_sessions(:in_progress)
    impersonated_user = impersonation_session.impersonated
    leaked_category = impersonated_user.family.categories.create!(
      name: "Impersonated Export Leak Probe"
    )
    impersonated_account = impersonated_user.finance_accounts.first
    assert_not_nil impersonated_account, "Test setup failed: impersonated user has no finance account"

    create_transaction(
      account: impersonated_account,
      name: "Impersonated export leak probe",
      date: Date.current,
      amount: 123.45,
      category: leaked_category
    )

    support_user.sessions.destroy_all
    support_user.sessions.create!(
      user_agent: "Browser session",
      ip_address: "127.0.0.1",
      active_impersonator_session: impersonation_session
    )

    get export_transactions_reports_path(
      format: :csv,
      period_type: :ytd,
      start_date: Date.current.beginning_of_year,
      end_date: Date.current,
      api_key: token_value
    )

    assert_response :ok
    assert_equal "text/csv", @response.media_type
    assert_no_match /Impersonated Export Leak Probe/, @response.body
  end

  test "export transactions with API key rejects deactivated user" do
    user = users(:family_admin)
    user.api_keys.active.destroy_all
    token_value = ApiKey.generate_secure_key
    export_access = user.api_keys.build(
      name: "Inactive User Export Credential",
      scopes: [ "read" ],
      source: "web"
    )
    export_access.key = token_value
    export_access.save!
    user.update_column(:active, false)

    get export_transactions_reports_path(
      format: :csv,
      period_type: :ytd,
      api_key: token_value
    )

    assert_response :unauthorized
    assert_match /Invalid or expired API key/, @response.body
  ensure
    user&.update_column(:active, true)
  end

  test "export transactions with invalid API key" do
    get export_transactions_reports_path(
      format: :csv,
      period_type: :ytd,
      api_key: "invalid_key"
    )

    assert_response :unauthorized
    assert_match /Invalid or expired API key/, @response.body
  end

  test "export transactions without API key uses session auth" do
    # Should use normal session-based authentication
    # The setup already signs in @user = users(:family_admin)
    assert_not_nil @user, "User should be set in test setup"
    assert_not_nil @family, "Family should be set in test setup"

    get export_transactions_reports_path(
      format: :csv,
      period_type: :ytd,
      start_date: Date.current.beginning_of_year,
      end_date: Date.current
    )

    assert_response :ok, "Export should work with session auth. Response: #{@response.body}"
    assert_equal "text/csv", @response.media_type
  end

  test "export transactions excludes tax-advantaged account transactions" do
    taxable_category = @family.categories.create!(name: "Export Taxable Income", color: "#111111")
    retirement_category = @family.categories.create!(name: "Export Retirement Income", color: "#222222")
    taxable_account = @family.accounts.create!(
      owner: @user,
      name: "Export Taxable Brokerage",
      balance: 0,
      currency: "USD",
      accountable: Investment.new(subtype: "brokerage")
    )
    retirement_account = @family.accounts.create!(
      owner: @user,
      name: "Export 401k",
      balance: 0,
      currency: "USD",
      accountable: Investment.new(subtype: "401k")
    )

    create_transaction(account: taxable_account, name: "Taxable export dividend", amount: -100, category: taxable_category)
    create_transaction(account: retirement_account, name: "401k export dividend", amount: -200, category: retirement_category)

    get export_transactions_reports_path(
      format: :csv,
      period_type: :monthly,
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month
    )

    assert_response :ok
    assert_equal "text/csv", @response.media_type
    assert_match /Export Taxable Income/, @response.body
    assert_no_match /Export Retirement Income/, @response.body
  end

  test "export transactions swaps dates when end_date is before start_date" do
    start_date = Date.current
    end_date = 1.month.ago.to_date

    get export_transactions_reports_path(
      format: :csv,
      period_type: :custom,
      start_date: start_date.to_s,
      end_date: end_date.to_s
    )

    assert_response :ok
    assert_equal "text/csv", @response.media_type
    # Verify the CSV content is generated (should not crash)
    assert_not_nil @response.body
  end

  test "index groups transactions by parent and subcategories" do
    # Create parent category with subcategories
    parent_category = @family.categories.create!(name: "Entertainment", color: "#FF5733")
    subcategory_movies = @family.categories.create!(name: "Movies", parent: parent_category, color: "#33FF57")
    subcategory_games = @family.categories.create!(name: "Games", parent: parent_category, color: "#5733FF")

    # Create transactions using helper
    create_transaction(account: @family.accounts.first, name: "Cinema ticket", amount: 15, category: subcategory_movies)
    create_transaction(account: @family.accounts.first, name: "Video game", amount: 60, category: subcategory_games)

    get reports_path(period_type: :monthly)
    assert_response :ok

    # Parent category
    assert_select "tr[data-category='category-#{parent_category.id}']", text: /^Entertainment/

    # Subcategories
    assert_select "tr[data-category='category-#{subcategory_movies.id}']", text: /^Movies/
    assert_select "tr[data-category='category-#{subcategory_games.id}']", text: /^Games/
  end

  test "index lets keyboard users scroll the breakdown table" do
    create_transaction(account: @family.accounts.first, name: "Lunch", amount: 15, category: categories(:food_and_drink))

    get reports_path(period_type: :monthly)

    assert_select "[role=region][tabindex='0'][aria-label=?] table", "Expenses"
  end

  test "index lets keyboard users scroll the trends and net worth tables" do
    create_transaction(account: @family.accounts.first, name: "Lunch", amount: 15, category: categories(:food_and_drink))

    get reports_path(period_type: :monthly)

    %w[Monthly\ Breakdown Assets Liabilities].each do |label|
      assert_select "[role=region][tabindex='0'][aria-label=?] table", label
    end
  end

  test "index links income and expense categories to filtered transactions" do
    start_date = Date.current.beginning_of_month
    end_date = Date.current.end_of_month
    expense_category = @family.categories.create!(name: "Reports Clickable Groceries", color: "#ABCDEF")
    income_category = @family.categories.create!(name: "Reports Clickable Salary", color: "#FEDCBA")
    account = @family.accounts.first

    create_transaction(account: account, name: "Groceries", amount: 42, category: expense_category, date: Date.current)
    create_transaction(account: account, name: "Salary", amount: -100, category: income_category, date: Date.current)
    create_transaction(account: account, name: "Uncategorized cash", amount: 25, date: Date.current)

    get reports_path(period_type: :monthly, start_date: start_date, end_date: end_date)
    assert_response :ok

    expense_href = transactions_path(q: { categories: [ expense_category.name ], start_date: start_date, end_date: end_date })
    income_href = transactions_path(q: { categories: [ income_category.name ], start_date: start_date, end_date: end_date })
    uncategorized_href = transactions_path(q: { categories: [ Category.uncategorized.filter_value ], start_date: start_date, end_date: end_date })

    assert_select "tr[data-category='category-#{expense_category.id}'] a[href=?]", expense_href, text: /#{Regexp.escape(expense_category.name)}/
    assert_select "tr[data-category='category-#{income_category.id}'] a[href=?]", income_href, text: /#{Regexp.escape(income_category.name)}/
    assert_select "tr[data-category='category-uncategorized'] a[href=?]", uncategorized_href, text: /#{Regexp.escape(Category.uncategorized.name)}/

    # Full-row hit target via a normal flex <a> wrapping icon+name+count —
    # deliberately not a `position: relative`/`absolute` stretched-link inside
    # the <table>, which caused a WebKit scrollHeight bug (see #3093).
    assert_select "tr[data-category='category-#{expense_category.id}'] a.flex.items-center"
    assert_select "tr[data-category='category-#{expense_category.id}'].relative", 0
    assert_select "tr[data-category='category-#{expense_category.id}'] a[class*='before:absolute']", 0

    # Amount and percentage cells are each wrapped in their own normal-flow
    # <a> to the same href, so the full row remains clickable without a
    # stretched-link overlay spanning the <tr>.
    assert_select "tr[data-category='category-#{expense_category.id}'] td:nth-child(2) a[href=?]", expense_href
    assert_select "tr[data-category='category-#{expense_category.id}'] td:nth-child(3) a[href=?]", expense_href
  end

  test "index uncategorized category link stays on the stable filter value while the displayed text is localized" do
    start_date = Date.current.beginning_of_month
    end_date = Date.current.end_of_month
    account = @family.accounts.first
    create_transaction(account: account, name: "Uncategorized cash", amount: 25, date: Date.current)

    @user.update!(locale: "zh-CN")
    localized_name = I18n.with_locale(:"zh-CN") { Category.uncategorized.name }

    get reports_path(period_type: :monthly, start_date: start_date, end_date: end_date)
    assert_response :ok

    href = transactions_path(q: { categories: [ Category::UNCATEGORIZED_FILTER_VALUE ], start_date: start_date, end_date: end_date })
    assert_select "tr[data-category='category-uncategorized'] a[href=?]", href, text: /#{Regexp.escape(localized_name)}/
  end

  test "index excludes tax-advantaged account transactions from activity breakdown" do
    @family.accounts.each { |account| account.entries.destroy_all }

    taxable_category = @family.categories.create!(name: "Reports Taxable Income", color: "#111111")
    retirement_category = @family.categories.create!(name: "Reports Retirement Income", color: "#222222")
    taxable_account = @family.accounts.create!(
      owner: @user,
      name: "Reports Taxable Brokerage",
      balance: 0,
      currency: "USD",
      accountable: Investment.new(subtype: "brokerage")
    )
    retirement_account = @family.accounts.create!(
      owner: @user,
      name: "Reports 401k",
      balance: 0,
      currency: "USD",
      accountable: Investment.new(subtype: "401k")
    )

    create_transaction(account: taxable_account, name: "Taxable dividend", amount: -100, category: taxable_category)
    create_transaction(account: retirement_account, name: "401k dividend", amount: -200, category: retirement_category)
    create_income_trade(account: taxable_account, label: "Dividend", amount: -100)
    create_income_trade(account: retirement_account, label: "Dividend", amount: -200)

    get reports_path(period_type: :monthly)
    assert_response :ok

    assert_select "tr[data-category='category-#{taxable_category.id}']", text: /Reports Taxable Income/
    assert_select "tr[data-category='category-#{retirement_category.id}']", count: 0

    other_investments_rows = css_select("tr[data-category='category-other_investments']")
    assert_operator other_investments_rows.size, :>=, 1
    other_investments_rows.each do |row|
      assert_match(/#{Regexp.escape(Category.other_investments.name)}/, row.text)
      assert_equal 0, row.css("a").size
    end
    assert_match(/#{Regexp.escape(I18n.t("reports.transactions_breakdown.table.entries", count: 1))}/, other_investments_rows.first.text)
    assert_match(/\$100\.00/, other_investments_rows.first.text)
  end

  # Selling a holding turns securities into cash; it is not income, and the
  # Total Income card (IncomeStatement::Totals) already leaves trades out.
  test "activity breakdown leaves trades out of income and expenses" do
    @family.accounts.each { |account| account.entries.destroy_all }

    salary = @family.categories.create!(name: "Reports Salary", color: "#111111")
    brokerage = @family.accounts.create!(
      owner: @user,
      name: "Reports Brokerage",
      balance: 0,
      currency: "USD",
      accountable: Investment.new(subtype: "brokerage")
    )

    create_transaction(account: accounts(:depository), name: "Paycheck", amount: -100, category: salary)
    create_trade(securities(:aapl), account: brokerage, qty: -10, date: Date.current, price: 100)
    create_trade(securities(:aapl), account: brokerage, qty: 5, date: Date.current, price: 100)

    get reports_path(period_type: :monthly)
    assert_response :ok

    assert_select "tr[data-category='category-other_investments']", count: 0
    assert_select "tr[data-category='category-#{salary.id}']", text: /\$100\.00/
    income_total = css_select("span.text-success.privacy-sensitive").map { |node| node.text.strip }
    assert_includes income_total, "$100.00"
    assert_not_includes income_total, "$1,100.00"
  end

  # Manually entered dividends, interest and fees are qty-0 trades
  # (Trade::CreateForm#create_income_trade) and stay under Other Investments.
  test "activity breakdown keeps manually entered dividends, interest and fees" do
    @family.accounts.each { |account| account.entries.destroy_all }
    brokerage = @family.accounts.create!(owner: @user, name: "Reports Brokerage", balance: 0, currency: "USD",
                                         accountable: Investment.new(subtype: "brokerage"))
    create_transaction(account: accounts(:depository), name: "Coffee", amount: 3) # the page needs a transaction
    create_income_trade(account: brokerage, label: "Dividend", amount: -42.17)
    create_income_trade(account: brokerage, label: "Interest", amount: -13.37)
    create_income_trade(account: brokerage, label: "Fee", amount: 7.77)

    get reports_path(period_type: :monthly)
    assert_response :ok

    rows = css_select("tr[data-category='category-other_investments']").map(&:text).join
    [ "$55.54", "$7.77" ].each { |amount| assert_includes rows, amount }
  end

  # The activity-label editor relabels a trade without changing its quantity.
  test "activity breakdown keeps a trade relabelled as a dividend" do
    @family.accounts.each { |account| account.entries.destroy_all }
    brokerage = @family.accounts.create!(owner: @user, name: "Reports Brokerage", balance: 0, currency: "USD",
                                         accountable: Investment.new(subtype: "brokerage"))
    create_transaction(account: accounts(:depository), name: "Coffee", amount: 3)
    create_trade(securities(:aapl), account: brokerage, qty: -1, date: Date.current, price: 42.17)
      .trade.update!(investment_activity_label: "Dividend")

    get reports_path(period_type: :monthly)
    assert_response :ok

    assert_includes css_select("tr[data-category='category-other_investments']").map(&:text).join, "$42.17"
  end

  # The rule is by label, not only Buy and Sell: a trade that moves units
  # stays out unless it is labelled as income or a fee.
  test "activity breakdown leaves out trades with other labels or none" do
    @family.accounts.each { |account| account.entries.destroy_all }
    brokerage = @family.accounts.create!(owner: @user, name: "Reports Brokerage", balance: 0, currency: "USD",
                                         accountable: Investment.new(subtype: "brokerage"))
    create_transaction(account: accounts(:depository), name: "Coffee", amount: 3)
    [ "Contribution", "Withdrawal", "Reinvestment", "Transfer", "Exchange", "Other", nil ].each_with_index do |label, i|
      create_trade(securities(:aapl), account: brokerage, qty: i.even? ? 2 : -2, date: Date.current, price: 50)
        .trade.update!(investment_activity_label: label)
    end

    get reports_path(period_type: :monthly)
    assert_response :ok

    assert_select "tr[data-category='category-other_investments']", count: 0
  end

  # A cash-only trade relabelled as a movement (e.g. through the API) is not
  # income either; an unlabelled or "Other" one stays as before.
  test "activity breakdown leaves out qty-0 trades labelled as movements" do
    @family.accounts.each { |account| account.entries.destroy_all }
    brokerage = @family.accounts.create!(owner: @user, name: "Reports Brokerage", balance: 0, currency: "USD",
                                         accountable: Investment.new(subtype: "brokerage"))
    create_transaction(account: accounts(:depository), name: "Coffee", amount: 3)
    [ "Transfer", "Sweep In", "Contribution", "Withdrawal", "Buy" ].each do |label|
      create_income_trade(account: brokerage, label: "Dividend", amount: -100).trade.update!(investment_activity_label: label)
    end
    create_income_trade(account: brokerage, label: "Dividend", amount: -12.34).trade.update!(investment_activity_label: "Other")
    create_income_trade(account: brokerage, label: "Dividend", amount: -10).trade.update!(investment_activity_label: nil)

    get reports_path(period_type: :monthly)
    assert_response :ok

    rows = css_select("tr[data-category='category-other_investments']").map(&:text).join
    assert_includes rows, "$22.34"
    assert_not_includes rows, "$522.34"
  end

  # The summary leaves out an amount in a currency with no rate; the
  # breakdown under it and the CSV export must leave it out too, not count
  # ₩130,000 as $130,000.
  test "the activity breakdown leaves out an expense in a currency with no rate" do
    category = @family.categories.create!(name: "Won Rent", color: "#111111")
    krw = @family.accounts.create!(owner: @user, name: "Seoul", balance: 0, currency: "KRW", accountable: Depository.new)
    create_transaction(account: krw, name: "Rent", amount: 130_000, currency: "KRW", category: category)

    get reports_path(period_type: :monthly)
    assert_response :ok

    assert_select "tr[data-category='category-#{category.id}']", count: 0
    assert_no_match(/130,000/, @response.body)
  end

  # Card authorisations post as 0.00; with no sign they are neither income nor expense.
  test "the breakdown and export leave out zero-amount transactions" do
    category = @family.categories.create!(name: "Zero Auth Streaming", color: "#111111")
    create_transaction(account: accounts(:depository), name: "Card check", amount: 0, category: category)

    get reports_path(period_type: :monthly)
    assert_response :ok
    assert_select "tr[data-category='category-#{category.id}']", count: 0

    get export_transactions_reports_path(format: :csv, period_type: :monthly,
                                         start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    assert_response :ok
    assert_no_match(/Zero Auth Streaming/, @response.body)
  end

  test "the export leaves out an expense in a currency with no rate" do
    category = @family.categories.create!(name: "Won Export Rent", color: "#111111")
    krw = @family.accounts.create!(owner: @user, name: "Seoul", balance: 0, currency: "KRW", accountable: Depository.new)
    create_transaction(account: krw, name: "Rent", amount: 130_000, currency: "KRW", category: category)

    get export_transactions_reports_path(format: :csv, period_type: :monthly,
                                         start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    assert_response :ok

    assert_no_match(/Won Export Rent/, @response.body)
    assert_no_match(/130000/, @response.body)
  end

  # The summary uses the latest stored rate however old; the breakdown used
  # Money#exchange_to, which looks back five days and then converts at 1.
  test "the activity breakdown converts at a stored rate older than five days" do
    category = @family.categories.create!(name: "Yen Rent", color: "#111111")
    jpy = @family.accounts.create!(owner: @user, name: "Tokyo", balance: 0, currency: "JPY", accountable: Depository.new)
    ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: 30.days.ago.to_date, rate: 0.0067)
    create_transaction(account: jpy, name: "Rent", amount: 10_000, currency: "JPY", category: category)

    get reports_path(period_type: :monthly)
    assert_response :ok

    row = css_select("tr[data-category='category-#{category.id}']").first
    assert row, "the converted expense is listed"
    assert_match(/\$67\.00/, row.text)
  end

  test "monthly period navigation shows previous month link" do
    get reports_path(period_type: :monthly)
    assert_response :ok

    prev_start = Date.current.beginning_of_month - 1.month
    prev_end = prev_start.end_of_month
    assert_select "a[href=?]", reports_path(period_type: :monthly, start_date: prev_start, end_date: prev_end)
  end

  test "monthly period navigation disables next arrow on current month" do
    get reports_path(period_type: :monthly)
    assert_response :ok

    assert_select "button[disabled][aria-label=?]", I18n.t("reports.index.next_period")
  end

  test "monthly period navigation shows next month link on past month" do
    past_start = Date.current.beginning_of_month - 2.months
    past_end = past_start.end_of_month
    get reports_path(period_type: :monthly, start_date: past_start, end_date: past_end)
    assert_response :ok

    next_start = past_start + 1.month
    next_end = next_start.end_of_month
    assert_select "a[href=?]", reports_path(period_type: :monthly, start_date: next_start, end_date: next_end)
  end

  test "period arrows carry their keyboard shortcuts" do
    past_start = Date.current.beginning_of_month - 2.months
    get reports_path(period_type: :monthly, start_date: past_start, end_date: past_start.end_of_month)
    assert_response :ok

    assert_select "a[aria-keyshortcuts='ArrowLeft'][data-hotkey='ArrowLeft']"
    assert_select "a[aria-keyshortcuts='ArrowRight'][data-hotkey='ArrowRight']"
    assert_select "[role='tooltip']", text: "Previous period (←)"
    assert_select "[role='tooltip']", text: "Next period (→)"
  end

  test "last 6 months next window extends to current month end when crossing boundary" do
    start_date = Date.current.beginning_of_month - 12.months
    end_date = start_date + 6.months - 1.day

    get reports_path(period_type: :last_6_months, start_date: start_date, end_date: end_date)
    assert_response :ok

    candidate_start = start_date.beginning_of_month + 6.months
    if candidate_start + 6.months >= Date.current.beginning_of_month
      expected_next_end   = Date.current.end_of_month
      expected_next_start = (expected_next_end + 1.day - 6.months).beginning_of_month
    else
      expected_next_start = candidate_start
      expected_next_end   = expected_next_start + 6.months - 1.day
    end

    assert_select "a[href=?]",
      reports_path(period_type: :last_6_months, start_date: expected_next_start, end_date: expected_next_end)
  end

  test "quarterly period navigation shows previous and next quarter links" do
    get reports_path(period_type: :quarterly)
    assert_response :ok

    prev_start = (Date.current.beginning_of_quarter - 1.day).beginning_of_quarter
    prev_end = prev_start.end_of_quarter
    assert_select "a[href=?]", reports_path(period_type: :quarterly, start_date: prev_start, end_date: prev_end)

    # Also verify a past quarter shows an enabled next-quarter link
    get reports_path(period_type: :quarterly, start_date: prev_start, end_date: prev_end)
    assert_response :ok

    next_start = prev_start.next_quarter.beginning_of_quarter
    next_end   = next_start.end_of_quarter
    assert_select "a[href=?]", reports_path(period_type: :quarterly, start_date: next_start, end_date: next_end)
  end

  test "custom period hides period display" do
    get reports_path(
      period_type: :custom,
      start_date: 1.month.ago.to_date,
      end_date: Date.current
    )
    assert_response :ok

    assert_select "a[aria-label=?]", I18n.t("reports.index.previous_period"), count: 0
    assert_select "a[aria-label=?]", I18n.t("reports.index.next_period"), count: 0
  end

  test "monthly period shows previous period navigation" do
    get reports_path(period_type: :monthly)
    assert_response :ok

    assert_select "a[aria-label=?]", I18n.t("reports.index.previous_period"), count: 1
  end

  test "ytd period navigation shows previous year link" do
    get reports_path(period_type: :ytd)
    assert_response :ok

    prev_year  = Date.current.year - 1
    prev_start = Date.new(prev_year, 1, 1)
    prev_end   = Date.new(prev_year, 12, 31)
    assert_select "a[href=?]", reports_path(period_type: :ytd, start_date: prev_start, end_date: prev_end)
  end

  test "the category filter lists the category's transactions and leaves trades out" do
    category = @family.categories.create!(name: "Filtered", color: "#123456")
    create_transaction(account: accounts(:depository), name: "Filtered spend", amount: 42, category: category)
    create_trade(securities(:aapl), account: accounts(:investment), qty: 1, date: Date.current, price: 100)

    get reports_path(period_type: :monthly, filter_category_id: category.id)

    assert_response :ok
    assert_select "tr[data-category='category-#{category.id}']", text: /\$42\.00/
    assert_select "tr[data-category='category-other_investments']", count: 0
  end

  test "ytd period navigation disables next arrow on current year" do
    get reports_path(period_type: :ytd)
    assert_response :ok

    assert_select "button[disabled][aria-label=?]", I18n.t("reports.index.next_period")
  end

  test "a transfer out is not listed among the period's sales" do
    account = @family.accounts.create!(name: "Wallet", balance: 100, currency: "USD",
                                       accountable: Investment.new)
    security = Security.find_or_create_by!(ticker: "MOVE") { |sec| sec.name = "Movable" }
    Holding.create!(account: account, security: security, date: 10.days.ago.to_date,
                    qty: 100, price: 2, amount: 200, currency: "USD", cost_basis: 1)

    %w[Transfer Sell].each do |label|
      account.entries.create!(
        date: 3.days.ago.to_date, name: "out #{label}", amount: 0, currency: "USD",
        entryable: Trade.new(security: security, qty: -40, price: 3, currency: "USD",
                             investment_activity_label: label)
      )
    end

    # `period_type`, not `period` — the controller reads the former, so the
    # latter silently fell back to the current month and the trades dated
    # three days ago dropped out of range on the 1st to the 3rd.
    get reports_path(period_type: :custom, start_date: 30.days.ago.to_date, end_date: Date.current)
    assert_response :success

    # A transfer out carries the same negative quantity as a sale. Counting it
    # as one both inflates the number of sales and books a gain nobody made.
    assert_match I18n.t("reports.investment_performance.sells_count", count: 1), response.body
    assert_no_match(/#{Regexp.escape(I18n.t("reports.investment_performance.sells_count", count: 2))}/, response.body)
  end

  # The category column of the reports export is a user-supplied name, and this
  # is the export the app points at Google Sheets.
  test "transactions export escapes formula-triggering category names" do
    malicious = "=SUM(A1)"
    malicious_income = "@income"
    account = @family.accounts.first

    # One expense and one income, so both sections of the export are covered.
    { malicious => 42.00, malicious_income => -500.00 }.each do |name, amount|
      account.entries.create!(
        name: "Payee",
        date: Date.current.beginning_of_month + 3.days,
        amount: amount,
        currency: "USD",
        entryable: Transaction.new(category: @family.categories.create!(name: name, color: "#123456"), kind: "standard")
      )
    end

    get export_transactions_reports_path(
      format: :csv,
      period_type: :monthly,
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month
    )

    assert_response :ok
    rows = CSV.parse(@response.body)
    [ malicious, malicious_income ].each do |name|
      assert rows.any? { |r| r.first == "'#{name}" }, "the #{name} category cell must be escaped"
      assert_not rows.any? { |r| r.first == name }, "a raw #{name} must not lead a row"
    end
  end

  # The card was gated on `investment_accounts`, which is visible accounts
  # only (draft and active), while its realised-gains half is measured over
  # every account included in reports, disabled ones too. A family whose only
  # brokerage account is closed was shown no card at all, although the period
  # held a disposal the card would have listed.
  test "the investment card shows a disposal from a closed account when it is the only investment account" do
    exclude_fixture_investment_accounts
    account, security = closed_account_with_disposal(date: Date.current.beginning_of_month)

    get reports_path
    assert_response :ok

    assert_select "[data-section-key='investment_performance']", { count: 1 },
                  "the card must render for a family whose only investment account is closed"
    line = css_select("[data-testid='realized-gain-line']").map(&:text).find { |text| text.include?(security.ticker) }
    assert line, "the disposal from #{account.name} must be listed on the card"
    assert_match "$100.00", line
  end

  # The gate widens rather than moves: an open investment account still shows
  # the card in a period with no disposal at all.
  test "the investment card still shows for an open investment account in a period with no disposals" do
    period_start = 10.years.ago.to_date.beginning_of_month
    assert_not @family.trades.joins(:entry).where(entries: { date: period_start..period_start.end_of_month }).exists?,
               "the period must hold no trade, or this proves nothing"

    get reports_path(period_type: :custom, start_date: period_start, end_date: period_start.end_of_month)
    assert_response :ok

    assert_select "[data-section-key='investment_performance']", count: 1
  end

  test "the investment card stays hidden with no investment accounts and no disposals" do
    exclude_fixture_investment_accounts

    get reports_path
    assert_response :ok

    assert_select "[data-section-key='investment_performance']", count: 0
  end

  # The gate is period-dependent: a disposal outside the chosen period is
  # nothing this card would show.
  test "the investment card stays hidden when the closed account's disposal is outside the period" do
    exclude_fixture_investment_accounts
    closed_account_with_disposal(date: Date.current.beginning_of_month.prev_month)

    get reports_path(period_type: :custom, start_date: Date.current.beginning_of_month, end_date: Date.current)
    assert_response :ok

    assert_select "[data-section-key='investment_performance']", count: 0
  end

  # A transfer out has a sale's negative quantity but is not a disposal; the
  # card leaves it out, so it must not open the card either.
  test "a transfer out of a closed account does not show the investment card" do
    exclude_fixture_investment_accounts
    closed_account_with_disposal(date: Date.current.beginning_of_month, label: "Transfer")

    get reports_path
    assert_response :ok

    assert_select "[data-section-key='investment_performance']", count: 0
  end

  # Another member's closed account that this user does not include in their
  # finances is not the user's to see; it must not open the card for them.
  test "another member's closed account with a disposal does not show the investment card" do
    exclude_fixture_investment_accounts
    closed_account_with_disposal(date: Date.current.beginning_of_month, owner: users(:family_member))

    get reports_path
    assert_response :ok

    assert_select "[data-section-key='investment_performance']", count: 0
  end

  # The card lists only what this user counts in their finances. When the
  # user's own closed account opens the card, another member's account that
  # is not shared with them must not be listed beside it.
  test "the investment card does not list another member's unshared disposal" do
    exclude_fixture_investment_accounts
    date = Date.current.beginning_of_month
    _, own = closed_account_with_disposal(date: date)
    _, theirs = closed_account_with_disposal(date: date, owner: users(:family_member))

    get reports_path
    assert_response :ok

    lines = css_select("[data-testid='realized-gain-line']").map(&:text)
    assert lines.any? { |text| text.include?(own.ticker) }, "the user's own disposal must be listed"
    assert lines.none? { |text| text.include?(theirs.ticker) },
           "another member's unshared disposal must not be listed"
  end

  # The same holds when an open investment account of the user's is what
  # shows the card, and when the other member's account is open too.
  test "the investment card does not list another member's unshared disposal beside an open account" do
    exclude_fixture_investment_accounts
    date = Date.current.beginning_of_month
    _, own = closed_account_with_disposal(date: date, close: false)
    _, theirs = closed_account_with_disposal(date: date, owner: users(:family_member), close: false)

    get reports_path
    assert_response :ok

    lines = css_select("[data-testid='realized-gain-line']").map(&:text)
    assert lines.any? { |text| text.include?(own.ticker) }, "the user's own disposal must be listed"
    assert lines.none? { |text| text.include?(theirs.ticker) },
           "another member's unshared disposal must not be listed"
  end

  # A member's account shared with the user and included in their finances
  # is the user's to see, so its disposal is listed and opens the card.
  test "the investment card lists a disposal from a member's account shared into the user's finances" do
    exclude_fixture_investment_accounts
    account, theirs = closed_account_with_disposal(date: Date.current.beginning_of_month, owner: users(:family_member))
    account.account_shares.create!(user: @user, permission: "read_only", include_in_finances: true)

    get reports_path
    assert_response :ok

    lines = css_select("[data-testid='realized-gain-line']").map(&:text)
    assert lines.any? { |text| text.include?(theirs.ticker) },
           "a disposal from an account shared into the user's finances must be listed"
  end

  # An excluded trade is left out of reports, as investment totals leave it
  # out; it is not a disposal for the card's gate or its list.
  test "an excluded disposal from a closed account does not show the investment card" do
    exclude_fixture_investment_accounts
    closed_account_with_disposal(date: Date.current.beginning_of_month, excluded: true)

    get reports_path
    assert_response :ok

    assert_select "[data-section-key='investment_performance']", count: 0
  end

  test "the investment card does not list an excluded disposal" do
    exclude_fixture_investment_accounts
    date = Date.current.beginning_of_month
    _, kept = closed_account_with_disposal(date: date, close: false)
    _, excluded = closed_account_with_disposal(date: date, close: false, excluded: true)

    get reports_path
    assert_response :ok

    lines = css_select("[data-testid='realized-gain-line']").map(&:text)
    assert lines.any? { |text| text.include?(kept.ticker) }, "the kept disposal must be listed"
    assert lines.none? { |text| text.include?(excluded.ticker) }, "the excluded disposal must not be listed"
  end

  test "activity breakdown draws one trend line per selected category" do
    account = accounts(:depository)
    groceries = @family.categories.create!(name: "Trend groceries", color: "#ABCDEF")
    dining = @family.categories.create!(name: "Trend dining", color: "#FEDCBA")
    period_start = 2.months.ago.beginning_of_month.to_date

    create_transaction(account: account, name: "Groceries now", amount: 40, category: groceries, date: Date.current)
    create_transaction(account: account, name: "Groceries before", amount: 10, category: groceries, date: period_start + 2.days)
    create_transaction(account: account, name: "Dining now", amount: 25, category: dining, date: Date.current)

    enable_preview!
    get reports_path(
      period_type: :custom,
      start_date: period_start,
      end_date: Date.current.end_of_month,
      trend_category_ids: [ groceries.id, dining.id ]
    )

    assert_response :ok
    data = trend_chart_data

    assert_select "section[data-section-key='trends_insights'] [data-controller='multi-series-chart']"
    assert_equal [ "Trend dining", "Trend groceries" ], data["series"].map { |series| series["name"] }.sort
    groceries_series = data["series"].find { |series| series["name"] == "Trend groceries" }

    assert_equal 3, groceries_series["values"].size
    assert_equal 40.0, groceries_series["values"].last["value"]
    assert_equal Date.current.beginning_of_month.iso8601, groceries_series["values"].last["date"]
  end

  test "a selected parent trend includes its subcategory spending" do
    parent = @family.categories.create!(name: "Trend parent", color: "#123123")
    child = @family.categories.create!(name: "Trend child", parent: parent, color: "#321321")

    create_transaction(account: accounts(:depository), name: "Child spend", amount: 30,
                       category: child, date: Date.current)

    enable_preview!
    get reports_path(
      period_type: :custom,
      start_date: 1.month.ago.beginning_of_month.to_date,
      end_date: Date.current.end_of_month,
      trend_category_ids: [ parent.id ]
    )

    assert_response :ok
    series = trend_chart_data["series"].sole

    assert_equal "Trend parent", series["name"]
    assert_equal 2, series["values"].size
    assert_equal 30.0, series["values"].last["value"]
  end

  test "year granularity sums the months in each year" do
    category = @family.categories.create!(name: "Trend yearly", color: "#0F0F0F")
    last_year_start = 1.year.ago.beginning_of_year.to_date
    this_year_start = Date.current.beginning_of_year.to_date

    create_transaction(account: accounts(:depository), name: "Last year", amount: 10,
                       category: category, date: last_year_start + 10.days)
    create_transaction(account: accounts(:depository), name: "Year first", amount: 10,
                       category: category, date: this_year_start + 10.days)
    create_transaction(account: accounts(:depository), name: "Year second", amount: 15,
                       category: category, date: this_year_start + 70.days)

    enable_preview!
    get reports_path(
      period_type: :custom,
      start_date: last_year_start,
      end_date: Date.current.end_of_year.to_date,
      trend_category_ids: [ category.id ],
      trend_granularity: "year"
    )

    assert_response :ok
    series = trend_chart_data["series"].sole

    assert_equal 2, series["values"].size
    assert_equal 10.0, series["values"].first["value"]
    assert_equal 25.0, series["values"].last["value"]
    assert_equal this_year_start.year.to_s, series["values"].last["label"]
  end

  test "year granularity keeps a one-year period visible as a single point" do
    category = @family.categories.create!(name: "Trend single year", color: "#0A0A0A")
    create_transaction(account: accounts(:depository), name: "Single year spend", amount: 12,
                       category: category, date: Date.current.beginning_of_year)

    enable_preview!
    get reports_path(
      period_type: :ytd,
      trend_category_ids: [ category.id ],
      trend_granularity: "year"
    )

    assert_response :ok
    series = trend_chart_data["series"].sole

    assert_equal 1, series["values"].size
    assert_equal 12.0, series["values"].sole["value"]
    assert_equal Date.current.year.to_s, series["values"].sole["label"]
  end

  test "a category from another family never reaches the trend chart" do
    foreign = Category.create!(family: families(:empty), name: "Foreign trend category",
                               color: "#333333", lucide_icon: "shapes")

    enable_preview!
    get reports_path(
      period_type: :custom,
      start_date: 1.month.ago.beginning_of_month.to_date,
      end_date: Date.current.end_of_month,
      trend_category_ids: [ foreign.id ]
    )

    assert_response :ok
    assert_select "[data-controller='multi-series-chart']", count: 0
  end

  test "uncategorized can be selected for the trend" do
    create_transaction(account: accounts(:depository), name: "No category spend",
                       amount: 12, date: Date.current)

    enable_preview!
    get reports_path(
      period_type: :custom,
      start_date: 1.month.ago.beginning_of_month.to_date,
      end_date: Date.current.end_of_month,
      trend_category_ids: [ Category::UNCATEGORIZED_FILTER_VALUE ]
    )

    assert_response :ok
    names = trend_chart_data["series"].map { |series| series["name"] }

    assert_includes names, Category.uncategorized.name
  end

  test "no trend chart renders without a category selection" do
    enable_preview!
    get reports_path(
      period_type: :custom,
      start_date: 1.month.ago.beginning_of_month.to_date,
      end_date: Date.current.end_of_month
    )

    assert_response :ok
    assert_select "[data-controller='multi-series-chart']", count: 0
  end

  test "the trend chart stays hidden without preview access" do
    category = @family.categories.create!(name: "Trend gated", color: "#707070")
    create_transaction(account: accounts(:depository), name: "Gated spend", amount: 20,
                       category: category, date: Date.current)

    get reports_path(period_type: :monthly, trend_category_ids: [ category.id ])

    assert_response :ok
    assert_select "[data-controller='multi-series-chart']", count: 0
    assert_select "[data-section-key='trends_insights']", count: 1
    assert_no_match(/#{Regexp.escape(I18n.t("reports.trends.category_trend.title"))}/, @response.body)
  end

  test "a refund lowers its category in the same bucket" do
    category = @family.categories.create!(name: "Trend refunded", color: "#717171")

    create_transaction(account: accounts(:depository), name: "Purchase", amount: 100,
                       category: category, date: Date.current)
    create_transaction(account: accounts(:depository), name: "Refund", amount: -100,
                       category: category, date: Date.current)

    enable_preview!
    get reports_path(period_type: :monthly, trend_category_ids: [ category.id ])

    assert_response :ok
    series = trend_chart_data["series"].sole

    assert_equal 0.0, series["values"].sum { |point| point["value"] }
  end

  test "the trend leaves out an entry in a currency with no rate" do
    category = @family.categories.create!(name: "Trend won rent", color: "#727272")
    krw = @family.accounts.create!(owner: @user, name: "Seoul trend", balance: 0,
                                   currency: "KRW", accountable: Depository.new)
    create_transaction(account: krw, name: "Rent", amount: 130_000, currency: "KRW",
                       category: category)

    enable_preview!
    get reports_path(period_type: :monthly, trend_category_ids: [ category.id ])

    assert_response :ok
    series = trend_chart_data["series"].sole

    assert_equal 0.0, series["values"].sum { |point| point["value"] }
  end

  test "the category trend uses the selected tags" do
    category = @family.categories.create!(name: "Trend tagged", color: "#131313")
    tag = @family.tags.create!(name: "Trend tag")
    create_transaction(account: accounts(:depository), name: "Tagged spend", amount: 40,
                       category: category, tags: [ tag ], date: TAGGED_MONTH + 9.days)
    create_transaction(account: accounts(:depository), name: "Untagged spend", amount: 60,
                       category: category, date: TAGGED_MONTH + 9.days)

    enable_preview!
    get reports_path(period_type: :custom, start_date: TAGGED_MONTH,
                     end_date: TAGGED_MONTH.end_of_month,
                     filter_tag_ids: [ tag.id ], trend_category_ids: [ category.id ])

    assert_response :ok
    series = trend_chart_data["series"].sole

    assert_equal 40.0, series["values"].sole["value"]
  end

  test "the category trend header shows the active tags" do
    category = @family.categories.create!(name: "Trend header", color: "#141414")
    tag = @family.tags.create!(name: "Trend header tag")

    enable_preview!
    get reports_path(period_type: :monthly, filter_tag_ids: [ tag.id ],
                     trend_category_ids: [ category.id ])

    assert_response :ok
    assert_select "[data-testid='category-trend-tags']", text: /#{Regexp.escape(tag.name)}/
  end

  test "the category trend Apply keeps the tag filter" do
    category = @family.categories.create!(name: "Trend apply", color: "#151515")
    tag = @family.tags.create!(name: "Trend apply tag")

    enable_preview!
    get reports_path(period_type: :monthly, filter_tag_ids: [ tag.id ],
                     trend_category_ids: [ category.id ])

    assert_response :ok
    form = css_select("form[action='#{reports_path}']").find do |node|
      node.at_css("input[type=checkbox][name='trend_category_ids[]']")
    end

    assert form, "the category filter form must render"
    assert form.at_css("input[type=hidden][name='filter_tag_ids[]'][value='#{tag.id}']"),
           "the category filter Apply drops the tag filter"
  end

  test "the tag filter Apply keeps the trend selection and granularity" do
    category = @family.categories.create!(name: "Trend tag filter", color: "#161616")
    tag = @family.tags.create!(name: "Trend tag filter tag")

    enable_preview!
    get reports_path(period_type: :monthly, filter_tag_ids: [ tag.id ],
                     trend_category_ids: [ category.id ], trend_granularity: "year")

    assert_response :ok
    form = css_select("form[action='#{reports_path}']").find do |node|
      node.at_css("input[type=checkbox][name='filter_tag_ids[]']")
    end

    assert form, "the tag filter form must render"
    assert form.at_css("input[type=hidden][name='trend_category_ids[]'][value='#{category.id}']"),
           "the tag filter Apply drops the trend selection"
    assert form.at_css("input[type=hidden][name='trend_granularity'][value='year']"),
           "the tag filter Apply drops the trend granularity"
  end

  test "period links keep the trend selection and granularity" do
    category = @family.categories.create!(name: "Trend link", color: "#444444")

    get reports_path(period_type: :monthly, trend_category_ids: [ category.id ],
                     trend_granularity: "year")

    assert_response :ok
    assert_select "a[href*='trend_category_ids']", minimum: 1
    assert_select "a[href*='trend_granularity=year']", minimum: 1
  end

  test "period links keep an explicit month on a long range" do
    category = @family.categories.create!(name: "Trend long month", color: "#555555")

    get reports_path(
      period_type: :custom,
      start_date: 3.years.ago.beginning_of_year.to_date,
      end_date: Date.current.end_of_month.to_date,
      trend_category_ids: [ category.id ],
      trend_granularity: "month"
    )

    assert_response :ok
    assert_select "a[href*='trend_granularity=month']", minimum: 1
  end

  test "period links keep an explicit year on a long range" do
    category = @family.categories.create!(name: "Trend long year", color: "#575757")

    get reports_path(
      period_type: :custom,
      start_date: 3.years.ago.beginning_of_year.to_date,
      end_date: Date.current.end_of_month.to_date,
      trend_category_ids: [ category.id ],
      trend_granularity: "year"
    )

    assert_response :ok
    assert_select "a[href*='period_type=monthly'][href*='trend_granularity=year']", minimum: 1
  end

  test "the custom date form omits an automatic granularity" do
    enable_preview!
    get reports_path(
      period_type: :custom,
      start_date: 3.years.ago.beginning_of_year.to_date,
      end_date: Date.current.end_of_month.to_date
    )

    assert_response :ok
    assert_select "form input[name='trend_granularity']", count: 0
  end

  test "the custom date form keeps an explicit granularity" do
    enable_preview!
    get reports_path(
      period_type: :custom,
      start_date: 3.years.ago.beginning_of_year.to_date,
      end_date: Date.current.end_of_month.to_date,
      trend_granularity: "year"
    )

    assert_response :ok
    assert_select "form[data-controller='auto-submit-form'] input[name='trend_granularity'][value='year']", count: 1
    # The category filter and tag filter forms also carry the explicit choice.
    assert_select "form input[name='trend_granularity'][value='year']", count: 3
  end

  test "the trend chart lists its values in a data table" do
    category = @family.categories.create!(name: "Trend table", color: "#787878")
    create_transaction(account: accounts(:depository), name: "Table spend", amount: 40,
                       category: category, date: Date.current)

    enable_preview!
    get reports_path(period_type: :last_6_months, trend_category_ids: [ category.id ])

    assert_response :ok
    assert_select "details table caption", text: I18n.t("reports.trends.category_trend.data_table_caption")
    assert_select "details table th[scope='col']", text: "Trend table"
    assert_select "details table th[scope='row']", minimum: 6
  end

  test "the amount sort link keeps the trend selection and granularity" do
    category = @family.categories.create!(name: "Trend sort", color: "#666666")
    create_transaction(account: accounts(:depository), name: "Sort spend", amount: 25,
                       category: category, date: Date.current)

    get reports_path(period_type: :last_6_months, trend_category_ids: [ category.id ],
                     trend_granularity: "year")

    assert_response :ok
    assert_select "a[href*='sort_by=amount'][href*='trend_category_ids']", minimum: 1
    assert_select "a[href*='sort_by=amount'][href*='trend_granularity=year']", minimum: 1
  end

  # POSTing to settings_api_keys_path is create, which needs api_key params.
  test "google sheets instructions link to the API keys page" do
    get google_sheets_instructions_reports_url

    assert_response :success
    assert_select "a[href=?][data-turbo-frame=_top]", settings_api_keys_path, text: I18n.t("reports.google_sheets_instructions.go_to_api_keys")
    assert_select "form[action=?]", settings_api_keys_path, count: 0
  end

  test "google sheets instructions give an export URL with the selected tags" do
    tag = @family.tags.create!(name: "Sheets tag")

    get google_sheets_instructions_reports_url(period_type: :monthly, filter_tag_ids: [ tag.id ])

    assert_response :success
    assert_includes CGI.unescapeHTML(@response.body), export_transactions_reports_url(period_type: :monthly, filter_tag_ids: [ tag.id ], format: :csv)
  end

  test "the tag filter limits the summary, trends and breakdown to transactions with any of the tags" do
    travel, work = seed_tagged_month

    get reports_path(period_type: :monthly, start_date: TAGGED_MONTH, end_date: TAGGED_MONTH.end_of_month,
                     filter_tag_ids: [ travel.id, work.id ])

    assert_response :ok
    # $30 travel + $50 work + $20 carrying both, counted once; the $1,000
    # "Other" expense and the untagged $500 salary are left out.
    assert_equal "$10.00", summary_value(I18n.t("reports.summary.total_income"))
    assert_equal "$100.00", summary_value(I18n.t("reports.summary.total_expenses"))
    assert_select "[data-section-key=trends_insights] tbody tr", count: 1 do
      assert_select "td", text: "$10.00"
      assert_select "td", text: "$100.00"
    end
    breakdown = css_select("[data-section-key=transactions_breakdown]").text.squish
    assert_includes breakdown, "#{I18n.t("reports.transactions_breakdown.table.income")}: $10.00"
    assert_includes breakdown, "#{I18n.t("reports.transactions_breakdown.table.expense")}: $100.00"
  end

  test "without a tag filter every transaction is counted" do
    seed_tagged_month

    get reports_path(period_type: :monthly, start_date: TAGGED_MONTH, end_date: TAGGED_MONTH.end_of_month)

    assert_response :ok
    assert_equal "$510.00", summary_value(I18n.t("reports.summary.total_income"))
    assert_equal "$1,100.00", summary_value(I18n.t("reports.summary.total_expenses"))
  end

  test "the tag filter leaves trades out of the breakdown" do
    tag = @family.tags.create!(name: "Filtered tag")
    create_transaction(account: accounts(:depository), name: "Tagged spend", amount: 42, tags: [ tag ])
    create_trade(securities(:aapl), account: accounts(:investment), qty: 1, date: Date.current, price: 100)

    get reports_path(period_type: :monthly, filter_tag_ids: [ tag.id ])

    assert_response :ok
    assert_select "[data-section-key=transactions_breakdown] tr[data-category]", count: 1
    assert_select "tr[data-category='category-uncategorized']", text: /\$42\.00/
    assert_select "tr[data-category='category-other_investments']", count: 0
  end

  test "tag ids that are not the family's are ignored" do
    seed_tagged_month
    foreign_tag = families(:empty).tags.create!(name: "Someone else's")

    get reports_path(period_type: :monthly, start_date: TAGGED_MONTH, end_date: TAGGED_MONTH.end_of_month,
                     filter_tag_ids: [ foreign_tag.id, "not-a-uuid" ])

    assert_response :ok
    assert_equal "$1,100.00", summary_value(I18n.t("reports.summary.total_expenses"))
    assert_select "button", text: I18n.t("reports.index.tag_filter.all")
    assert_select "input[name='filter_tag_ids[]'][checked]", count: 0
  end

  test "the tag filter lists the family's tags and checks the selected ones" do
    travel, work, other = seed_tagged_month

    get reports_path(period_type: :monthly, filter_tag_ids: [ travel.id, work.id ])

    assert_response :ok
    assert_select "button", text: I18n.t("reports.index.tag_filter.selected", count: 2)
    assert_select "input[name='filter_tag_ids[]'][value=?][checked]", travel.id
    assert_select "input[name='filter_tag_ids[]'][value=?][checked]", work.id
    assert_select "input[name='filter_tag_ids[]'][value=?]:not([checked])", other.id
  end

  test "period controls keep the tag filter" do
    travel, = seed_tagged_month

    get reports_path(period_type: :monthly, start_date: TAGGED_MONTH, end_date: TAGGED_MONTH.end_of_month,
                     filter_tag_ids: [ travel.id ])

    assert_response :ok
    report_links = css_select("a[href^='/reports?']").map { |link| link["href"] }
    assert_operator report_links.size, :>, 5
    report_links.each { |href| assert_includes CGI.unescape(href), "filter_tag_ids[]=#{travel.id}", href }

    get reports_path(period_type: :custom, filter_tag_ids: [ travel.id ])

    assert_select "form[action='#{reports_path}'] input[type=date][name=start_date]" do |inputs|
      form = inputs.first.ancestors("form").first
      assert form.at_css("input[type=hidden][name='filter_tag_ids[]'][value='#{travel.id}']"), "custom range form drops the tag filter"
    end
  end

  test "breakdown rows link to transactions filtered by category and the selected tags" do
    tag = @family.tags.create!(name: "Linked tag")
    category = @family.categories.create!(name: "Tagged groceries", color: "#ABCDEF")
    create_transaction(account: accounts(:depository), name: "Groceries", amount: 42, category: category, tags: [ tag ])
    start_date = Date.current.beginning_of_month
    end_date = Date.current.end_of_month

    get reports_path(period_type: :monthly, start_date: start_date, end_date: end_date, filter_tag_ids: [ tag.id ])

    href = transactions_path(q: { categories: [ category.name ], start_date: start_date, end_date: end_date, tags: [ tag.name ] })
    assert_select "tr[data-category='category-#{category.id}'] a[href=?]", href
  end

  test "export transactions keeps only the selected tags" do
    tag = @family.tags.create!(name: "Export tag")
    tagged = @family.categories.create!(name: "Export Tagged Spend", color: "#111111")
    untagged = @family.categories.create!(name: "Export Untagged Spend", color: "#222222")
    create_transaction(account: accounts(:depository), name: "Tagged", amount: 10, category: tagged, tags: [ tag ])
    create_transaction(account: accounts(:depository), name: "Untagged", amount: 20, category: untagged)

    get export_transactions_reports_path(format: :csv, period_type: :monthly, start_date: Date.current.beginning_of_month,
                                         end_date: Date.current.end_of_month, filter_tag_ids: [ tag.id ])

    assert_response :ok
    assert_match(/Export Tagged Spend/, @response.body)
    assert_no_match(/Export Untagged Spend/, @response.body)
  end

  test "biggest expenses lists the period's largest expenses first and marks one-time ones" do
    category = @family.categories.create!(name: "Big Repairs", color: "#222222")
    create_transaction(name: "Rent", amount: 900, date: BIGGEST_MONTH + 1)
    create_transaction(name: "Garage invoice", amount: 1_200, date: BIGGEST_MONTH + 2, category: category, kind: "one_time")
    create_transaction(name: "Coffee", amount: 4, date: BIGGEST_MONTH + 3)
    create_transaction(name: "Salary", amount: -3_000, date: BIGGEST_MONTH + 4)
    create_transaction(name: "Hidden refund", amount: 2_000, date: BIGGEST_MONTH + 5).update!(excluded: true)
    create_transaction(name: "Move to savings", amount: 2_500, date: BIGGEST_MONTH + 6, kind: "funds_movement")
    create_transaction(name: "Card payoff", amount: 2_600, date: BIGGEST_MONTH + 7, kind: "cc_payment")

    get biggest_expenses_reports_path

    assert_response :ok
    assert_equal [ "Garage invoice", "Rent", "Coffee" ], biggest_expense_names
    assert_select "[data-section-key=biggest_expenses] tbody tr:first-child", text: /One-time/
    assert_select "[data-section-key=biggest_expenses] tbody tr:first-child", text: /Big Repairs/
    assert_select "[data-section-key=biggest_expenses] tbody tr:nth-child(2)", text: /One-time/, count: 0
  end

  test "biggest expenses leaves out trades" do
    security = securities(:aapl)
    create_trade(security, account: accounts(:investment), qty: 100, date: BIGGEST_MONTH + 1, price: 500)
    create_transaction(name: "Rent", amount: 900, date: BIGGEST_MONTH + 1)

    get biggest_expenses_reports_path

    assert_equal [ "Rent" ], biggest_expense_names
  end

  test "biggest expenses follows the count investing as spending setting" do
    create_transaction(name: "Brokerage deposit", amount: 1_000, date: BIGGEST_MONTH + 1, kind: "investment_contribution")
    create_transaction(name: "Rent", amount: 900, date: BIGGEST_MONTH + 1)

    @family.update!(investment_contributions_as_spending: true)
    get biggest_expenses_reports_path
    assert_equal [ "Brokerage deposit", "Rent" ], biggest_expense_names

    @family.update!(investment_contributions_as_spending: false)
    get biggest_expenses_reports_path
    assert_equal [ "Rent" ], biggest_expense_names
  end

  # Some importers store loan payments and contributions as negative amounts;
  # the income statement counts them as expenses either way.
  test "biggest expenses keeps negative loan payments and contributions as expenses" do
    @family.update!(investment_contributions_as_spending: true)
    create_transaction(name: "Imported contribution", amount: -1_500, date: BIGGEST_MONTH + 1, kind: "investment_contribution")
    create_transaction(name: "Imported loan payment", amount: -700, date: BIGGEST_MONTH + 1, kind: "loan_payment")
    create_transaction(name: "Rent", amount: 900, date: BIGGEST_MONTH + 1)
    create_transaction(name: "Refund", amount: -2_000, date: BIGGEST_MONTH + 1)

    get biggest_expenses_reports_path

    assert_equal [ "Imported contribution", "Rent", "Imported loan payment" ], biggest_expense_names
    assert_select "[data-section-key=biggest_expenses] tbody tr:first-child", text: /\$1,500\.00/
  end

  test "biggest expenses ranks a foreign-currency expense by its converted amount" do
    eur = @family.accounts.create!(owner: @user, name: "Paris", balance: 0, currency: "EUR", accountable: Depository.new)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: BIGGEST_MONTH + 2, rate: 2)
    create_transaction(name: "Rent", amount: 900, date: BIGGEST_MONTH + 1)
    create_transaction(account: eur, name: "Paris hotel", amount: 600, currency: "EUR", date: BIGGEST_MONTH + 2)

    get biggest_expenses_reports_path

    assert_equal [ "Paris hotel", "Rent" ], biggest_expense_names
    assert_select "[data-section-key=biggest_expenses] tbody tr:first-child", text: /\$1,200\.00/
  end

  test "biggest expenses shows as many rows as the user chose" do
    12.times { |i| create_transaction(name: "Expense #{i}", amount: 100 + i, date: BIGGEST_MONTH + 1) }

    get biggest_expenses_reports_path
    assert_equal 10, biggest_expense_names.size
    assert_select "[data-section-key=biggest_expenses] summary [aria-pressed=true]", text: "10"

    @user.update_columns(preferences: (@user.preferences || {}).merge("reports_biggest_expenses_limit" => 5))
    get biggest_expenses_reports_path
    assert_equal (7..11).map { |i| "Expense #{i}" }.reverse, biggest_expense_names
  end

  test "biggest expenses applies the tag filter" do
    tag = @family.tags.create!(name: "Holiday")
    create_transaction(name: "Flight", amount: 400, date: BIGGEST_MONTH + 1, tags: [ tag ])
    create_transaction(name: "Rent", amount: 900, date: BIGGEST_MONTH + 1)

    get biggest_expenses_reports_path(filter_tag_ids: [ tag.id ])

    assert_equal [ "Flight" ], biggest_expense_names
  end

  test "biggest expenses is hidden when the period has no expenses" do
    create_transaction(name: "Salary", amount: -3_000, date: BIGGEST_MONTH + 1)

    get biggest_expenses_reports_path

    assert_response :ok
    assert_select "[data-section-key=biggest_expenses]", count: 0
  end

  test "the printed report lists the biggest expenses" do
    create_transaction(name: "Garage invoice", amount: 1_200, date: BIGGEST_MONTH + 2, kind: "one_time")
    create_transaction(name: "Rent", amount: 900, date: BIGGEST_MONTH + 1)

    get print_reports_path(period_type: :custom, start_date: BIGGEST_MONTH, end_date: BIGGEST_MONTH.end_of_month)

    assert_response :ok
    section = css_select("section").find { |node| node.text.include?(I18n.t("reports.print.biggest_expenses.title")) }
    assert section, "the biggest expenses section is printed"
    rows = section.css("tbody tr").map(&:text)
    assert_match(/Garage invoice\s+One-time/, rows.first)
    assert_match(/Rent/, rows.second)
  end

  test "the reports preferences endpoint stores an offered biggest expenses limit only" do
    patch update_preferences_reports_path, params: { preferences: { reports_biggest_expenses_limit: 25 } }, as: :json
    assert_response :ok
    assert_equal 25, @user.reload.reports_biggest_expenses_limit

    patch update_preferences_reports_path, params: { preferences: { reports_biggest_expenses_limit: 7 } }, as: :json
    assert_response :ok
    assert_equal 25, @user.reload.preferences["reports_biggest_expenses_limit"]

    patch update_preferences_reports_path, params: { preferences: { reports_biggest_expenses_limit: "abc" } }, as: :json
    assert_response :ok
    assert_equal 25, @user.reload.preferences["reports_biggest_expenses_limit"]
  end

  private
    def with_memory_cache
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      yield
    end

    def biggest_expenses_reports_path(**params)
      reports_path(period_type: :custom, start_date: BIGGEST_MONTH, end_date: BIGGEST_MONTH.end_of_month, **params)
    end

    def biggest_expense_names
      css_select("[data-section-key=biggest_expenses] tbody tr td:first-child a").map { |node| node.text.strip }
    end

    def enable_preview!
      @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    end

    def trend_chart_data
      chart = css_select("[data-controller='multi-series-chart']").first

      assert chart, "the trend chart must render"
      JSON.parse(chart["data-multi-series-chart-data-value"])
    end

    # Travel, Work and Other tags on a month of their own, away from the
    # fixture transactions, with expenses of $30 (travel), $50 (work), $20
    # (both) and $1,000 (other), and income of $10 (travel) and $500 (none).
    def seed_tagged_month
      travel = @family.tags.create!(name: "Travel")
      work = @family.tags.create!(name: "Work")
      other = @family.tags.create!(name: "Other")
      account = accounts(:depository)
      date = TAGGED_MONTH + 9.days

      create_transaction(account: account, date: date, name: "Hotel", amount: 30, tags: [ travel ])
      create_transaction(account: account, date: date, name: "Laptop stand", amount: 50, tags: [ work ])
      create_transaction(account: account, date: date, name: "Airport lunch", amount: 20, tags: [ travel, work ])
      create_transaction(account: account, date: date, name: "Rent", amount: 1000, tags: [ other ])
      create_transaction(account: account, date: date, name: "Refund", amount: -10, tags: [ travel ])
      create_transaction(account: account, date: date, name: "Salary", amount: -500)

      [ travel, work, other ]
    end

    # The figure on the summary card headed by label.
    def summary_value(label)
      heading = css_select("h3").find { |node| node.text.strip == label }
      heading.ancestors("div.bg-container").first.at_css("p.text-2xl").text.strip
    end

    # Takes every fixture investment account out of the card's scope, so an
    # account the test creates is the family's only one; otherwise the
    # fixtures satisfy the visible-accounts gate on their own.
    def exclude_fixture_investment_accounts
      @family.accounts.where(accountable_type: %w[Investment Crypto]).update_all(exclude_from_reports: true)
    end

    # An investment account holding 5 shares at a basis of 100, with 2 sold at
    # 150 on +date+ (a gain of $100.00), then closed.
    # +close: false+ leaves it open; +excluded: true+ marks the sale excluded.
    def closed_account_with_disposal(date:, label: "Sell", owner: @user, close: true, excluded: false)
      account = @family.accounts.create!(name: "Closed brokerage", balance: 0, currency: "USD",
                                         accountable: Investment.new, owner: owner)
      security = Security.create!(ticker: "CLS#{SecureRandom.hex(3)}", name: "Closed Position")
      account.holdings.create!(security: security, date: date, qty: 5, price: 150,
                               amount: BigDecimal(750), currency: "USD", cost_basis: 100)
      account.entries.create!(
        date: date, name: "out #{label}", amount: -300, currency: "USD", excluded: excluded,
        entryable: Trade.new(security: security, qty: -2, price: 150, currency: "USD",
                             investment_activity_label: label)
      )
      account.disable! if close
      [ account, security ]
    end

    # n EUR-priced disposals in a USD account, each on its own date with its
    # own rate row, so every one needs a distinct lookup.
    def seed_foreign_disposals(account, count)
      base = Date.current.beginning_of_month

      count.times do |i|
        date = base + i
        security = Security.create!(ticker: "EUX#{SecureRandom.hex(3)}", name: "Euro Listed #{i}")

        ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: date, rate: 1.5)
        account.holdings.create!(security: security, date: date, qty: 5, price: 150,
                                 amount: BigDecimal(750), currency: "USD", cost_basis: 100)
        create_trade(security, account: account, qty: -2, date: date, price: 150, currency: "EUR")
      end
    end

    # A cash-only trade, as Trade::CreateForm#create_income_trade records a
    # manually entered dividend, interest payment or fee.
    def create_income_trade(account:, label:, amount:)
      account.entries.create!(name: label, date: Date.current, amount: amount, currency: "USD",
                              entryable: Trade.new(qty: 0, price: 0, currency: "USD", security: securities(:aapl),
                                                   investment_activity_label: label))
    end
end
