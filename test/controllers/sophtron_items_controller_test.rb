require "test_helper"

class SophtronItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @item = @user.family.sophtron_items.create!(
      name: "Sophtron",
      user_id: "developer-user",
      access_key: Base64.strict_encode64("secret-key"),
      customer_id: "cust-1"
    )
  end

  test "select_accounts renders institution connection flow when no institution is connected" do
    SophtronItem.any_instance.stubs(:ensure_customer!).returns("cust-1")

    get select_accounts_sophtron_items_url

    assert_response :success
    assert_includes response.body, "Connect Sophtron Institution"
  end

  test "member cannot access Sophtron account selection" do
    sign_in users(:family_member)

    get select_accounts_sophtron_items_url

    assert_redirected_to accounts_path
  end

  test "cannot access another family's Sophtron item" do
    other_item = families(:empty).sophtron_items.create!(
      name: "Other Sophtron",
      user_id: "other-developer-user",
      access_key: Base64.strict_encode64("other-secret")
    )

    get connection_status_sophtron_item_url(other_item)

    assert_response :not_found
  end

  test "connect_institution persists job and user institution ids" do
    provider = mock
    provider.expects(:create_user_institution).with(
      institution_id: "inst-1",
      username: "bank-user",
      password: "bank-pass",
      pin: ""
    ).returns({
      JobID: "job-1",
      UserInstitutionID: "ui-1"
    })

    SophtronItem.any_instance.stubs(:ensure_customer!).returns("cust-1")
    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)

    post connect_institution_sophtron_items_url, params: {
      institution_id: "inst-1",
      institution_name: "Example Bank",
      bank_username: "bank-user",
      bank_password: "bank-pass"
    }

    @item.reload
    assert_equal "job-1", @item.current_job_id
    assert_equal "ui-1", @item.user_institution_id
    assert_redirected_to connection_status_sophtron_item_path(@item)
  end

  test "create verifies credentials and persists provisioned customer id" do
    stub_request(:get, "https://api.sophtron.com/api/Institution/HealthCheckAuth")
      .to_return(status: 200, body: "")
    stub_request(:get, "https://api.sophtron.com/api/v2/customers")
      .to_return(status: 200, body: [].to_json)
    stub_request(:post, "https://api.sophtron.com/api/v2/customers")
      .to_return(status: 200, body: {
        CustomerID: "cust-new",
        CustomerName: "Sure family #{@user.family.id}"
      }.to_json)

    assert_difference "SophtronItem.count", 1 do
      post sophtron_items_url, params: {
        sophtron_item: {
          name: "New Sophtron",
          user_id: "developer-user",
          access_key: Base64.strict_encode64("secret-key")
        }
      }
    end

    item = @user.family.sophtron_items.find_by!(name: "New Sophtron")
    assert_equal "cust-new", item.customer_id
    assert_redirected_to accounts_path
  end

  test "connection_status renders MFA challenge when Sophtron asks for security answers" do
    @item.update!(user_institution_id: "ui-1", current_job_id: "job-1")
    provider = mock
    provider.expects(:get_job_information).with("job-1").returns({
      SecurityQuestion: [ "What is your favorite color?" ].to_json,
      SuccessFlag: nil,
      LastStatus: "Waiting"
    })

    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)

    get connection_status_sophtron_item_url(@item)

    assert_response :success
    assert_includes response.body, "What is your favorite color?"
  end

  test "connection_status times out after max UI polls" do
    @item.update!(user_institution_id: "ui-1", current_job_id: "job-1")

    get connection_status_sophtron_item_url(@item, poll_attempt: SophtronItemsController::CONNECTION_STATUS_MAX_POLLS)

    assert_response :success
    assert_includes response.body, "Sophtron did not finish connecting"
    assert_equal "requires_update", @item.reload.status
    assert_equal "job-1", @item.current_job_id
  end

  test "connection_status increments polling attempt while job is still running" do
    @item.update!(user_institution_id: "ui-1", current_job_id: "job-1")
    provider = mock
    provider.expects(:get_job_information).with("job-1").returns({
      AccountID: "00000000-0000-0000-0000-000000000000",
      JobType: "AddAccounts",
      JobID: "job-1"
    })

    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)

    get connection_status_sophtron_item_url(@item, poll_attempt: 3)

    assert_response :success
    assert_includes response.body, "poll_attempt=4"
  end

  test "submit_mfa sends security answer as array string" do
    @item.update!(user_institution_id: "ui-1", current_job_id: "job-1")
    provider = mock
    provider.expects(:update_job_security_answer).with("job-1", [ "blue" ]).returns({})

    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)

    post submit_mfa_sophtron_item_url(@item), params: {
      mfa_type: "security_answer",
      security_answers: [ "blue" ]
    }

    assert_redirected_to connection_status_sophtron_item_path(@item)
  end

  test "link_existing_account links manual account to sophtron account" do
    @item.update!(user_institution_id: "ui-1")
    account = accounts(:depository)
    provider = mock
    provider.expects(:get_accounts).with("ui-1").returns({
      accounts: [
        {
          id: "acct-1",
          account_id: "acct-1",
          account_name: "Sophtron Checking",
          balance: "123.45",
          balance_currency: "USD",
          currency: "USD",
          account_type: "checking"
        }.with_indifferent_access
      ],
      total: 1
    })

    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)
    SophtronItem.any_instance.stubs(:sync_later)

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_sophtron_items_url, params: {
        account_id: account.id,
        sophtron_account_id: "acct-1"
      }
    end

    assert account.reload.linked?
    assert_equal "SophtronAccount", account.account_providers.first.provider_type
    assert_redirected_to accounts_path
  end
end
