require "test_helper"

class AccountsBalanceCardViewTest < ActionView::TestCase
  # The fixture holds 10000 USD, so a card that drops the amount or its
  # currency, or shows zero, fails the text match.
  setup do
    @account = accounts(:investment)
  end

  # The Reports investment card renders with the defaults, so these are the
  # classes that page has always drawn.
  test "the defaults draw the plain card" do
    render partial: "accounts/balance_card", locals: { account: @account, href: "/accounts/1" }

    assert_select "a[href='/accounts/1'][class=?]", "bg-container-inset rounded-lg p-4 flex items-center justify-between hover:bg-container-hover transition-colors" do
      assert_select "> div[class=?]", "flex items-center gap-3" do
        assert_select "> div:not([class])" do
          assert_select "p[class=?]", "font-medium text-primary text-sm", text: @account.name
          assert_select "p[class=?]", "text-xs text-secondary", text: @account.short_subtype_label
        end
      end
      assert_select "> p[class=?]", "font-medium text-primary privacy-sensitive", text: "$10,000.00"
    end
  end

  test "truncate and focus_ring fit the card to a narrow cell and show keyboard focus" do
    render partial: "accounts/balance_card", locals: { account: @account, href: "/accounts/1", truncate: true, focus_ring: true }

    assert_select "a.focus-ring" do
      assert_select "> div.min-w-0 > div.min-w-0" do
        assert_select "p.truncate", count: 2
      end
      assert_select "> p.whitespace-nowrap", text: "$10,000.00"
    end
  end
end
