require "test_helper"

class AiE2eBillSetupTest < ActiveSupport::TestCase
  include AiE2eHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.update!(ai_enabled: true)
    @entries = 3.times.map do |i|
      accounts(:depository).entries.create!(date: i.months.ago.to_date.change(day: 3), amount: 15.49, currency: "USD",
                                             name: "NETFLIX.COM 866-579-7172", entryable: Transaction.new)
    end
  end

  test "Kilo suggests a bill's setup from its charges" do
    suggestion = with_live_ai do
      RecurringTransaction::AiSetupSuggester.new(@family, user: @user).suggest_from_entries(@entries)
    end

    assert suggestion.any_proposal?, "no field proposed"
    assert_includes [ nil, *RecurringTransaction::FrequencyPreset::PRESETS ], suggestion.frequency
    assert suggestion.category_id.nil? || @family.categories.exists?(suggestion.category_id)
    assert_ai_usage(@family, :bill_setup)
    assert_no_ai_errors
  end
end
