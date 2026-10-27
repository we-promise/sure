require "test_helper"
require "csv"

class ReportsLocalizationTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @start_date = Date.new(2020, 1, 1)
    @end_date = Date.new(2020, 2, 29)
    @account = @family.accounts.create!(
      name: "Synthetic report account", owner: @user, currency: @family.currency,
      balance: 0, status: :active, accountable: Depository.new
    )
    @income = @family.categories.create!(name: "Synthetic Income, Keep 原文")
    @expense = @family.categories.create!(name: "Synthetic Expense 原文")
    [
      [ @start_date, "-1234.56", @income ], [ @end_date, "-10.44", @income ],
      [ @start_date, "42.12", @expense ], [ @end_date, "7.88", @expense ],
      [ @end_date, "5.25", nil ]
    ].each do |date, amount, category|
      create_transaction(account: @account, date: date, amount: BigDecimal(amount),
                         currency: @family.currency, category: category)
    end
    create_transaction(account: @account, date: @start_date, amount: 999,
                       currency: @family.currency, category: @expense, kind: "one_time")
  end

  test "CSV localizes human readable headings while preserving rows amounts order and user category names" do
    stored_entries = @account.entries.order(:id).pluck(:id, :amount, :currency, :date)
    assert_no_difference [ "Entry.count", "Transaction.count" ] do
      LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
        get export_transactions_reports_path(format: :csv), params: period_params.merge(locale: locale)
        assert_response :success
        assert_equal "text/csv", response.media_type
        rows = CSV.parse(response.body)
        expected = [
          [ tr("reports.transactions_breakdown.table.category", locale), month(@start_date, locale), month(@end_date, locale), tr("reports.trends.total", locale) ],
          [ tr("reports.transactions_breakdown.table.income", locale), "", "", "" ],
          [ @income.name, money("1234.56", locale), money("10.44", locale), money("1245.00", locale) ],
          [ tr("reports.summary.total_income", locale), money("1234.56", locale), money("10.44", locale), money("1245.00", locale) ],
          [],
          [ tr("reports.transactions_breakdown.table.expense", locale), "", "", "" ],
          [ @expense.name, money("42.12", locale), money("7.88", locale), money("50.00", locale) ],
          [ tr("reports.transactions_breakdown.table.uncategorized", locale), money("0", locale), money("5.25", locale), money("5.25", locale) ],
          [ tr("reports.summary.total_expenses", locale), money("42.12", locale), money("13.13", locale), money("55.25", locale) ]
        ]
        assert_equal expected, rows, "CSV layout and amounts must remain correct for #{locale}"
      end
    end
    assert_equal stored_entries, @account.entries.order(:id).pluck(:id, :amount, :currency, :date)
  end

  test "report sections expose complete localized keyboard instructions and localized trend months" do
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      get reports_path, params: period_params.merge(locale: locale)
      assert_response :success
      assert_select "[data-controller='sortable-list'][role='list'][aria-label=?]", tr("reports.index.sections_aria_label", locale)
      assert_select "section[data-section-key='trends_insights'][role='listitem'][aria-label=?]",
        tr("reports.index.section_reorder_aria", locale, title: tr("reports.trends.title", locale))
      assert_select "section[data-section-key='trends_insights'] td span", text: month(@start_date, locale)
      assert_select "section[data-section-key='trends_insights'] td span", text: month(@end_date, locale)
      assert_select ".translation_missing", count: 0
    end
  end

  test "print report localizes date ranges generated date footer and trend months" do
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      get print_reports_path, params: period_params.merge(locale: locale)
      assert_response :success
      assert_select "html[lang=?]", locale
      range = "#{I18n.l(@start_date, format: :long, locale: locale)} – #{I18n.l(@end_date, format: :long, locale: locale)}".squish
      assert_select "title", text: "#{tr('reports.print.document_title', locale)} - #{range}"
      assert_select ".tufte-period", text: range
      assert_select ".tufte-meta", text: /#{Regexp.escape(tr("reports.print.generated_on", locale, date: I18n.l(Date.current, format: :long, locale: locale)).squish)}/
      assert_select ".tufte-footer", text: /#{Regexp.escape("#{month(@start_date, locale)} – #{month(@end_date, locale)}")}/
      assert_select "td", text: month(@start_date, locale)
      assert_select "td", text: month(@end_date, locale)
      assert_select ".translation_missing", count: 0
    end
  end

  test "localized and English uncategorized user names remain separate from genuinely uncategorized rows" do
    localized_name = tr("reports.transactions_breakdown.table.uncategorized", "zh-CN")
    named_localized = @family.categories.create!(name: localized_name)
    named_english = @family.categories.create!(name: "Uncategorized")
    create_transaction(account: @account, date: @end_date, amount: BigDecimal("1.23"),
                       currency: @family.currency, category: named_localized)
    create_transaction(account: @account, date: @end_date, amount: BigDecimal("2.00"),
                       currency: @family.currency, category: named_english)

    %w[en zh-CN].each do |locale|
      get export_transactions_reports_path(format: :csv), params: period_params.merge(locale: locale)
      assert_response :success
      rows = CSV.parse(response.body)
      assert_includes rows, [ named_localized.name, money("0", locale), money("1.23", locale), money("1.23", locale) ]
      assert_includes rows, [ named_english.name, money("0", locale), money("2.00", locale), money("2.00", locale) ]
      assert_includes rows, [ tr("reports.transactions_breakdown.table.uncategorized", locale), money("0", locale), money("5.25", locale), money("5.25", locale) ]
      assert_equal [ @expense.name, money("42.12", locale), money("7.88", locale), money("50.00", locale) ], rows[6]
      assert_equal [ tr("reports.summary.total_expenses", locale), money("42.12", locale), money("16.36", locale), money("58.48", locale) ], rows.last
      assert_equal 11, rows.length
    end
  end

  test "dashboard sections share localized reorder instructions without changing keyboard behavior" do
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      get root_path, params: { locale: locale }
      assert_response :success
      title = tr("pages.dashboard.balance_sheet.title", locale)
      assert_select "section[data-section-key='balance_sheet'][role='listitem'][aria-label=?][draggable='true'][tabindex='0'][aria-grabbed='false']",
        tr("reports.index.section_reorder_aria", locale, title: title) do
        assert_select "h2", text: title
      end
      assert_select "section[data-section-key='balance_sheet'][data-action*='keydown->sortable-list#handleKeyDown']", count: 1
    end
  end

  private
    def period_params
      { period_type: :custom, start_date: @start_date, end_date: @end_date, filter_account_id: @account.id }
    end

    def tr(key, locale, **options)
      assert I18n.exists?(key, locale, fallback: false), "Explicit translation required: #{locale}.#{key}"
      I18n.t(key, locale: locale, fallback: false, raise: true, **options)
    end

    def month(date, locale)
      I18n.l(date, format: :month_year, locale: locale)
    end

    def money(amount, locale)
      I18n.with_locale(locale) { Money.new(BigDecimal(amount), @family.currency).format }
    end
end
