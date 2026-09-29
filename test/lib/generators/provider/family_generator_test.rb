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

  def render_template(name, **locals)
    template = Rails.root.join("lib/generators/provider/family/templates", name).read
    context = Struct.new(*locals.keys).new(*locals.values)
    ERB.new(template, trim_mode: "-").result(context.instance_eval { binding })
  end

  test "the unlinking scaffold renders to valid Ruby and carries the disposition seam" do
    rendered = render_template("unlinking_concern.rb.tt", class_name: "Gocardless", file_name: "gocardless")

    assert_parses rendered
    # A generated provider retains by default and refuses a discard it has not
    # implemented, rather than accepting one and keeping the data.
    assert_includes rendered, "disposition: ProviderDisconnectable::DEFAULT_DISPOSITION"
    assert_includes rendered, "does not implement the #{'#{disposition}'} disposition"
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

  # Row and drawer forms post from the page, so no request carries a Turbo-Frame
  # header: saves and errors stream into the panel, and a new connection reloads.
  test "the controller scaffold renders to valid Ruby and answers panel requests in place" do
    rendered = render_template("controller.rb.tt", class_name: "Gocardless", file_name: "gocardless",
                               table_name: "gocardless_items", parsed_fields: [ { name: "secret_id" } ])

    assert_parses rendered
    assert_not_includes rendered, "turbo_frame_request?"
    assert_includes rendered, "if turbo_panel_request?"
    assert_match(/if @gocardless_item\.save\n\s+redirect_to settings_providers_path, notice:/, rendered)
  end

  # Bank sync builds its connection rows and drawers from FAMILY_PANELS, so a
  # section injected into show.html.erb would render outside both.
  test "adds the provider to the family panels of the real providers controller" do
    source = Rails.root.join("app/controllers/settings/providers_controller.rb").read
    result = Provider::FamilyGenerator.append_family_panel_entry(source, key: "gocardless", title: "Gocardless")

    assert_parses result
    assert_includes result, %(      { key: "gocardless", title: "Gocardless", turbo_id: "gocardless", partial: "gocardless_panel" }\n    ].freeze)
  end

  test "separates the new family panel from the previous last entry" do
    result = Provider::FamilyGenerator.append_family_panel_entry(<<~RUBY, key: "gocardless", title: "Gocardless")
      FAMILY_PANELS = [
        { key: "akahu", title: "Akahu", turbo_id: "akahu", partial: "akahu_panel" }
      ].freeze
    RUBY

    assert_parses result
    assert_includes result, %(partial: "akahu_panel" },\n  { key: "gocardless")
  end

  test "returns nil when there are no family panels to update" do
    assert_nil Provider::FamilyGenerator.append_family_panel_entry("class Foo\nend\n", key: "gocardless", title: "Gocardless")
  end

  test "reserved item columns exclude family but include family_id" do
    # family is created by t.references :family as family_id, so a field named family is
    # not a collision and must not be rejected.
    assert_not_includes Provider::FamilyGenerator::RESERVED_ITEM_COLUMNS, "family"
    assert_includes Provider::FamilyGenerator::RESERVED_ITEM_COLUMNS, "family_id"
    assert_includes Provider::FamilyGenerator::RESERVED_ITEM_COLUMNS, "institution_id"
  end
end
