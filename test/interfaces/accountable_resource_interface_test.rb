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
end
