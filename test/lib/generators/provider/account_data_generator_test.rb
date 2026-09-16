require_relative "generator_test_helper"

class Provider::AccountDataGeneratorTest < ProviderGeneratorTestCase
  def test_generates_only_an_integration_package_and_preserves_shared_files
    shared_files = %w[
      app/models/family.rb app/models/account.rb app/controllers/accounts_controller.rb
      app/controllers/settings/providers_controller.rb config/routes.rb db/schema.rb
      app/views/accounts/index.html.erb app/views/settings/providers/show.html.erb
    ]
    shared_files.each do |path|
      absolute = File.join(@destination, path)
      FileUtils.mkdir_p(File.dirname(absolute))
      File.write(absolute, "existing #{path}\n")
    end

    generate([ "acme_bank", "api_key:text:secret" ])

    assert_equal (expected_files + shared_files).sort, generated_files
    shared_files.each { |path| assert_equal "existing #{path}\n", read_generated(path) }
    expected_files.grep(/\.rb\z/).each do |path|
      RubyVM::InstructionSequence.compile_file(File.join(@destination, path))
    end
    assert_equal "connection", load_generated_adapter.definition.credential_scope
  end

  def test_banking_defaults_expose_transactions_and_fail_until_implemented
    generate
    assert_generated_ruby_compiles
    adapter_class = load_generated_adapter
    assert_equal "acme_bank", adapter_class.definition.key
    assert_equal "acme_bank", adapter_class.definition.source
    assert_equal [ "transactions" ], adapter_class.definition.capabilities
    client = adapter_class::Client.new(credentials: {}, settings: {})
    adapter = adapter_class.new(client: client)

    [ client, adapter ].each do |subject|
      assert_raises(Provider::AccountData::NotImplementedError) { subject.list_accounts(cursor: "page-2") }
      assert_raises(Provider::AccountData::NotImplementedError) do
        subject.fetch_transactions(account: "remote-account", cursor: "page-2", window: { from: "2026-09-01" })
      end
    end
    refute_includes adapter_class.instance_methods(false), :fetch_holdings
    refute_includes adapter_class::Client.instance_methods(false), :fetch_activities
    assert_includes read_generated("test/models/provider/account_data/acme_bank_test.rb"), "flunk"
    assert_includes read_generated("docs/providers/acme_bank.md"), "Status: draft"
  end

  def test_investment_generates_holdings_and_activities_with_the_same_page_contract
    generate([ "acme_bank" ], { type: "investment" })
    assert_generated_ruby_compiles
    adapter_class = load_generated_adapter
    assert_equal %w[transactions holdings activities], adapter_class.definition.capabilities
    client = adapter_class::Client.new(credentials: {}, settings: {})
    adapter = adapter_class.new(client: client)

    [ client, adapter ].each do |subject|
      %i[fetch_holdings fetch_activities].each do |method|
        assert_raises(Provider::AccountData::NotImplementedError) do
          subject.public_send(method, account: "remote-account", cursor: "page-2", window: nil)
        end
      end
    end
    assert_includes read_generated("test/models/provider/account_data/acme_bank_test.rb"), "normalizes holdings and investment activities"
  end

  def test_declared_fields_preserve_secret_markers_and_typed_defaults
    generate([
      "acme_bank", "token:text:secret", "label:string:default=personal",
      "enabled:boolean:default=false", "limit:integer:default=-12",
      "institution_id:string", "family_id:string", "name:string"
    ])
    fields = load_generated_adapter.definition.fields.to_h { |field| [ field[:name], field ] }

    assert_equal({ name: "token", type: "text", secret: true, default: nil }, fields["token"])
    assert_equal "personal", fields["label"][:default]
    assert_equal false, fields["enabled"][:default]
    assert_equal(-12, fields["limit"][:default])
    assert_equal %w[enabled family_id institution_id label limit name token], fields.keys.sort
    assert_generated_ruby_compiles
  end

  def test_default_text_is_escaped_as_data_in_generated_ruby
    value = "https://example.test:443/path?label=\"quoted\"\\suffix:default=literal\nsecond line"
    value += '#{raise "unsafe interpolation"}'
    generate([ "acme_bank", "base_url:string:default=#{value}" ])

    assert_generated_ruby_compiles
    assert_equal value, load_generated_adapter.definition.fields.first[:default]
  end

  def test_credential_scope_is_explicitly_selectable
    generate([ "acme_bank", "client_secret:text:secret" ], { credential_scope: "application" })

    assert_equal "application", load_generated_adapter.definition.credential_scope
    assert_includes read_generated("docs/providers/acme_bank.md"), "`application` scope"
  end

  def test_cli_parses_typed_fields_and_hyphenated_options
    capture_io do
      generator_class.start(
        [ "acme_bank", "limit:integer:default=5", "--type=investment", "--credential-scope=application" ],
        destination_root: @destination
      )
    end

    definition = load_generated_adapter.definition
    assert_equal "application", definition.credential_scope
    assert_equal %w[transactions holdings activities], definition.capabilities
    assert_equal 5, definition.fields.first[:default]
    assert_equal expected_files, generated_files
  end

  def test_generated_client_and_adapter_inspection_hide_both_credential_scopes
    generate
    adapter_class = load_generated_adapter
    client = adapter_class::Client.new(
      credentials: { token: "connection-private-token" }, settings: {},
      application_credentials: { secret: "application-private-secret" }
    )
    adapter = adapter_class.new(client: client)

    [ client, adapter ].each do |subject|
      refute_includes subject.inspect, "connection-private-token"
      refute_includes subject.inspect, "application-private-secret"
    end
  end

  def test_rejects_unsafe_or_reserved_provider_names_before_writing
    [ "AcmeBank", "acme/bank", "acme::bank", "../acme", "acme-bank", "acme_", "acme__bank", "1bank", "adapter", "definition", "page", "record", "error", "unsupported_capability", "not_implemented_error", "invalid_response", "stale_writer", "incomplete_page", "budget_exhausted", "registry", "normalization", "syncer", "runtime_context", "migration_value", "migration_copier", "migration_manifest", "migration_manifest_catalog" ].each do |name|
      assert_raises(Thor::Error, "Expected #{name.inspect} to be rejected") { generate([ name ]) }
      assert_empty generated_files
    end
  end

  def test_rejects_malformed_fields_before_writing
    [
      "token", "token:", ":text", "Token:text", "token-name:text", "token:text:private",
      "token:text:secret:secret", "token:text:", "token:jsonb", "token:float",
      "token_:text", "token__name:text", "token:text:secret:default=secret",
      "enabled:boolean:default=1", "enabled:boolean:default=TRUE", "limit:integer:default=1.5",
      "limit:integer:default=12abc", "limit:integer:default=", "limit:integer:default= 2"
    ].each do |field|
      assert_raises(Thor::Error, "Expected #{field.inspect} to be rejected") { generate([ "acme_bank", field ]) }
      assert_empty generated_files
    end
  end

  def test_force_cannot_overwrite_shared_credential_or_group_runtime_components
    %w[application_credentials credential_store exchange_rate_resolver nonce_generator request_grant runtime_inputs request_inputs generation_accounts transaction_group transaction_sync pagination_restart_required legacy_writer_fence legacy_writer_guard deferred_page financial_identity_manifest identity_bootstrap_plan migration_preparation sync_execution auxiliary_copier retained_row].each do |name|
      assert_raises(Thor::Error) { generate([ name ], { force: true }) }
      assert_empty generated_files
    end
  end

  def test_rejects_duplicate_configuration_fields
    assert_raises(Thor::Error) { generate([ "acme_bank", "token:text:secret", "token:string" ]) }
    assert_empty generated_files
  end

  def test_every_shared_runtime_file_is_protected_from_force_and_revocation
    runtime = File.expand_path("../../../../app/models/provider/account_data", __dir__)
    Dir.glob(File.join(runtime, "*.rb")).sort.each do |path|
      # Integration adapters intentionally remain replaceable with --force.
      # Discover shared components from the real source tree so adding one cannot
      # silently leave it available as a destructive generator name.
      next if File.read(path).match?(/^class Provider::AccountData::\w+ < Provider::AccountData::Adapter\s*$/)

      name = File.basename(path, ".rb")
      target = "app/models/provider/account_data/#{name}.rb"
      absolute = File.join(@destination, target)
      FileUtils.mkdir_p(File.dirname(absolute))
      File.write(absolute, "# Shared runtime must survive\n")
      before = generated_files.to_h { |file| [ file, read_generated(file) ] }

      assert_raises(Thor::Error, "force must reject shared component #{name}") do
        generate([ name ], { force: true })
      end
      assert_raises(Thor::Error, "revoke must reject shared component #{name}") do
        generate([ name ], {}, behavior: :revoke)
      end
      assert_equal before, generated_files.to_h { |file| [ file, read_generated(file) ] }
    end
  end

  def test_rejects_unknown_options_and_retired_skip_switches
    %w[--skip-migration --skip-models --skip-routes --skip-view --skip-controller --skip-adapter --typo].each do |option|
      assert_command_rejected([ "acme_bank", option ])
    end
    assert_command_rejected([ "acme_bank", "--type=unknown" ])
    assert_command_rejected([ "acme_bank", "--credential-scope=unknown" ])
  end

  def test_pretend_makes_no_files_or_directories
    generate([ "acme_bank", "token:text:secret" ], { pretend: true })

    assert_empty Dir.children(@destination)
  end

  def test_revoke_removes_only_the_generated_package
    generate
    File.write(File.join(@destination, "keep.txt"), "existing content")

    generate([ "acme_bank" ], {}, behavior: :revoke)

    assert_equal [ "keep.txt" ], generated_files
    assert_equal "existing content", read_generated("keep.txt")
  end

  def test_rerunning_is_idempotent_and_skip_preserves_edited_files
    generate
    originals = expected_files.to_h { |path| [ path, read_generated(path) ] }
    generate
    assert_equal originals, expected_files.to_h { |path| [ path, read_generated(path) ] }
    path = "app/models/provider/account_data/acme_bank.rb"
    File.write(File.join(@destination, path), "# User implementation\n")

    generate([ "acme_bank" ], { skip: true })

    assert_equal "# User implementation\n", read_generated(path)
    assert_equal expected_files, generated_files
  end
end
