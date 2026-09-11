require "test_helper"
require "generators/provider/family/family_generator"

# Covers the source-enum insertion, which historically emitted invalid Ruby. The failure
# mode is nasty: the generator reports success, and the damage surfaces later as a
# SyntaxError in data_enrichment.rb with nothing pointing back at the generator. So each
# case asserts the result actually PARSES, not just that it looks right.
class Provider::FamilyGeneratorTest < ActiveSupport::TestCase
  def append(content)
    Provider::FamilyGenerator.append_source_enum_entry(content, "gocardless")
  end

  def assert_parses(source)
    RubyVM::AbstractSyntaxTree.parse(source)
  rescue SyntaxError => e
    flunk "generated invalid Ruby: #{e.message}\n\n#{source}"
  end

  test "appends to a single-line enum" do
    result = append(<<~RUBY)
      class ProviderMerchant < Merchant
        enum :source, { plaid: "plaid", redbark: "redbark" }
      end
    RUBY

    assert_parses result
    assert_includes result, 'redbark: "redbark", gocardless: "gocardless" }'
  end

  test "appends to a multiline enum without putting the entry after the expression ends" do
    result = append(<<~RUBY)
      class DataEnrichment < ApplicationRecord
        enum :source, {
          plaid: "plaid",
          redbark: "redbark"
        }
      end
    RUBY

    assert_parses result
    # The comma must attach to the previous entry, and the new entry take its indentation.
    assert_includes result, %(    redbark: "redbark",\n    gocardless: "gocardless"\n)
  end

  test "does not double the comma on a single-line enum with a trailing comma" do
    result = append('enum :source, { plaid: "plaid", redbark: "redbark", }')

    assert_parses "x = #{result}"
    assert_not_includes result, ",,"
  end

  test "does not double the comma on a multiline enum with a trailing comma" do
    result = append(<<~RUBY)
      class DataEnrichment < ApplicationRecord
        enum :source, {
          plaid: "plaid",
          redbark: "redbark",
        }
      end
    RUBY

    assert_parses result
    assert_not_includes result, ",,"
    assert_includes result, 'gocardless: "gocardless"'
  end

  test "does not emit a leading comma into an empty single-line enum" do
    result = append("enum :source, {}")

    assert_parses "x = #{result}"
    assert_not_includes result, "{,"
    assert_includes result, 'gocardless: "gocardless"'
  end

  test "does not emit a leading comma into an empty multiline enum" do
    result = append(<<~RUBY)
      class DataEnrichment < ApplicationRecord
        enum :source, {
        }
      end
    RUBY

    assert_parses result
    assert_not_includes result, "{,"
    assert_includes result, 'gocardless: "gocardless"'
  end

  test "returns nil when there is no source enum to update" do
    assert_nil append("class Foo < ApplicationRecord\nend\n")
  end

  test "preserves backslashes in the hash body rather than treating them as backreferences" do
    result = append(%(enum :source, { plaid: "pl\\\\aid" }))

    assert_includes result, "pl\\\\aid"
  end

  test "reserved item columns exclude family but include family_id" do
    # family is created by t.references :family as family_id, so a field named family is
    # not a collision and must not be rejected.
    assert_not_includes Provider::FamilyGenerator::RESERVED_ITEM_COLUMNS, "family"
    assert_includes Provider::FamilyGenerator::RESERVED_ITEM_COLUMNS, "family_id"
    assert_includes Provider::FamilyGenerator::RESERVED_ITEM_COLUMNS, "institution_id"
  end
end
