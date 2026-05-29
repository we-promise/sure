require "test_helper"

class RetirementBucketEntryTest < ActiveSupport::TestCase
  setup do
    @entry = retirement_bucket_entries(:bob_investment)
    @goal = goals(:retirement_bob)
  end

  test "fixture is valid" do
    assert @entry.valid?, @entry.errors.full_messages.to_sentence
  end

  test "account is unique within a plan" do
    dup = RetirementBucketEntry.new(goal_retirement: @goal, account: @entry.account)
    assert_not dup.valid?
    assert_includes dup.errors.attribute_names, :account_id
  end

  test "account must belong to the plan's family" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    foreign = Account.create!(family: other_family, accountable: Depository.new, name: "Foreign", currency: "USD", balance: 1)

    entry = RetirementBucketEntry.new(goal_retirement: @goal, account: foreign)
    assert_not entry.valid?
    assert_includes entry.errors[:account],
      I18n.t("activerecord.errors.models.retirement_bucket_entry.attributes.account.must_belong_to_family")
  end
end
