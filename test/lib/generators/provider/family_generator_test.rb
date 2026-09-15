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

  # Every hand-written *_item.rb / *_account.rb model in app/models encrypts its raw
  # provider payload columns (they hold full API responses, which can contain secrets).
  # These templates generate the starting point for every *new* provider, so a gap here
  # means every future provider ships with unencrypted payloads until someone notices.
  def template_path(name)
    File.expand_path("../../../../../lib/generators/provider/family/templates/#{name}", __FILE__)
  end

  test "item model template encrypts raw_payload and raw_institution_payload" do
    template = File.read(template_path("item_model.rb.tt"))
    encryption_block = template[/if encryption_ready\?.*?\n  end/m]

    assert encryption_block, "expected an `if encryption_ready?` block in item_model.rb.tt"
    assert_includes encryption_block, "encrypts :raw_payload"
    assert_includes encryption_block, "encrypts :raw_institution_payload"
  end

  test "account model template includes Encryptable and encrypts raw payload columns" do
    template = File.read(template_path("account_model.rb.tt"))

    assert_includes template, "Encryptable"
    encryption_block = template[/if encryption_ready\?.*?\n  end/m]

    assert encryption_block, "expected an `if encryption_ready?` block in account_model.rb.tt"
    assert_includes encryption_block, "encrypts :raw_payload"
    assert_includes encryption_block, "encrypts :raw_transactions_payload"
    assert_includes encryption_block, "encrypts :raw_holdings_payload"
    assert_includes encryption_block, "encrypts :raw_activities_payload"
  end
end
