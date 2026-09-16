require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class ProviderConnections::DisconnectsControllerTest < ActionDispatch::IntegrationTest
  include ProviderIngestionTestHelper

  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    DebugLogEntry.stubs(:capture)
    Provider::AccountData::Up.stubs(:native_ready?).returns(true)
  end

  test "singleton routes separate review from token approved submission" do
    id = SecureRandom.uuid
    assert_routing({ path: "/provider_connections/#{id}/disconnect", method: :get },
      { controller: "provider_connections/disconnects", action: "show", provider_connection_id: id })
    assert_routing({ path: "/provider_connections/#{id}/disconnect", method: :post },
      { controller: "provider_connections/disconnects", action: "create", provider_connection_id: id })
  end

  test "review lists admitted names and submits only the original approval token" do
    with_connection do |connection|
      account = accounts(:checking)
      disconnect_for(connection).expects(:form).returns(selection(connection, accounts: [ account ]))

      get provider_connection_disconnect_path(connection)

      assert_response :success
      assert_select "li", text: account.name
      assert_select "p", text: I18n.t("provider_connections.disconnect.kept_description")
      assert_select "p", text: I18n.t("provider_connections.disconnect.remote_access")
      assert_select "a[href=?]", edit_provider_connection_path(connection), text: I18n.t("provider_connections.disconnect.cancel")
      assert_select "form[action=?][method='post']", provider_connection_disconnect_path(connection) do |forms|
        fields = forms.first.css("input[name], select[name], textarea[name]")
        assert_equal [ "disconnect[form_token]" ], fields.map { |field| field["name"] }.reject { |name| name == "authenticity_token" }
        assert_select "input[name='disconnect[form_token]'][value='signed-original-disconnect']"
        assert_select "button[type='submit']", text: I18n.t("provider_connections.disconnect.submit")
      end
      assert_not_includes response.body, "private-provider-token"
    end
  end

  test "review supports a connection with no linked accounts" do
    with_connection do |connection|
      disconnect_for(connection).expects(:form).returns(selection(connection))

      get provider_connection_disconnect_path(connection)

      assert_response :success
      assert_select "p", text: I18n.t("provider_connections.disconnect.no_accounts")
      assert_select "button[type='submit']", text: I18n.t("provider_connections.disconnect.submit")
    end
  end

  test "submission delegates only the signed token to the family scoped connection" do
    with_connection do |connection|
      disconnect_for(connection).expects(:call).with(token: "signed-original-disconnect").returns(OpenStruct.new(connection: connection, replayed: false))

      post provider_connection_disconnect_path(connection), params: { disconnect: {
        form_token: "signed-original-disconnect", account_ids: [ accounts(:checking).id ], destroy_accounts: "true",
        family_id: families(:empty).id, connection_id: SecureRandom.uuid, credentials: { token: "untrusted-secret" }
      } }

      assert_redirected_to settings_providers_path
      assert_equal 303, response.status
      assert_equal I18n.t("provider_connections.disconnect.success"), flash[:notice]
      assert_not_includes response.body, "untrusted-secret"
    end
  end

  test "a duplicate successful submission has the same safe result" do
    with_connection do |connection|
      disconnect_for(connection).expects(:call).with(token: "signed-original-disconnect").returns(OpenStruct.new(connection: connection, replayed: true))

      post provider_connection_disconnect_path(connection), params: { disconnect: { form_token: "signed-original-disconnect" } }

      assert_redirected_to settings_providers_path
      assert_equal I18n.t("provider_connections.disconnect.success"), flash[:notice]
    end
  end

  test "stale approval returns to a fresh review without rendering old account names or token" do
    with_connection do |connection|
      command = disconnect_for(connection)
      command.expects(:form).returns(selection(connection, accounts: [ accounts(:checking) ]))
      command.expects(:call).with(token: "signed-original-disconnect").raises(ProviderConnection::Disconnect::Conflict, "private-graph-details")

      get provider_connection_disconnect_path(connection)
      assert_response :success
      post provider_connection_disconnect_path(connection), params: { disconnect: { form_token: "signed-original-disconnect" } }

      assert_redirected_to provider_connection_disconnect_path(connection)
      assert_equal 303, response.status
      assert_equal I18n.t("provider_connections.disconnect.errors.conflict"), flash[:alert]
      assert_not_includes response.body, "signed-original-disconnect"
      assert_not_includes response.body, "private-graph-details"
    end
  end

  {
    busy: ProviderConnection::Disconnect::Busy,
    unsupported: Provider::AccountData::UnsupportedCapability,
    stale_writer: Provider::AccountData::StaleWriter,
    missing_after_admission: ActiveRecord::RecordNotFound,
    invalid: ArgumentError,
    database: ActiveRecord::StatementInvalid,
    unexpected: IOError
  }.each do |kind, error_class|
    test "#{kind} error excludes private details from diagnostics and response" do
      with_connection do |connection|
        disconnect_for(connection).expects(:call).raises(error_class, "private-exception-data")
        DebugLogEntry.expects(:capture).with do |**values|
          assert_equal connection.id, values.fetch(:metadata).fetch(:provider_connection_id)
          assert_equal error_class.name, values.fetch(:metadata).fetch(:error_class)
          assert_not_includes values.inspect, "private-exception-data"
          assert_not_includes values.inspect, "private-approval-token"
          true
        end

        post provider_connection_disconnect_path(connection), params: { disconnect: { form_token: "private-approval-token" } }

        reason = case kind
        when :unsupported, :stale_writer, :missing_after_admission then :conflict
        when :database, :unexpected then :failed
        else kind
        end
        assert_redirected_to provider_connection_disconnect_path(connection)
        assert_equal I18n.t("provider_connections.disconnect.errors.#{reason}"), flash[:alert]
        assert_not_includes response.body, "private-exception-data"
        assert_not_includes response.body, "private-approval-token"
      end
    end
  end

  test "failed review and failed diagnostic storage return to settings without a redirect loop" do
    with_connection do |connection|
      disconnect_for(connection).expects(:form).raises(ProviderConnection::Disconnect::Conflict, "private-permission-details")
      DebugLogEntry.stubs(:capture).raises(IOError, "private-diagnostic-data")

      get provider_connection_disconnect_path(connection)

      assert_redirected_to settings_providers_path
      assert_equal 303, response.status
      assert_equal I18n.t("provider_connections.disconnect.errors.conflict"), flash[:alert]
    end
  end

  test "missing and malformed approval tokens refuse before constructing the command" do
    with_connection do |connection|
      ProviderConnection::Disconnect.expects(:new).never
      [ {}, { disconnect: "wrong-shape" }, { disconnect: { form_token: "" } },
        { disconnect: { form_token: [ "wrong-shape" ] } }, { disconnect: { form_token: { value: "wrong-shape" } } } ].each do |values|
        post provider_connection_disconnect_path(connection), params: values
        assert_redirected_to provider_connection_disconnect_path(connection)
        assert_equal I18n.t("provider_connections.disconnect.errors.invalid"), flash[:alert]
      end
    end
  end

  test "non admin cannot read account review or submit approval" do
    with_connection do |connection|
      sign_in users(:family_member)
      ProviderConnection::Disconnect.expects(:new).never

      get provider_connection_disconnect_path(connection)
      assert_redirected_to accounts_path
      post provider_connection_disconnect_path(connection), params: { disconnect: { form_token: "signed-original-disconnect" } }
      assert_redirected_to accounts_path
    end
  end

  test "foreign family connection stays absent on review and submission" do
    with_connection(family: families(:empty)) do |connection|
      ProviderConnection::Disconnect.expects(:new).never

      get provider_connection_disconnect_path(connection)
      assert_response :not_found
      post provider_connection_disconnect_path(connection), params: { disconnect: { form_token: "signed-original-disconnect" } }
      assert_response :not_found
    end
  end

  test "native editor links readiness admitted disconnect without changing the existing settings form" do
    with_connection do |connection|
      configuration = mock("configuration")
      ProviderConnection::Configuration.expects(:new).twice.with(connection: connection, actor: users(:family_admin)).returns(configuration)
      configuration.expects(:form).twice.returns(ProviderConnection::Configuration::Form.new(connection: connection,
        token: "settings-token", credential_fields: []))

      get edit_provider_connection_path(connection)
      assert_response :success
      assert_select "a[href=?]", provider_connection_disconnect_path(connection), text: I18n.t("provider_connections.disconnect.open")
      assert_select "form[action=?]", provider_connection_path(connection)

      Provider::AccountData::Up.stubs(:native_ready?).returns(false)
      get edit_provider_connection_path(connection)
      assert_response :success
      assert_select "a[href=?]", provider_connection_disconnect_path(connection), count: 0
    end
  end

  private
    def with_connection(**attributes)
      with_provider_encryption do
        yield create_provider_connection(**{ family: users(:family_admin).family, name: "Native disconnect review" }.merge(attributes))
      end
    end

    def disconnect_for(connection)
      command = mock("native disconnect")
      ProviderConnection::Disconnect.stubs(:new).with(connection: connection, actor: users(:family_admin)).returns(command)
      command
    end

    def selection(connection, accounts: [])
      OpenStruct.new(connection: connection, accounts: accounts, token: "signed-original-disconnect")
    end
end
