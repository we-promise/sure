require_relative "generator_test_helper"
require_relative "../../../../lib/generators/provider/global/global_generator"

class Provider::GlobalGeneratorTest < ProviderGeneratorTestCase
  def test_legacy_global_command_generates_application_credentials_without_global_accounts
    generate([ "acme_bank", "client_secret:text:secret" ])

    assert_equal expected_files, generated_files
    assert_equal "application", load_generated_adapter.definition.credential_scope
    assert_generated_ruby_compiles
    assert_includes read_generated("docs/providers/acme_bank.md"), "All connections\nremain family-owned"
  end

  def test_global_alias_honors_scope_override_and_revoke
    generate([ "acme_bank" ], { credential_scope: "connection" })
    assert_equal "connection", load_generated_adapter.definition.credential_scope

    generate([ "acme_bank" ], {}, behavior: :revoke)
    assert_empty generated_files
  end

  private
    def generator_class
      Provider::GlobalGenerator
    end
end
