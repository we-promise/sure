require "test_helper"

class Transactions::InterfaceLocalizationViewTest < ActionView::TestCase
  setup do
    @user = users(:family_admin)
    Current.session = Session.create!(user: @user)
    @accessible_account_ids = @user.accessible_accounts.pluck(:id).to_set
    @split_parent_entry_ids = Set.new
  end

  test "both selection bars translate the bulk delete title without changing the action" do
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      I18n.with_locale(locale) do
        %w[transactions/selection_bar entries/selection_bar].each do |partial|
          html = Nokogiri::HTML.fragment(render(partial: partial))
          button = html.at_css("button[data-bulk-select-scope-param='bulk_delete']")
          assert_equal I18n.t("transactions.show.delete", fallback: false, raise: true), button["title"], "#{locale}: #{partial}"
          assert_equal "bulk-select#submitBulkRequest", button["data-action"]
          assert_equal "button", button["type"]
        end
      end
    end
  end

  test "one-time income and expense tooltips are localized without translating user names" do
    transaction = Transaction.create!(kind: "one_time")
    entry = Entry.create!(account: accounts(:depository), entryable: transaction,
                          name: "Synthetic <name> & original", amount: 12.34,
                          currency: "USD", date: Date.current)

    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      I18n.with_locale(locale) do
        { income: -12.34, expense: 12.34 }.each do |type, amount|
          entry.amount = amount
          html = Nokogiri::HTML.fragment(render(partial: "transactions/transaction", locals: { entry: entry }))
          expected = I18n.t("transactions.transaction.one_time_#{type}_tooltip", fallback: false, raise: true)
          assert html.css("span[title]").any? { |node| node["title"] == expected }, "#{locale}: #{type} tooltip"
          assert html.css("a").any? { |node| node.text == entry.name }, "User-entered name must be preserved"
          assert_empty html.css("name"), "User-entered markup must remain text"
        end
      end
    end
  end

  test "ordinary transactions do not acquire a one-time tooltip" do
    I18n.with_locale(:"zh-CN") do
      html = Nokogiri::HTML.fragment(render(partial: "transactions/transaction", locals: { entry: entries(:transaction) }))
      assert_empty html.css("span[title]").select { |node| node["title"].include?("一次性") }
    end
  end
end
