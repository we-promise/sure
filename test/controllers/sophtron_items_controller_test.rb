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

  test "select_accounts renders institution search after failed connection attempt" do
    @item.update!(user_institution_id: "ui-1", status: :requires_update)
    SophtronItem.any_instance.stubs(:ensure_customer!).returns("cust-1")

    get select_accounts_sophtron_items_url

    assert_response :success
    assert_includes response.body, "Connect Sophtron Institution"
  end

  test "select_accounts renders institution search after stale Sophtron timeout" do
    @item.update!(
      user_institution_id: "ui-1",
      status: :good,
      job_status: "Timeout",
      raw_job_payload: {
        AccountID: "00000000-0000-0000-0000-000000000000",
        JobType: "AddAccounts",
        JobID: "job-1",
        SuccessFlag: false,
        LastStep: "LogInPanel",
        LastStatus: "Timeout"
      }
    )
    SophtronItem.any_instance.stubs(:ensure_customer!).returns("cust-1")

    get select_accounts_sophtron_items_url

    assert_response :success
    assert_includes response.body, "Connect Sophtron Institution"
  end

  test "select_accounts can start a new institution connection when already connected" do
    @item.update!(user_institution_id: "ui-1", status: :good)
    SophtronItem.any_instance.stubs(:ensure_customer!).returns("cust-1")

    get select_accounts_sophtron_items_url(connect_new_institution: true)

    assert_response :success
    assert_includes response.body, "Connect Sophtron Institution"
    assert_includes response.body, 'name="connect_new_institution"'
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

    post connect_institution_sophtron_item_url(@item), params: {
      institution_id: "inst-1",
      institution_name: "Example Bank",
      bank_username: "bank-user",
      bank_password: "bank-pass"
    }

    @item.reload
    assert_equal "Sophtron", @item.name
    assert_equal "Example Bank", @item.institution_name
    assert_equal "job-1", @item.current_job_id
    assert_equal "ui-1", @item.user_institution_id
    assert_redirected_to connection_status_sophtron_item_path(@item)
  end

  test "connect_institution creates separate item for additional institution" do
    @item.update!(
      institution_id: "apple-inst",
      institution_name: "Apple / Goldman Sachs",
      user_institution_id: "ui-apple",
      status: :good
    )
    @item.sophtron_accounts.create!(
      name: "Juan",
      account_id: "card-1",
      currency: "USD",
      balance: 1_947.18,
      institution_metadata: {
        name: "Apple / Goldman Sachs",
        user_institution_id: "ui-apple"
      }
    )

    provider = mock
    provider.expects(:create_user_institution).with(
      institution_id: "amazon-inst",
      username: "bank-user",
      password: "bank-pass",
      pin: ""
    ).returns({
      JobID: "job-amazon",
      UserInstitutionID: "ui-amazon"
    })

    SophtronItem.any_instance.stubs(:ensure_customer!).returns("cust-1")
    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)

    assert_difference -> { @user.family.sophtron_items.count }, 1 do
      post connect_institution_sophtron_item_url(@item), params: {
        institution_id: "amazon-inst",
        institution_name: "Amazon",
        bank_username: "bank-user",
        bank_password: "bank-pass",
        connect_new_institution: true
      }
    end

    @item.reload
    new_item = @user.family.sophtron_items.find_by!(user_institution_id: "ui-amazon")

    assert_equal "Apple / Goldman Sachs", @item.institution_name
    assert_equal "ui-apple", @item.user_institution_id
    assert_equal "Amazon", new_item.institution_name
    assert_equal "ui-amazon", new_item.user_institution_id
    assert_equal "job-amazon", new_item.current_job_id
    assert_redirected_to connection_status_sophtron_item_path(new_item, connect_new_institution: "true")
  end

  test "Sophtron bank credentials and mfa inputs are filtered from logs" do
    parameter_filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered_params = parameter_filter.filter(
      bank_username: "bank-user",
      bank_password: "bank-pass",
      security_answers: [ "blue" ],
      captcha_input: "captcha"
    )

    assert_equal "[FILTERED]", filtered_params[:bank_username]
    assert_equal "[FILTERED]", filtered_params[:bank_password]
    assert_equal "[FILTERED]", filtered_params[:security_answers]
    assert_equal "[FILTERED]", filtered_params[:captcha_input]
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

  test "connection_status sanitizes captcha image before rendering data uri" do
    @item.update!(user_institution_id: "ui-1", current_job_id: "job-1")
    provider = mock
    provider.expects(:get_job_information).with("job-1").returns({
      CaptchaImage: "YWJj+/=\"><svg onload=alert(1)>",
      LastStatus: "Waiting"
    })

    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)

    get connection_status_sophtron_item_url(@item)

    assert_response :success
    captcha_src = response.body[/src="data:image\/png;base64,([^"]+)"/, 1]
    assert_equal "YWJj+/=", captcha_src
    assert_no_match(/svg|onload|alert|[<>"\s]/i, captcha_src)
  end

  test "connection_status renders token challenge before failed timeout handling" do
    @item.update!(user_institution_id: "ui-1", current_job_id: "job-1")
    provider = mock
    provider.expects(:get_job_information).with("job-1").returns({
      AccountID: "00000000-0000-0000-0000-000000000000",
      JobType: "AddAccounts",
      JobID: "job-1",
      SuccessFlag: false,
      TokenSentFlag: true,
      TokenInputName: "Token",
      LastStep: "TokenInput",
      LastStatus: "Timeout"
    })

    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)

    get connection_status_sophtron_item_url(@item)

    assert_response :success
    assert_includes response.body, "Verification code"
    assert_not_includes response.body, "Sophtron could not complete this connection."
  end

  test "connection_status times out after max UI polls" do
    @item.update!(user_institution_id: "ui-1", current_job_id: "job-1")
    provider = mock
    provider.expects(:get_job_information).with("job-1").returns({
      AccountID: "00000000-0000-0000-0000-000000000000",
      JobType: "AddAccounts",
      JobID: "job-1"
    })

    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)

    get connection_status_sophtron_item_url(@item, poll_attempt: SophtronItemsController::CONNECTION_STATUS_MAX_POLLS)

    assert_response :success
    assert_includes response.body, "Sophtron did not finish connecting"
    assert_includes response.body, "Attempt #{SophtronItemsController::CONNECTION_STATUS_MAX_POLLS} of #{SophtronItemsController::CONNECTION_STATUS_MAX_POLLS}"
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

    get connection_status_sophtron_item_url(@item, poll_attempt: 2)

    assert_response :success
    assert_includes response.body, "Attempt 2 of #{SophtronItemsController::CONNECTION_STATUS_MAX_POLLS}"
    assert_includes response.body, "poll_attempt=3"
    assert_includes response.body, 'data-controller="polling"'
    assert_includes response.body, 'data-polling-frame-id-value="modal"'
    assert_includes response.body, 'data-turbo-prefetch="false"'
    assert_select "a[href*='poll_attempt=3']"
  end

  test "connection_status keeps polling through the third initial attempt for delayed otp" do
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
    assert_includes response.body, "Attempt 3 of #{SophtronItemsController::CONNECTION_STATUS_MAX_POLLS}"
    assert_includes response.body, "poll_attempt=4"
    assert_not_includes response.body, "Sophtron did not finish connecting"
    assert_not_equal "requires_update", @item.reload.status
  end

  test "connection_status extends polling when Sophtron starts institution login before otp" do
    @item.update!(user_institution_id: "ui-1", current_job_id: "job-1")
    provider = mock
    provider.expects(:get_job_information).with("job-1").returns({
      AccountID: "00000000-0000-0000-0000-000000000000",
      JobType: "AddAccounts",
      JobID: "job-1",
      LastStep: "LogInPanel",
      LastStatus: "Started"
    })

    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)

    get connection_status_sophtron_item_url(@item, poll_attempt: SophtronItemsController::CONNECTION_STATUS_MAX_POLLS)

    assert_response :success
    assert_includes response.body, "Attempt #{SophtronItemsController::CONNECTION_STATUS_MAX_POLLS} of #{SophtronItemsController::LOGIN_PROGRESS_CONNECTION_STATUS_MAX_POLLS}"
    assert_includes response.body, "poll_attempt=#{SophtronItemsController::CONNECTION_STATUS_MAX_POLLS + 1}"
    assert_not_includes response.body, "Sophtron did not finish connecting"
    assert_not_equal "requires_update", @item.reload.status
  end

  test "connection_status keeps polling after initial max when login progress was already seen" do
    @item.update!(
      user_institution_id: "ui-1",
      current_job_id: "job-1",
      raw_job_payload: {
        AccountID: "00000000-0000-0000-0000-000000000000",
        JobType: "AddAccounts",
        JobID: "job-1",
        LastStep: "LogInPanel",
        LastStatus: "Started"
      }
    )
    provider = mock
    provider.expects(:get_job_information).with("job-1").returns({
      AccountID: "00000000-0000-0000-0000-000000000000",
      JobType: "AddAccounts",
      JobID: "job-1",
      LastStep: "LogInPanel",
      LastStatus: "Started"
    })

    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)

    get connection_status_sophtron_item_url(@item, poll_attempt: SophtronItemsController::CONNECTION_STATUS_MAX_POLLS + 1)

    assert_response :success
    assert_includes response.body, "Attempt #{SophtronItemsController::CONNECTION_STATUS_MAX_POLLS + 1} of #{SophtronItemsController::LOGIN_PROGRESS_CONNECTION_STATUS_MAX_POLLS}"
    assert_includes response.body, "poll_attempt=#{SophtronItemsController::CONNECTION_STATUS_MAX_POLLS + 2}"
    assert_not_includes response.body, "Sophtron did not finish connecting"
    assert_not_equal "requires_update", @item.reload.status
  end

  test "connection_status uses longer polling after mfa is submitted" do
    @item.update!(user_institution_id: "ui-1", current_job_id: "job-1")
    provider = mock
    provider.expects(:get_job_information).with("job-1").returns({
      AccountID: "00000000-0000-0000-0000-000000000000",
      JobType: "AddAccounts",
      JobID: "job-1",
      TokenInput: "123456",
      LastStep: "TransactionTable",
      LastStatus: "Started"
    })

    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)

    get connection_status_sophtron_item_url(@item, poll_attempt: SophtronItemsController::CONNECTION_STATUS_MAX_POLLS, post_mfa: true)

    assert_response :success
    assert_includes response.body, "Attempt #{SophtronItemsController::CONNECTION_STATUS_MAX_POLLS} of 15"
    assert_includes response.body, "poll_attempt=#{SophtronItemsController::CONNECTION_STATUS_MAX_POLLS + 1}"
    assert_not_includes response.body, "Sophtron did not finish connecting"
  end

  test "connection_status renders accounts when post mfa completed job has available accounts" do
    @item.update!(user_institution_id: "ui-1", current_job_id: "job-1")
    provider = mock
    provider.expects(:get_job_information).with("job-1").returns({
      AccountID: "00000000-0000-0000-0000-000000000000",
      JobType: "AddAccounts",
      JobID: "job-1",
      TokenInput: "123456",
      LastStep: "TokenInput",
      LastStatus: "Completed"
    })
    provider.expects(:get_accounts).with("ui-1").returns({
      accounts: [
        {
          id: "acct-1",
          account_id: "acct-1",
          account_name: "Sophtron Checking",
          institution_name: "Example Bank",
          balance: "123.45",
          balance_currency: "USD",
          currency: "USD",
          status: "active"
        }.with_indifferent_access
      ],
      total: 1
    })

    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)

    get connection_status_sophtron_item_url(@item, poll_attempt: 5, post_mfa: true)

    assert_response :success
    assert_includes response.body, "Sophtron Checking"
    assert_not_includes response.body, "poll_attempt=6"

    @item.reload
    assert_nil @item.current_job_id
    assert_equal "good", @item.status
    assert @item.pending_account_setup?
  end

  test "connection_status keeps polling when post mfa completed job has no accounts yet" do
    @item.update!(user_institution_id: "ui-1", current_job_id: "job-1")
    provider = mock
    provider.expects(:get_job_information).with("job-1").returns({
      AccountID: "00000000-0000-0000-0000-000000000000",
      JobType: "AddAccounts",
      JobID: "job-1",
      TokenInput: "123456",
      LastStep: "Reset",
      LastStatus: "Completed"
    })
    provider.expects(:get_accounts).with("ui-1").returns({ accounts: [], total: 0 })

    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)

    get connection_status_sophtron_item_url(@item, poll_attempt: 6, post_mfa: true)

    assert_response :success
    assert_includes response.body, "Attempt 6 of #{SophtronItemsController::POST_MFA_CONNECTION_STATUS_MAX_POLLS}"
    assert_includes response.body, "poll_attempt=7"
    assert_not_includes response.body, "Sophtron did not finish connecting"
    assert_equal "job-1", @item.reload.current_job_id
  end

  test "connection_status ignores browser prefetches" do
    @item.update!(user_institution_id: "ui-1", current_job_id: "job-1")
    SophtronItem.any_instance.expects(:sophtron_provider).never

    get connection_status_sophtron_item_url(@item, poll_attempt: 2), headers: { "X-Sec-Purpose" => "prefetch" }

    assert_response :no_content
    assert_nil @item.reload.job_status
  end

  test "connection_status treats Sophtron timeout as failed" do
    @item.update!(user_institution_id: "ui-1", current_job_id: "job-1")
    provider = mock
    provider.expects(:get_job_information).with("job-1").returns({
      AccountID: "00000000-0000-0000-0000-000000000000",
      JobType: "AddAccounts",
      JobID: "job-1",
      SuccessFlag: false,
      LastStep: "LogInPanel",
      LastStatus: "Timeout"
    })

    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)

    get connection_status_sophtron_item_url(@item)

    assert_response :success
    assert_includes response.body, "Sophtron timed out while the institution was completing login."
    assert_includes response.body, "Unable to connect to the institution"
    assert_includes response.body, "Bank credentials"
    assert_includes response.body, "Verification code"
    assert_includes response.body, "Try connecting again"
    assert_not_includes response.body, "Check Provider Settings"
    @item.reload
    assert_equal "requires_update", @item.status
    assert_nil @item.current_job_id
    assert_nil @item.user_institution_id
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

    assert_redirected_to connection_status_sophtron_item_path(@item, post_mfa: true)
  end

  test "submit_mfa rejects too many security answers" do
    @item.update!(user_institution_id: "ui-1", current_job_id: "job-1")
    provider = mock
    provider.expects(:update_job_security_answer).never

    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)

    post submit_mfa_sophtron_item_url(@item), params: {
      mfa_type: "security_answer",
      security_answers: Array.new(SophtronItemsController::MAX_SECURITY_ANSWERS + 1, "blue")
    }

    assert_redirected_to connection_status_sophtron_item_path(@item)
    assert_equal "Security answers are missing or too long.", flash[:alert]
  end

  test "submit_mfa rejects oversized security answers" do
    @item.update!(user_institution_id: "ui-1", current_job_id: "job-1")
    provider = mock
    provider.expects(:update_job_security_answer).never

    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)

    post submit_mfa_sophtron_item_url(@item), params: {
      mfa_type: "security_answer",
      security_answers: [ "a" * (SophtronItemsController::MAX_SECURITY_ANSWER_LENGTH + 1) ]
    }

    assert_redirected_to connection_status_sophtron_item_path(@item)
    assert_equal "Security answers are missing or too long.", flash[:alert]
  end

  test "submit_mfa redirects to post mfa polling window" do
    @item.update!(user_institution_id: "ui-1", current_job_id: "job-1")
    provider = mock
    provider.expects(:update_job_token_input).with("job-1", token_input: "123456").returns({})

    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)

    post submit_mfa_sophtron_item_url(@item), params: {
      mfa_type: "token_input",
      token_input: "123456"
    }

    assert_redirected_to connection_status_sophtron_item_path(@item, post_mfa: true)
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
    SophtronItem.any_instance.stubs(:start_initial_load_later)

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
