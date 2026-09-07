require "test_helper"

class TradeRepublicLocaleTest < ActiveSupport::TestCase
  PLURALIZED_KEYS = %w[
    trade_republic_items.trade_republic_item.data_quality.positions
    trade_republic_items.trade_republic_item.data_quality.unpriced
    trade_republic_items.trade_republic_item.data_quality.events
    trade_republic_items.trade_republic_item.data_quality.unknown
    trade_republic_items.trade_republic_item.data_quality.expenses
    trade_republic_items.complete_account_setup.success
    trade_republic_items.complete_account_setup.partial_failure
  ].freeze

  test "Romanian translations cover one few and other plural branches" do
    assert_plural_branches(:ro, [ 1, 2, 20 ], keys: PLURALIZED_KEYS.last(2))
  end

  test "Ukrainian translations cover one few many and other plural branches" do
    assert_plural_branches(:uk, [ 1, 2, 5, 1.5 ])
  end

  private

    def assert_plural_branches(locale, counts, keys: PLURALIZED_KEYS)
      keys.each do |key|
        counts.each do |count|
          translation = I18n.t(key, locale: locale, count: count, amount: "10 EUR")

          refute_match(/translation missing/i, translation, "#{locale}.#{key} is missing count=#{count}")
          assert_includes translation, count.to_s unless count == 1
        end
      end
    end
end
