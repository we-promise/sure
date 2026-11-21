require "test_helper"

module AccountableResourceInterfaceTest
  extend ActiveSupport::Testing::Declarative

  test "shows new form" do
    Family.any_instance.stubs(:get_link_token).returns("test-link-token")

    get new_polymorphic_url(@account.accountable)
    assert_response :success
  end

  test "shows edit form" do
    get edit_account_url(@account)
    assert_response :success
  end

  test "update saves currency change" do
    @account.update!(currency: "USD")

    patch send("#{@account.accountable_type.underscore}_path", @account), params: {
      account: {
        name: @account.name,
        currency: "EUR"
      }
    }

    @account.reload
    assert_equal "EUR", @account.currency
  end
  test "create ignores a submitted account type" do
    forged_type = forged_accountable_type

    assert_no_difference -> { Account.where(accountable_type: forged_type).count } do
      post send("#{@account.accountable_type.underscore.pluralize}_path"), params: {
        account: {
          name: "Forged type",
          balance: 10,
          currency: "USD",
          accountable_type: forged_type,
          # Some forms only build the accountable from its nested fields.
          accountable_attributes: { id: "" }
        }
      }
    end

    assert_equal @account.accountable_type, Account.find_by!(name: "Forged type").accountable_type
  end

  test "update ignores a submitted account type" do
    original_type = @account.accountable_type

    patch send("#{@account.accountable_type.underscore}_path", @account), params: {
      account: { name: "Renamed account", accountable_type: forged_accountable_type }
    }

    @account.reload
    assert_equal "Renamed account", @account.name
    assert_equal original_type, @account.accountable_type
  end

  private
    # Gift cards are the type a gate protects; any other type proves the point
    # for the gift card controller itself.
    def forged_accountable_type
      @account.accountable_type == "GiftCard" ? "OtherAsset" : "GiftCard"
    end
end
