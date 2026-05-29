require "test_helper"

class PensionSourceTest < ActiveSupport::TestCase
  setup do
    @source = pension_sources(:de_grv_bob)
  end

  test "fixture is valid" do
    assert @source.valid?, @source.errors.full_messages.to_sentence
  end

  test "validates enum-like inclusions" do
    @source.kind = "bogus"
    assert_not @source.valid?
    assert_includes @source.errors.attribute_names, :kind
  end

  test "end_age required for fixed-term payout" do
    @source.payout_shape = "monthly_fixed_term"
    @source.end_age = nil
    assert_not @source.valid?
    assert_includes @source.errors[:end_age],
      I18n.t("activerecord.errors.models.pension_source.attributes.end_age.required_for_fixed_term")
  end

  test "end_age must exceed start_age" do
    @source.end_age = @source.start_age - 1
    assert_not @source.valid?
  end

  test "amount_money uses the source currency" do
    assert_equal Money.new(1510, "EUR"), @source.amount_money
  end

  test "effective_rate_override bounded between 0 and 1" do
    @source.effective_rate_override = 1.5
    assert_not @source.valid?
  end
end
