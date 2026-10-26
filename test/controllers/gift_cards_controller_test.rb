require "test_helper"

class GiftCardsControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    enable_preview_features!
    @account = @user.family.accounts.create_and_sync(
      {
        name: "Bookstore gift card",
        balance: 50,
        currency: "USD",
        owner: @user,
        accountable_type: "GiftCard",
        accountable_attributes: { card_format: "physical" }
      },
      skip_initial_sync: true
    )
  end

  test "creates with gift card details" do
    assert_difference -> { Account.count } => 1,
      -> { GiftCard.count } => 1,
      -> { Valuation.count } => 1 do
      post gift_cards_path, params: {
        account: {
          name: "Cinema voucher",
          balance: 25,
          currency: "EUR",
          opening_balance_date: "2026-10-01",
          accountable_type: "GiftCard",
          accountable_attributes: {
            card_format: "digital",
            expires_on: "2027-10-01",
            card_number: "CODE-1234",
            pin: "4321",
            redeem_url: "https://cinema.example/redeem"
          }
        }
      }
    end

    created_account = Account.find_by!(name: "Cinema voucher")
    gift_card = created_account.accountable

    assert_equal 25, created_account.balance
    assert_equal "EUR", created_account.currency
    assert_equal "digital", gift_card.card_format
    assert_equal Date.new(2027, 10, 1), gift_card.expires_on
    assert_equal "CODE-1234", gift_card.card_number
    assert_equal "4321", gift_card.pin
    assert_equal "https://cinema.example/redeem", gift_card.redeem_url
    assert_equal 25, gift_card.face_value
    assert_equal "EUR", gift_card.face_value_currency
    # Anchored the evening before the card was received.
    assert_equal Date.new(2026, 9, 30), created_account.entries.valuations.first.date

    assert_redirected_to created_account
    assert_enqueued_with(job: SyncJob)
  end

  test "spending on the day a card was received lowers its balance" do
    post gift_cards_path, params: {
      account: {
        name: "Birthday card",
        balance: 50,
        currency: "USD",
        opening_balance_date: Date.current.to_s,
        accountable_type: "GiftCard",
        accountable_attributes: { card_format: "physical" }
      }
    }

    account = Account.find_by!(name: "Birthday card")
    spend(account, 10)

    assert_equal 40, balance_today(account)
  end

  test "a partly spent card keeps its initial amount and takes new spending" do
    post gift_cards_path, params: {
      account: {
        name: "Half used card",
        balance: 30,
        currency: "USD",
        opening_balance_date: Date.current.to_s,
        accountable_type: "GiftCard",
        accountable_attributes: { card_format: "physical", face_value: 100 }
      }
    }

    account = Account.find_by!(name: "Half used card")
    assert_equal 30, account.balance
    assert_equal Money.new(100, "USD"), account.gift_card.initial_amount
    assert_equal Money.new(70, "USD"), account.gift_card.spent_amount

    # The entered balance is the opening anchor, with no reconciliation today
    # that would override what is spent next.
    assert_equal 1, account.entries.valuations.count
    spend(account, 10)
    assert_equal 20, balance_today(account)
  end

  test "creates without any gift card fields" do
    assert_difference "GiftCard.count", 1 do
      post gift_cards_path, params: {
        account: { name: "Plain card", balance: 15, currency: "USD", opening_balance_date: Date.current.to_s }
      }
    end

    assert_equal 15, Account.find_by!(name: "Plain card").gift_card.face_value
  end

  test "a rejected form keeps the received date" do
    post gift_cards_path, params: {
      account: {
        name: "Bad link",
        balance: 10,
        currency: "USD",
        opening_balance_date: "2026-08-15",
        accountable_attributes: { card_format: "digital", redeem_url: "javascript:alert(1)" }
      }
    }

    assert_response :unprocessable_entity
    assert_select "input[name='account[opening_balance_date]'][value='2026-08-15']"
  end

  test "another account form cannot create a gift card" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    assert_no_difference "GiftCard.count" do
      post other_assets_path, params: {
        account: { name: "Sneaky card", balance: 10, currency: "USD", accountable_type: "GiftCard" }
      }
    end

    assert_equal "OtherAsset", Account.find_by!(name: "Sneaky card").accountable_type
  end

  test "credentials are filtered from request logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(account: {
      accountable_attributes: { card_number: "CODE-1234", pin: "4321", redeem_url: "https://x.example/?t=1" }
    })

    %i[card_number pin redeem_url].each do |attribute|
      assert_equal "[FILTERED]", filtered[:account][:accountable_attributes][attribute], attribute
    end
  end

  test "updates gift card details" do
    assert_no_difference [ "Account.count", "GiftCard.count" ] do
      patch gift_card_path(@account), params: {
        account: {
          name: "Updated gift card",
          balance: 30,
          accountable_type: "GiftCard",
          accountable_attributes: {
            id: @account.accountable_id,
            card_format: "digital",
            expires_on: "2027-01-31"
          }
        }
      }
    end

    @account.reload
    assert_equal "Updated gift card", @account.name
    assert_equal 30, @account.balance
    assert_equal "digital", @account.gift_card.card_format
    assert_equal Date.new(2027, 1, 31), @account.gift_card.expires_on
    assert_redirected_to account_path(@account)
  end

  test "a known initial amount cannot be cleared" do
    @account.gift_card.update!(face_value: 50)

    patch gift_card_path(@account), params: {
      account: { accountable_attributes: { id: @account.accountable_id, face_value: "" } }
    }

    assert_response :unprocessable_entity
    assert_equal 50, @account.gift_card.reload.face_value
  end

  test "rejects a redeem link that is not a web address" do
    assert_no_difference "Account.count" do
      post gift_cards_path, params: {
        account: {
          name: "Bad link",
          balance: 10,
          currency: "USD",
          accountable_type: "GiftCard",
          accountable_attributes: { card_format: "digital", redeem_url: "javascript:alert(1)" }
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "shows the overview with the card details" do
    @account.gift_card.update!(expires_on: Date.current + 5.days, card_number: "SHOW-ME")

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_select "code", text: "SHOW-ME"
  end

  test "after a currency change the overview leaves spending unknown" do
    @account.gift_card.update!(face_value: 50, face_value_currency: "USD")
    @account.update!(currency: "EUR")

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_match "$50.00", response.body
    assert_match I18n.t("gift_cards.tabs.overview.unknown"), response.body
  end

  test "shares that cannot act on the card see the balance but not its credentials" do
    @account.gift_card.update!(card_number: "SECRET-CODE", pin: "PIN-SECRET", redeem_url: "https://shop.example/r/URL-SECRET")
    member = users(:family_member)
    share = @account.account_shares.find_or_initialize_by(user: member)
    sign_in member

    %w[read_only read_write].each do |permission|
      share.update!(permission: permission)
      get account_path(@account, tab: "overview")

      assert_response :success
      %w[SECRET-CODE PIN-SECRET URL-SECRET].each { |secret| assert_no_match secret, response.body, permission }
    end
  end

  test "the appearance settings offer gift cards only with preview features" do
    @account.destroy!
    get settings_appearance_path
    assert_select "#user_account_groups_gift_card"

    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
    get settings_appearance_path
    assert_select "#user_account_groups_gift_card", count: 0
  end

  test "the appearance settings keep the gift card group of an existing card" do
    @user.update!(preferences: @user.preferences.merge(
      "preview_features_enabled" => false, "always_expanded_account_groups" => [ "gift_card" ]
    ))

    get settings_appearance_path
    assert_select "#user_account_groups_gift_card[checked]"
  end

  test "the appearance settings show a held gift card group only to users who can access the card" do
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => false))
    @account.account_shares.where(user: member).destroy_all
    sign_in member

    get settings_appearance_path
    assert_select "#user_account_groups_gift_card", count: 0

    @account.account_shares.create!(user: member, permission: "read_only")
    get settings_appearance_path
    assert_select "#user_account_groups_gift_card"
  end

  test "saving the appearance settings keeps the selection of a group the form did not show" do
    @account.destroy!
    @user.update!(preferences: @user.preferences.merge(
      "preview_features_enabled" => false, "always_expanded_account_groups" => [ "gift_card" ]
    ))

    patch settings_appearance_path, params: { user: { account_groups: [ "", "depository" ] } }

    assert_equal %w[depository gift_card], @user.reload.always_expanded_account_groups.sort
  end

  test "the initial amount is not rounded to the rendered currency's precision" do
    get new_gift_card_path
    assert_select "input[name='account[accountable_attributes][face_value]'][step='any']"
  end

  test "saving the edit form again keeps the initial amount" do
    @account.gift_card.update!(face_value: 100.1234, face_value_currency: "USD")
    assert_equal 100.12, @account.gift_card.reload.face_value

    get edit_gift_card_path(@account)
    assert_select "input[name='account[accountable_attributes][face_value]'][value='100.12']"
  end

  test "the form warns when credentials will be stored unencrypted" do
    GiftCard.stubs(:encryption_ready?).returns(false)
    get edit_gift_card_path(@account)
    assert_includes response.body, I18n.t("gift_cards.form.unencrypted_credentials")

    GiftCard.stubs(:encryption_ready?).returns(true)
    get edit_gift_card_path(@account)
    assert_not_includes response.body, I18n.t("gift_cards.form.unencrypted_credentials")
  end

  test "creating a gift card requires preview features" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    get new_gift_card_path
    assert_redirected_to root_path

    assert_no_difference "Account.count" do
      post gift_cards_path, params: {
        account: { name: "Gift card", balance: 10, currency: "USD", accountable_type: "GiftCard" }
      }
    end
    assert_redirected_to root_path
  end

  test "an existing gift card stays editable without preview features" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    get edit_gift_card_path(@account)
    assert_response :success
  end

  private
    def spend(account, amount)
      account.entries.create!(
        name: "Books", date: Date.current, currency: account.currency, amount: amount, entryable: Transaction.new
      )
    end

    def balance_today(account)
      Balance::ForwardCalculator.new(account).calculate.find { |balance| balance.date == Date.current }.balance
    end

    def enable_preview_features!
      @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    end
end
