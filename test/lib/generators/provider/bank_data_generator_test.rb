require_relative "generator_test_helper"
require_relative "../../../../lib/generators/provider/bank_data/bank_data_generator"

class Provider::BankDataGeneratorTest < ProviderGeneratorTestCase
  def test_bank_data_compatibility_command_generates_the_canonical_package
    generate([ "acme_bank", "token:text:secret" ])

    assert_equal expected_files, generated_files
    assert_equal "connection", load_generated_adapter.definition.credential_scope
    assert_generated_ruby_compiles
  end

  def test_bank_data_alias_retains_investment_options_and_revocation
    generate([ "acme_bank" ], { type: "investment" })
    assert_equal %w[transactions holdings activities], load_generated_adapter.definition.capabilities

    generate([ "acme_bank" ], {}, behavior: :revoke)
    assert_empty generated_files
  end

  private
    def generator_class
      Provider::BankDataGenerator
    end
end
