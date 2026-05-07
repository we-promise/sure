require "test_helper"

class CreditCardTest < ActiveSupport::TestCase
  test "is invalid when expiration date is in the past" do
    card = credit_cards(:one)
    card.expiration_date = Date.yesterday

    assert_not card.valid?
    assert_includes card.errors[:expiration_date], "must be greater than or equal to #{Date.current}"
  end

  test "is valid when expiration date is today or later" do
    card = credit_cards(:one)
    card.expiration_date = Date.current

    assert card.valid?
  end
end
