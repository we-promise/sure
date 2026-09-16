require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class ProviderConnections::AccountSetupsControllerTest < ActionDispatch::IntegrationTest
  include ProviderIngestionTestHelper

  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    DebugLogEntry.stubs(:capture)
    Provider::AccountData::Up.stubs(:native_ready?).returns(true)
  end

  test "catalog chooses an exact existing target before requesting its signed confirmation" do
    with_connection do |connection|
      external = create_external_account(connection, name: "Discovered checking", current_balance: "987654.32")
      account = accounts(:checking)
      cursor = SecureRandom.uuid
      setup_for(connection).expects(:catalog).with(after: nil).returns(catalog(connection, external_accounts: [ external ],
        existing_accounts: [ account ], next_cursor: cursor))

      get provider_connection_account_setup_path(connection)

      assert_response :success
      assert_select "a[href=?]", provider_connection_account_setup_path(connection, external_account_id: external.id)
      assert_select "form[action=?][method='get']", provider_connection_account_setup_path(connection) do
        assert_select "input[name='external_account_id'][value=?]", external.id
        assert_select "select[name='account_id'][required]" do
          assert_select "option[value=?]", account.id, text: account.name
        end
        assert_select "input[name='account_setup[token]']", count: 0
      end
      assert_select "a[href=?]", provider_connection_account_setup_path(connection, after: cursor)
      assert_not_includes response.body, "private-provider-token"
      assert_not_includes response.body, "987654.32"
    end
  end

  test "catalog pagination passes its original scalar cursor" do
    with_connection do |connection|
      cursor = SecureRandom.uuid
      setup_for(connection).expects(:catalog).with(after: cursor).returns(catalog(connection))

      get provider_connection_account_setup_path(connection, after: cursor)

      assert_response :success
      assert_select "p", text: I18n.t("provider_connections.account_setup.empty_title")
      assert_select "form[action=?]", refresh_provider_connection_account_setup_path(connection)
      assert_select "input[name='account_setup[token]']", count: 0
    end
  end

  test "new confirmation renders allowed types and a blank explicit balance" do
    with_connection do |connection|
      external = create_external_account(connection, name: "Discovered card", current_balance: "-54321.98")
      setup_for(connection).expects(:form).with(external_account_id: external.id, account_id: nil)
        .returns(selection(connection, external, account_types: [ "Depository", "CreditCard" ]))

      get provider_connection_account_setup_path(connection, external_account_id: external.id)

      assert_response :success
      assert_select "form[action=?][method='post']", provider_connection_account_setup_path(connection) do
        assert_select "input[name='account_setup[token]'][value='signed-original-selection']"
        assert_select "input[name='account_setup[name]'][value=?]", external.name
        assert_select "input[name='account_setup[currency]'][value='USD']"
        assert_select "input[name='account_setup[balance]'][value=''][required]"
        assert_select "select[name='account_setup[accountable_type]'][required]" do
          assert_select "option[value='Depository']", text: I18n.t("accounts.types.depository")
          assert_select "option[value='CreditCard']", text: I18n.t("accounts.types.credit_card")
          assert_select "option[value='Property']", count: 0
        end
        assert_select "input[name='account_setup[account_id]']", count: 0
        assert_select "input[name='account_setup[external_account_id]']", count: 0
      end
      assert_not_includes response.body, "-54321.98"
      assert_not_includes response.body, "private-provider-token"
    end
  end

  test "existing confirmation posts only its token and explains preserved source choices" do
    with_connection do |connection|
      external = create_external_account(connection)
      account = accounts(:checking)
      setup_for(connection).expects(:form).with(external_account_id: external.id, account_id: account.id)
        .returns(selection(connection, external, account: account, secondary: true))

      get provider_connection_account_setup_path(connection, external_account_id: external.id, account_id: account.id)

      assert_response :success
      assert_includes response.body, I18n.t("provider_connections.account_setup.secondary")
      assert_select "form[action=?][method='post']", provider_connection_account_setup_path(connection) do |forms|
        names = forms.first.css("input[name], select[name], textarea[name]").map { |field| field["name"] }
        assert_equal [ "account_setup[token]" ], names.reject { |name| name == "authenticity_token" }
      end
    end
  end

  test "create passes the signed selection and only explicit new-account attributes" do
    with_connection do |connection|
      setup_for(connection).expects(:apply!).with(token: "signed-original-selection", attributes: {
        "name" => "Personal checking", "accountable_type" => "Depository", "currency" => "USD", "balance" => "123.45"
      })

      post provider_connection_account_setup_path(connection), params: { account_setup: {
        token: "signed-original-selection", name: "Personal checking", accountable_type: "Depository", currency: "USD", balance: "123.45",
        account_id: accounts(:checking).id, external_account_id: SecureRandom.uuid, family_id: families(:empty).id,
        owner_id: users(:family_member).id, provider_key: "brex", mode: "existing", source_policy: "replace",
        credentials: { token: "untrusted-secret" }
      } }

      assert_redirected_to provider_connection_account_setup_path(connection)
      assert_equal 303, response.status
      assert_equal I18n.t("provider_connections.account_setup.success"), flash[:notice]
      assert_not_includes response.body, "untrusted-secret"
    end
  end

  test "existing confirmation does not invent new account attributes" do
    with_connection do |connection|
      setup_for(connection).expects(:apply!).with(token: "signed-existing-selection", attributes: {})

      post provider_connection_account_setup_path(connection), params: { account_setup: { token: "signed-existing-selection" } }

      assert_redirected_to provider_connection_account_setup_path(connection)
    end
  end

  test "refresh delegates one explicit discovery request without accepting credentials" do
    with_connection do |connection|
      setup_for(connection).expects(:refresh!).once

      post refresh_provider_connection_account_setup_path(connection), params: { credentials: { token: "untrusted-secret" }, legacy_item_id: SecureRandom.uuid }

      assert_redirected_to provider_connection_account_setup_path(connection)
      assert_equal 303, response.status
      assert_equal I18n.t("provider_connections.account_setup.refresh_success"), flash[:notice]
      assert_not_includes response.body, "untrusted-secret"
    end
  end

  {
    conflict: ProviderConnection::AccountSetup::Conflict,
    busy: ProviderConnection::AccountSetup::Busy,
    invalid: ArgumentError,
    unsupported: Provider::AccountData::UnsupportedCapability
  }.each do |kind, error_class|
    test "#{kind} refusal does not expose signed selections values or error details" do
      with_connection do |connection|
        setup_for(connection).expects(:apply!).raises(error_class, "private-error-detail")
        DebugLogEntry.expects(:capture).with do |**values|
          assert_equal connection.id, values.fetch(:metadata).fetch(:provider_connection_id)
          assert_equal error_class.name, values.fetch(:metadata).fetch(:error_class)
          assert_not_includes values.inspect, "private-error-detail"
          assert_not_includes values.inspect, "private-selection-token"
          assert_not_includes values.inspect, "private-account-name"
          true
        end

        post provider_connection_account_setup_path(connection), params: { account_setup: {
          token: "private-selection-token", name: "private-account-name", balance: "999999.99"
        } }

        assert_redirected_to provider_connection_account_setup_path(connection)
        reason = kind == :unsupported ? :conflict : kind
        assert_equal I18n.t("provider_connections.account_setup.errors.#{reason}"), flash[:alert]
        assert_not_includes response.body, "private-error-detail"
        assert_not_includes response.body, "private-account-name"
      end
    end
  end

  test "show refusal and diagnostic failure return to connections without a redirect loop" do
    with_connection do |connection|
      setup_for(connection).expects(:catalog).raises(ProviderConnection::AccountSetup::Conflict, "private-error-detail")
      DebugLogEntry.stubs(:capture).raises(IOError, "diagnostic failed")

      get provider_connection_account_setup_path(connection)

      assert_redirected_to settings_providers_path
      assert_equal 303, response.status
      assert_equal I18n.t("provider_connections.account_setup.errors.conflict"), flash[:alert]
    end
  end

  test "malformed scalar parameters refuse before command construction" do
    with_connection do |connection|
      ProviderConnection::AccountSetup.expects(:new).never

      get provider_connection_account_setup_path(connection), params: { external_account_id: [ SecureRandom.uuid ] }
      assert_redirected_to settings_providers_path
      get provider_connection_account_setup_path(connection), params: { after: { id: SecureRandom.uuid } }
      assert_redirected_to settings_providers_path
      post provider_connection_account_setup_path(connection), params: { account_setup: { token: [ "wrong-shape" ] } }
      assert_redirected_to provider_connection_account_setup_path(connection)
      post provider_connection_account_setup_path(connection), params: { account_setup: "wrong-shape" }
      assert_redirected_to provider_connection_account_setup_path(connection)
    end
  end

  test "family member cannot read confirm apply or refresh setup" do
    with_connection do |connection|
      sign_in users(:family_member)
      ProviderConnection::AccountSetup.expects(:new).never

      get provider_connection_account_setup_path(connection)
      assert_redirected_to accounts_path
      post provider_connection_account_setup_path(connection), params: { account_setup: { token: "signed-selection" } }
      assert_redirected_to accounts_path
      post refresh_provider_connection_account_setup_path(connection)
      assert_redirected_to accounts_path
    end
  end

  test "another family's connection is absent on every setup route" do
    with_connection(family: families(:empty)) do |connection|
      ProviderConnection::AccountSetup.expects(:new).never

      get provider_connection_account_setup_path(connection)
      assert_response :not_found
      post provider_connection_account_setup_path(connection), params: { account_setup: { token: "signed-selection" } }
      assert_response :not_found
      post refresh_provider_connection_account_setup_path(connection)
      assert_response :not_found
    end
  end

  test "browser delegates retired connection setup without loading a legacy item" do
    with_connection do |connection|
      legacy_id = SecureRandom.uuid
      ProviderMigrationControl.create!(family: connection.family, provider_key: "up", legacy_type: "UpItem", legacy_id: legacy_id,
        provider_connection: connection, state: "retired")
      assert_not UpItem.exists?(legacy_id)
      setup_for(connection).expects(:catalog).returns(catalog(connection))

      get provider_connection_account_setup_path(connection)

      assert_response :success
      assert_select "form[action=?]", refresh_provider_connection_account_setup_path(connection)
    end
  end

  test "both native settings surfaces link supported account setup" do
    with_connection do |connection|
      configuration = mock("configuration")
      ProviderConnection::Configuration.expects(:new).with(connection: connection, actor: users(:family_admin)).returns(configuration)
      configuration.expects(:form).returns(ProviderConnection::Configuration::Form.new(connection: connection, token: "settings-token", credential_fields: []))

      get edit_provider_connection_path(connection)
      assert_response :success
      assert_select "a[href=?]", provider_connection_account_setup_path(connection)

      get settings_providers_path
      assert_response :success
      assert_select "a[href=?]", provider_connection_account_setup_path(connection)

      Provider::AccountData::Up.stubs(:account_setup_types).returns([])
      get settings_providers_path
      assert_response :success
      assert_select "a[href=?]", provider_connection_account_setup_path(connection), count: 0
    end
  end

  private
    def with_connection(**attributes)
      with_provider_encryption do
        yield create_provider_connection(**{ family: users(:family_admin).family, name: "Native account setup" }.merge(attributes))
      end
    end

    def setup_for(connection)
      command = mock("native account setup")
      ProviderConnection::AccountSetup.expects(:new).with(connection: connection, actor: users(:family_admin)).returns(command)
      command
    end

    def catalog(connection, external_accounts: [], existing_accounts: [], next_cursor: nil)
      OpenStruct.new(connection: connection, external_accounts: external_accounts, existing_accounts: existing_accounts,
        account_types: [ "Depository", "CreditCard" ], next_cursor: next_cursor)
    end

    def selection(connection, external, account: nil, secondary: false, account_types: [ "Depository" ])
      OpenStruct.new(connection: connection, external_account: external, account: account, token: "signed-original-selection",
        account_types: account_types, secondary: secondary)
    end
end
