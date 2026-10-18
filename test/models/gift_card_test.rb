require "test_helper"

class GiftCardTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create_and_sync(
      {
        name: "Bookstore gift card",
        balance: 50,
        currency: "USD",
        owner: users(:family_admin),
        accountable_type: "GiftCard",
        accountable_attributes: { card_format: "digital", face_value: 50, face_value_currency: "USD", card_number: "ABCD-1234", pin: "9876", redeem_url: "https://books.example/redeem?token=SECRET" }
      },
      skip_initial_sync: true,
      opening_balance_date: Date.new(2026, 9, 1)
    )
    @gift_card = @account.gift_card
  end

  test "is an asset tracked as cash so spending lowers the balance" do
    assert_equal "asset", GiftCard.classification
    assert_equal :cash, @account.balance_type
  end

  test "expiry status relative to a reference date" do
    today = Date.new(2026, 10, 16)

    @gift_card.expires_on = nil
    assert_not @gift_card.expired?(as_of: today)
    assert_not @gift_card.expiring_soon?(as_of: today)
    assert_nil @gift_card.days_until_expiry(as_of: today)

    @gift_card.expires_on = today + 10.days
    assert_not @gift_card.expired?(as_of: today)
    assert @gift_card.expiring_soon?(as_of: today)
    assert_equal 10, @gift_card.days_until_expiry(as_of: today)

    @gift_card.expires_on = today
    assert_not @gift_card.expired?(as_of: today), "a card is still usable on its expiry date"
    assert @gift_card.expiring_soon?(as_of: today)

    @gift_card.expires_on = today + 31.days
    assert_not @gift_card.expiring_soon?(as_of: today)

    @gift_card.expires_on = today - 1.day
    assert @gift_card.expired?(as_of: today)
    assert_not @gift_card.expiring_soon?(as_of: today)
  end

  test "initial and spent amounts are unknown without a face value" do
    @gift_card.update_column(:face_value, nil)

    assert_nil @gift_card.initial_amount
    assert_nil @gift_card.spent_amount
  end

  test "a known initial amount cannot be cleared" do
    @gift_card.face_value = nil
    assert_not @gift_card.valid?
    assert @gift_card.errors.of_kind?(:face_value, :blank)

    @gift_card.face_value = 40
    assert @gift_card.valid?
  end

  test "editing the balance keeps the initial amount" do
    # A manual cash account without reconciliations takes a balance edit by
    # moving its opening valuation, so the initial amount can't be read from it.
    assert @account.set_current_balance(20).success?
    @gift_card = @account.reload.gift_card

    assert_equal Money.new(50, "USD"), @gift_card.initial_amount
    assert_equal Money.new(30, "USD"), @gift_card.spent_amount
  end

  test "after a currency change the initial amount keeps its currency and spending is unknown" do
    ExchangeRate.expects(:find_or_fetch_rate).never
    @account.update!(currency: "EUR")
    @gift_card = @account.reload.gift_card

    assert_equal Money.new(50, "USD"), @gift_card.initial_amount
    assert_nil @gift_card.spent_amount
  end

  test "the initial amount is unknown without its currency" do
    @gift_card.update_column(:face_value_currency, nil)

    assert_nil @gift_card.initial_amount
    assert_nil @gift_card.spent_amount
  end

  test "a face value first entered on edit is in the account's currency" do
    @gift_card.update_columns(face_value: nil, face_value_currency: nil)
    @account.update!(currency: "EUR")

    @account.reload.gift_card.update!(face_value: 80)

    assert_equal "EUR", @account.gift_card.face_value_currency
    assert_equal Money.new(80, "EUR"), @account.gift_card.initial_amount
  end

  test "initial amount cannot be negative" do
    @gift_card.face_value = -1
    assert_not @gift_card.valid?
  end

  test "only physical and digital formats are allowed" do
    @gift_card.card_format = "plastic"
    assert_not @gift_card.valid?

    @gift_card.card_format = "physical"
    assert @gift_card.valid?
  end

  test "redeem url must be a web link" do
    @gift_card.redeem_url = "javascript:alert(1)"
    assert_not @gift_card.valid?

    @gift_card.redeem_url = "https://example.com/redeem"
    assert @gift_card.valid?
  end

  test "blank codes are stored as nil" do
    @gift_card.update!(card_number: "  ", pin: "", redeem_url: " ")

    assert_nil @gift_card.card_number
    assert_nil @gift_card.pin
    assert_nil @gift_card.redeem_url
  end

  test "code, pin and redeem link are encrypted at rest" do
    skip "Encryption not configured" unless GiftCard.encryption_ready?

    raw = GiftCard.connection.select_one("SELECT card_number, pin, redeem_url FROM gift_cards WHERE id = #{GiftCard.connection.quote(@gift_card.id)}")

    assert_not_equal "ABCD-1234", raw["card_number"]
    assert_not_equal "9876", raw["pin"]
    assert_no_match "SECRET", raw["redeem_url"]
    @gift_card.reload
    assert_equal "ABCD-1234", @gift_card.card_number
    assert_equal "9876", @gift_card.pin
    assert_equal "https://books.example/redeem?token=SECRET", @gift_card.redeem_url
  end

  test "credentials stay out of serialized output" do
    serialized = @account.as_json(include: { accountable: {} })["accountable"]

    assert_equal "digital", serialized["card_format"]
    assert_equal "50.0", serialized["face_value"]
    assert_not serialized.key?("card_number")
    assert_not serialized.key?("pin")
    assert_not serialized.key?("redeem_url")

    assert_equal({}, @gift_card.as_json(only: %i[card_number pin redeem_url]))
  end

  test "credentials are shown to the owner and full control shares only" do
    member = users(:family_member)
    assert_equal({ card_number: "ABCD-1234", pin: "9876" }, @gift_card.visible_codes_for(users(:family_admin)))
    assert_equal "https://books.example/redeem?token=SECRET", @gift_card.visible_redeem_url_for(users(:family_admin))

    share = @account.account_shares.find_or_initialize_by(user: member)
    %w[read_only read_write].each do |permission|
      share.update!(permission: permission)
      assert_equal({}, @gift_card.visible_codes_for(member), permission)
      assert_nil @gift_card.visible_redeem_url_for(member), permission
    end

    share.update!(permission: "full_control")
    assert @gift_card.credentials_visible_to?(member)

    share.destroy!
    assert_not @gift_card.credentials_visible_to?(member)
  end
end
