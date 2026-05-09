require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "#icon normalizes icon names to lowercase" do
    capture = []

    singleton_class.send(:define_method, :lucide_icon) do |key, **opts|
      capture << [ key, opts ]
      "<svg></svg>".html_safe
    end

    icon("Key")

    assert_equal "key", capture.first.first
  ensure
    singleton_class.send(:remove_method, :lucide_icon) if singleton_class.method_defined?(:lucide_icon)
  end

  test "#icon falls back when lucide icon is unknown" do
    calls = []

    singleton_class.send(:define_method, :lucide_icon) do |key, **_opts|
      calls << key
      raise ArgumentError, "Unknown icon #{key}" if key == "not-a-real-icon"

      "<svg></svg>".html_safe
    end

    result = icon("not-a-real-icon")

    assert_equal [ "not-a-real-icon", "key" ], calls
    assert_equal "<svg></svg>", result
  ensure
    singleton_class.send(:remove_method, :lucide_icon) if singleton_class.method_defined?(:lucide_icon)
  end

  test "#title(page_title)" do
    title("Test Title")
    assert_equal "Test Title", content_for(:title)
  end

  test "#header_title(page_title)" do
    header_title("Test Header Title")
    assert_equal "Test Header Title", content_for(:header_title)
  end

  def setup
    @account1 = Account.new(currency: "USD", balance: 1)
    @account2 = Account.new(currency: "USD", balance: 2)
    @account3 = Account.new(currency: "EUR", balance: -7)
  end

  test "#totals_by_currency(collection: collection, money_method: money_method)" do
    assert_equal "$3.00", totals_by_currency(collection: [ @account1, @account2 ], money_method: :balance_money)
    assert_equal "$3.00 | -€7.00", totals_by_currency(collection: [ @account1, @account2, @account3 ], money_method: :balance_money)
    assert_equal "", totals_by_currency(collection: [], money_method: :balance_money)
    assert_equal "$0.00", totals_by_currency(collection: [ Account.new(currency: "USD", balance: 0) ], money_method: :balance_money)
    assert_equal "-$3.00 | €7.00", totals_by_currency(collection: [ @account1, @account2, @account3 ], money_method: :balance_money, negate: true)
  end

  test "#currency_picker_options_for_family returns enabled family currencies" do
    family = families(:dylan_family)
    family.update!(currency: "SGD", enabled_currencies: [ "USD" ])

    assert_equal [ "SGD", "USD" ], currency_picker_options_for_family(family)
  end

  test "#currency_picker_options_for_family keeps selected legacy currency visible" do
    family = families(:dylan_family)
    family.update!(currency: "SGD", enabled_currencies: [ "USD" ])

    assert_equal [ "SGD", "USD", "EUR" ], currency_picker_options_for_family(family, extra: "EUR")
  end
end
