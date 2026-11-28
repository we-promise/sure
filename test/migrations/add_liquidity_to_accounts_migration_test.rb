# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261006170000_add_liquidity_to_accounts")

# The backfill keeps a frozen copy of the subtype defaults. These tests fail
# when a subtype is added or reclassified in the model without the migration's
# lists, which would backfill existing accounts differently from new ones.
class AddLiquidityToAccountsMigrationTest < ActiveSupport::TestCase
  test "investment lists match the model default for every subtype" do
    Investment::SUBTYPES.each_key do |subtype|
      assert_equal Investment.default_liquidity_for(subtype),
                   backfilled_investment_level(subtype),
                   "Investment/#{subtype}"
    end
  end

  test "depository lists match the model default for every subtype" do
    Depository::SUBTYPES.each_key do |subtype|
      assert_equal Depository.default_liquidity_for(subtype),
                   backfilled_depository_level(subtype),
                   "Depository/#{subtype}"
    end
  end

  private
    def backfilled_investment_level(subtype)
      if AddLiquidityToAccounts::INVESTMENT_LOCKED_SUBTYPES.include?(subtype)
        "locked"
      elsif AddLiquidityToAccounts::INVESTMENT_LONG_TERM_SUBTYPES.include?(subtype)
        "long_term"
      else
        "short_term"
      end
    end

    def backfilled_depository_level(subtype)
      if AddLiquidityToAccounts::DEPOSITORY_LOCKED_SUBTYPES.include?(subtype)
        "locked"
      elsif AddLiquidityToAccounts::DEPOSITORY_SHORT_TERM_SUBTYPES.include?(subtype)
        "short_term"
      elsif AddLiquidityToAccounts::DEPOSITORY_LONG_TERM_SUBTYPES.include?(subtype)
        "long_term"
      else
        "immediate"
      end
    end
end
