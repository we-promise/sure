require_relative "generator_test_helper"
require_relative "../../../../lib/generators/provider/family/family_generator"

class Provider::FamilyGeneratorTest < ProviderGeneratorTestCase
  def test_legacy_family_command_generates_a_connection_scoped_integration_only
    generate([ "acme_bank", "token:text:secret" ])

    assert_equal expected_files, generated_files
    assert_equal "connection", load_generated_adapter.definition.credential_scope
    assert_generated_ruby_compiles
  end

  def test_family_alias_honors_shared_options_and_pretend
    generate([ "acme_bank" ], { type: "investment", credential_scope: "application", pretend: true })
    assert_empty Dir.children(@destination)

    generate([ "acme_bank" ], { type: "investment", credential_scope: "application" })
    definition = load_generated_adapter.definition
    assert_equal "application", definition.credential_scope
    assert_equal %w[transactions holdings activities], definition.capabilities
  end

  private
    def generator_class
      Provider::FamilyGenerator
    end
end
