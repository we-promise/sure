require "test_helper"
require_relative "../support/provider_ingestion_test_helper"

class ProviderConnectionsControllerTest < ActionDispatch::IntegrationTest
  include ProviderIngestionTestHelper

  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    DebugLogEntry.stubs(:capture)
    Provider::AccountData::Up.stubs(:native_ready?).returns(true)
    Provider::AccountData::Mercury.stubs(:native_ready?).returns(true)
    Provider::AccountData::Brex.stubs(:native_ready?).returns(true)
  end

  test "admin editor renders only permitted empty credential fields and original form token" do
    with_connection do |connection|
      command = configuration_for(connection)
      command.expects(:form).returns(configuration_form(connection, fields: [ "access_token" ]))

      get edit_provider_connection_path(connection)

      assert_response :success
      assert_select "form[action=?]", provider_connection_path(connection) do
        assert_select "input[name='provider_connection[form_token]'][value='signed-original-state']"
        assert_select "input[name='provider_connection[name]'][value=?]", connection.name
        assert_select "input[name='provider_connection[sync_start_date]'][type='date']"
        assert_select "input[name='provider_connection[access_token]'][type='password'][value='']"
        assert_select "input[name='provider_connection[token]']", count: 0
      end
      assert_not_includes response.body, "private-provider-token"
    end
  end

  test "a display-only credential policy renders no secret input" do
    with_connection do |connection|
      configuration_for(connection).expects(:form).returns(configuration_form(connection, fields: []))

      get edit_provider_connection_path(connection)

      assert_response :success
      assert_select "input[type='password']", count: 0
      assert_select "input[name='provider_connection[name]']"
    end
  end

  test "update passes the signed original and bounded flat attributes to the command" do
    with_connection do |connection|
      configuration_for(connection).expects(:update!).with(token: "signed-original-state",
        attributes: { "name" => "Renamed", "sync_start_date" => "2026-09-01", "access_token" => "replacement-secret" })

      patch provider_connection_path(connection), params: { provider_connection: {
        form_token: "signed-original-state", name: "Renamed", sync_start_date: "2026-09-01", access_token: "replacement-secret",
        family_id: families(:empty).id, provider_key: "mercury", base_url: "https://unexpected.example",
        settings: { region: "changed" }, credentials: { access_token: "nested-secret" }, writer_epoch: 99
      } }

      assert_redirected_to settings_providers_path
      assert_equal 303, response.status
      assert_equal I18n.t("provider_connections.update.success"), flash[:notice]
      assert_not_includes response.body, "replacement-secret"
      assert_equal "private-provider-token", connection.reload.credentials.fetch("access_token")
    end
  end

  test "blank credentials remain an explicit preserve request" do
    with_connection do |connection|
      configuration_for(connection).expects(:update!).with(token: "signed-original-state", attributes: { "access_token" => "" })

      patch provider_connection_path(connection), params: { provider_connection: { form_token: "signed-original-state", access_token: "" } }

      assert_redirected_to settings_providers_path
    end
  end

  {
    conflict: ProviderConnection::Configuration::Conflict,
    busy: Provider::AccountData::CredentialStore::Busy,
    invalid: ArgumentError,
    unsupported: Provider::AccountData::UnsupportedCapability
  }.each do |kind, error_class|
    test "#{kind} failure never renders supplied credentials or exception details" do
      with_connection do |connection|
        configuration_for(connection).expects(:update!).raises(error_class, "private-error-secret")
        DebugLogEntry.expects(:capture).with do |**values|
          assert_equal users(:family_admin).family_id, values.fetch(:family).id
          assert_equal connection.id, values.fetch(:metadata).fetch(:provider_connection_id)
          assert_equal error_class.name, values.fetch(:metadata).fetch(:error_class)
          assert_not_includes values.inspect, "private-error-secret"
          assert_not_includes values.inspect, "replacement-secret"
          true
        end

        patch provider_connection_path(connection), params: { provider_connection: {
          form_token: "signed-original-state", access_token: "replacement-secret"
        } }

        assert_redirected_to settings_providers_path
        assert_equal I18n.t("provider_connections.errors.#{kind == :unsupported ? :conflict : kind}"), flash[:alert]
        assert_not_includes response.body, "private-error-secret"
        assert_not_includes response.body, "replacement-secret"
      end
    end
  end

  test "validation messages containing credential values are not exposed" do
    with_connection do |connection|
      connection.errors.add(:credentials, "private-error-secret")
      configuration_for(connection).expects(:update!).raises(ActiveRecord::RecordInvalid.new(connection))

      patch provider_connection_path(connection), params: { provider_connection: { form_token: "signed-original-state", access_token: "replacement-secret" } }

      assert_redirected_to settings_providers_path
      assert_equal I18n.t("provider_connections.errors.invalid"), flash[:alert]
      assert_not_includes response.body, "private-error-secret"
    end
  end

  test "diagnostic failure does not replace the localized conflict response" do
    with_connection do |connection|
      configuration_for(connection).expects(:update!).raises(ProviderConnection::Configuration::Conflict, "private-error-secret")
      DebugLogEntry.stubs(:capture).raises(IOError, "diagnostic storage failed")

      patch provider_connection_path(connection), params: { provider_connection: { form_token: "signed-original-state" } }

      assert_redirected_to settings_providers_path
      assert_equal I18n.t("provider_connections.errors.conflict"), flash[:alert]
      assert_not_includes response.body, "private-error-secret"
    end
  end

  test "member cannot read or update connection configuration" do
    with_connection do |connection|
      sign_in users(:family_member)
      ProviderConnection::Configuration.expects(:new).never

      get edit_provider_connection_path(connection)
      assert_redirected_to accounts_path
      patch provider_connection_path(connection), params: { provider_connection: { name: "Denied" } }
      assert_redirected_to accounts_path
    end
  end

  test "another family's connection is absent from both routes" do
    with_connection(family: families(:empty)) do |connection|
      ProviderConnection::Configuration.expects(:new).never

      get edit_provider_connection_path(connection)
      assert_response :not_found
      patch provider_connection_path(connection), params: { provider_connection: { name: "Denied" } }
      assert_response :not_found
    end
  end

  test "settings lists native connections without requiring a retained legacy item" do
    with_connection do |connection|
      ProviderMigrationControl.create!(family: connection.family, provider_key: "up", legacy_type: "UpItem",
        legacy_id: SecureRandom.uuid, provider_connection: connection, state: "retired")
      hidden = create_provider_connection(family: families(:empty), name: "Foreign connection")

      get settings_providers_path

      assert_response :success
      assert_select "a[href=?]", edit_provider_connection_path(connection), text: I18n.t("provider_connections.list.edit", name: connection.name)
      assert_select "a[href=?]", edit_provider_connection_path(hidden), count: 0
      assert_not_includes response.body, "private-provider-token"
    end
  end

  test "a native-only family can reach configuration and Sync all from settings" do
    with_provider_encryption do
      family = Family.create!(name: "Native connections only")
      actor = users(:family_admin).dup
      actor.assign_attributes(family: family, email: "native-settings-#{SecureRandom.hex(6)}@example.test")
      actor.save!
      sign_in actor
      Provider::ConfigurationRegistry.stubs(:all).returns([])
      connection = create_provider_connection(family: family)
      ProviderMigrationControl.create!(family: family, provider_key: "up", legacy_type: "UpItem",
        legacy_id: SecureRandom.uuid, provider_connection: connection, state: "retired")

      get settings_providers_path

      assert_response :success
      assert_empty @controller.view_assigns.fetch("connected")
      assert_empty @controller.view_assigns.fetch("needs_attention")
      assert_select "a[href=?]", edit_provider_connection_path(connection)
      assert_select "form[action=?]", sync_all_settings_providers_path do
        assert_select "button", text: I18n.t("settings.providers.sync_all")
      end
    end
  end

  [ [ "up", "UpItem", :up_item, :access_token ], [ "mercury", "MercuryItem", :mercury_item, :token ],
    [ "brex", "BrexItem", :brex_item, :token ] ].each do |key, type, route, secret|
    test "migrated #{key} settings uses the shared editor and hides its old form" do
      with_provider_encryption do
        family = users(:family_admin).family
        item = type.constantize.create!({ family: family, name: "Migrated #{key}", secret => "legacy-secret" })
        connection = create_provider_connection(family: family, provider_key: key, name: "Native #{key}", credentials: { secret.to_s => "native-secret" })
        ProviderMigrationControl.create!(family: family, provider_key: key, legacy_type: type, legacy_id: item.id,
          provider_connection: connection, state: "active")

        get public_send("edit_#{route}_path", item)
        assert_redirected_to edit_provider_connection_path(connection)

        get settings_providers_path
        assert_response :success
        assert_select "a[href=?]", edit_provider_connection_path(connection)
        assert_select "form[action=?]", public_send("#{route}_path", item), count: 0
        assert_not_includes response.body, "native-secret"
      end
    end
  end

  private
    def with_connection(**attributes)
      with_provider_encryption do
        yield create_provider_connection(**{ family: users(:family_admin).family, name: "Shared connection" }.merge(attributes))
      end
    end

    def configuration_for(connection)
      command = mock("connection configuration")
      ProviderConnection::Configuration.expects(:new).with(connection: connection, actor: users(:family_admin)).returns(command)
      command
    end

    def configuration_form(connection, fields:)
      ProviderConnection::Configuration::Form.new(connection: connection, token: "signed-original-state", credential_fields: fields)
    end
end
