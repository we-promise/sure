require "test_helper"

class AiE2eBillSetupTest < ActiveSupport::TestCase
  include AiE2eHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.update!(ai_enabled: true)
    @entry = accounts(:depository).entries.create!(date: 3.months.ago.to_date.change(day: 3), amount: 15.49,
                                                   currency: "USD", name: "NETFLIX.COM 866-579-7172",
                                                   entryable: Transaction.new)
    2.times do |i|
      accounts(:depository).entries.create!(date: i.months.ago.to_date.change(day: 3), amount: 15.49,
                                            currency: "USD", name: "NETFLIX.COM 866-579-7172",
                                            entryable: Transaction.new)
    end
  end

  test "Kilo suggests a bill's setup from its charges" do
    suggestion = @family.recurring_transaction_suggestions.create!(user: @user, entry: @entry, mode: :fill)

    with_live_ai do
      Ai::GenerationJob.perform_now(:bill_setup, ai_run_args(:bill_setup, ids: [ suggestion.id ],
                                                             family: @family, id: suggestion.id))
    end

    answer = suggestion.reload.proposal
    assert answer.any_proposal?, "no field proposed"
    assert_includes [ nil, *RecurringTransaction::FrequencyPreset::PRESETS ], answer.frequency
    assert answer.category_id.nil? || @family.categories.exists?(answer.category_id)
    assert_ai_usage(@family, :bill_setup)
    assert_no_ai_errors
  end
end
