require "test_helper"
require "generators/provider/family/family_generator"

# Covers the source-enum insertion, which historically emitted invalid Ruby. The failure
# mode is nasty: the generator reports success, and the damage surfaces later as a
# SyntaxError in data_enrichment.rb with nothing pointing back at the generator. So each
# case asserts the result actually PARSES, not just that it looks right.
class Provider::FamilyGeneratorTest < ActiveSupport::TestCase
  module GeneratedControllers
  end

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

  # A generated view must be plain ERB once Thor has rendered it: no Ruby string
  # building its tags, at either end, and source that Action View can compile.
  def assert_plain_erb(generated)
    # A tag built from strings renders as text: refuse a string that opens one
    # ("<" + ..., "<%..."), or a concatenation that closes one (..." + ">").
    assert_no_match(/["']<["'] \+|["']<%|%["'] \+ ["']>/, generated)
    assert_parses ActionView::Template::Handlers::ERB::Erubi.new(generated).src
  end

  # Renders a generated view the way Rails would, from a real view path, so relative
  # translation keys and strict locals behave as they do in the app. Redbark has the
  # model, routes, fixtures and translations the generated views call, so it stands
  # in for a new provider here. The view sits at the app's own path, prepended so it
  # renders instead of Redbark's: under any other prefix its relative keys would
  # resolve in a scope the app does not have.
  def render_generated_view(generated, partial: nil, template: nil, **options)
    Dir.mktmpdir do |dir|
      virtual_path = partial ? partial.sub(%r{([^/]+)\z}, '_\\1') : template
      file = File.join(dir, "#{virtual_path}.html.erb")
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, generated)

      controller = Class.new(ApplicationController) { prepend_view_path dir }
      target = partial ? { partial: partial } : { template: template, layout: false }
      html = controller.renderer.render(**target, **options)
      # Missing keys render a placeholder rather than raising in test, so a key
      # the app does not define would otherwise pass unnoticed.
      assert_not_includes html, "translation_missing"
      html
    end
  end

  test "the unlinking scaffold renders to valid Ruby and carries the disposition seam" do
    rendered = render_template("unlinking_concern.rb.tt", class_name: "Gocardless", file_name: "gocardless")

    assert_parses rendered
    # A generated provider retains by default and refuses a discard it has not
    # implemented, rather than accepting one and keeping the data.
    assert_includes rendered, "disposition: ProviderDisconnectable::DEFAULT_DISPOSITION"
    assert_includes rendered, "does not implement the #{'#{disposition}'} disposition"
  end

  # A generated card must require the accounts it lists, so a render that
  # forgets them fails instead of showing every account on the connection.
  # Its job has no viewer to filter for, so it sends the toast, never the card.
  test "the generated card requires visible_accounts and its job does not broadcast it" do
    card = render_template("item_partial.html.erb.tt", file_name: "gocardless")
    job = render_template("activities_fetch_job.rb.tt", class_name: "Gocardless", file_name: "gocardless")

    assert_equal "<%# locals: (gocardless_item:, visible_accounts:) %>\n", card.lines.first
    assert_includes card, '<%= render "accounts/index/account_groups", accounts: visible_accounts %>'
    assert_parses job
    assert_not_includes job, '"gocardless_items/gocardless_item"'
    assert_includes job, "@gocardless_account.gocardless_item&.family&.broadcast_sync_complete"
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
    assert_includes rendered, %(render_provider_panel("gocardless", alert: @gocardless_item.errors.full_messages.join(", ")))
    assert_includes rendered, 'render_provider_panel("gocardless", notice: t(".success"'
    assert_match(/if @gocardless_item\.save\n\s+redirect_to settings_providers_path, notice:/, rendered)
  end

  test "generated account entry points escape frames and preserve ordinary redirects" do
    rendered = render_template("controller.rb.tt", class_name: "Gocardless", file_name: "gocardless",
                               table_name: "gocardless_items", parsed_fields: [])
    # Evaluate the actual scaffold in an isolated namespace, without installing a
    # provider or altering the application's routes/models.
    namespace = GeneratedControllers
    namespace.module_eval(rendered)
    controller_class = namespace.const_get(:GocardlessItemsController)
    family = mock("family")
    items = mock("items")
    accounts = mock("accounts")
    family.stubs(:gocardless_items).returns(items)
    family.stubs(:accounts).returns(accounts)
    items.stubs(:first).returns(nil)
    accounts.stubs(:find).with("account-id").returns(accounts(:depository))
    Current.stubs(:family).returns(family)

    [ :preload_accounts, :select_accounts, :select_existing_account ].each do |action|
      [ nil, "modal", "account-picker" ].each do |frame_id|
        controller = controller_class.new
        request = ActionDispatch::TestRequest.create
        request.headers["Turbo-Frame"] = frame_id if frame_id
        controller.set_request!(request)
        controller.set_response!(ActionDispatch::TestResponse.new)
        controller.params = { account_id: "account-id" }
        controller.stubs(:settings_providers_path).returns("/settings/providers")
        controller.stubs(:t).with(".no_credentials_configured").returns("Configure a connection first.")

        controller.public_send(action)

        assert_equal "Configure a connection first.", controller.flash[:alert]
        if frame_id
          assert_equal 200, controller.response.status
          html = Nokogiri::HTML.fragment(controller.response.body)
          assert html.at_css("turbo-frame##{frame_id} turbo-stream[action=redirect][target='/settings/providers']")
        else
          assert_equal 302, controller.response.status
          assert_equal "http://test.host/settings/providers", controller.response.location
        end
      end
    end
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

  # provider_summary leaves a key it doesn't know under Available, so a connected
  # provider only moves to Your connections through its own case.
  test "adds a provider_summary case to the real settings helper" do
    source = Rails.root.join("app/helpers/settings_helper.rb").read
    result = Provider::FamilyGenerator.append_provider_summary_case(source, key: "gocardless")

    assert_parses result
    assert_includes result[/def provider_summary\b.*?\n  end\n/m],
                    %(    when "gocardless"\n      return { status: :off } unless @gocardless_items&.any?\n      sync_based_summary(key)\n    else\n      { status: :off }\n)
  end

  test "returns nil when there is no provider_summary to update" do
    assert_nil Provider::FamilyGenerator.append_provider_summary_case("module Foo\nend\n", key: "gocardless")
  end

  # The row's sync status reads both maps, and its Sync button posts a key that
  # Settings::ProvidersController#sync looks up in PANEL_SYNCABLE_TYPES.
  test "adds the provider to the sync maps of the real providers controller" do
    source = Rails.root.join("app/controllers/settings/providers_controller.rb").read
    result = Provider::FamilyGenerator.append_panel_syncable_type(source, key: "gocardless", class_name: "Gocardless")
    result = Provider::FamilyGenerator.append_family_panel_item(result, key: "gocardless")

    assert_parses result
    syncable = result[/PANEL_SYNCABLE_TYPES = \{\n(.*?)\n\s*\}\.freeze/m, 1].lines(chomp: true)
    items = result[/def family_panel_items\n\s*\{\n(.*?)\n\s*\}\n/m, 1].lines(chomp: true)

    assert_equal %("gocardless" => "GocardlessItem"), syncable.last.squish
    assert_equal %("gocardless" => @gocardless_items), items.last.squish
    # The arrows line up with the entry above, however long the longest key is.
    assert_equal syncable[-2].index("=>"), syncable.last.index("=>")
    assert_equal items[-2].index("=>"), items.last.index("=>")
  end

  test "keeps a space before the arrow when the new key is longer than the column" do
    result = Provider::FamilyGenerator.append_panel_syncable_type(<<~RUBY, key: "gocardless_bank_data", class_name: "GocardlessBankData")
      PANEL_SYNCABLE_TYPES = {
        "up" => "UpItem"
      }.freeze
    RUBY

    assert_parses result
    assert_includes result, %(  "up" => "UpItem",\n  "gocardless_bank_data" => "GocardlessBankDataItem"\n}.freeze)
  end

  test "reserved item columns exclude family but include family_id" do
    # family is created by t.references :family as family_id, so a field named family is
    # not a collision and must not be rejected.
    assert_not_includes Provider::FamilyGenerator::RESERVED_ITEM_COLUMNS, "family"
    assert_includes Provider::FamilyGenerator::RESERVED_ITEM_COLUMNS, "family_id"
    assert_includes Provider::FamilyGenerator::RESERVED_ITEM_COLUMNS, "institution_id"
  end

  # The old templates built opening tags with "<" + and closing ones with "%" + ">".
  # A string-built closer that ends a multi-line tag breaks the compiled Ruby, so
  # the parse check catches it, but one standing alone still parses and renders a
  # stray %> as text. The check refuses string building at either end.
  test "the plain ERB check refuses a tag built from strings at either end" do
    [
      %(<div>\n<%= "<" + "%= t(\".title\") %" + ">" %>\n</div>\n),
      %(<%= render DS::Link.new(\n  text: "x"\n) <%= "%" + ">" %>\n),
      %(<p>x</p>\n<%= "%" + ">" %>\n),
      %(<div>\n<%= "<%" + "= t(\\".title\\") %" + ">" %>\n</div>\n),
      %(<p>x</p>\n<%= '%' + '>' %>\n),
      %(<div>\n<%= "<%" + "= t(\\".title\\") %" + "" + ">" %>\n</div>\n),
      %(<div>\n<%= "<" + "%= t(\\".title\\") %" + "" + ">" %>\n</div>\n)
    ].each do |generated|
      assert_raises(Minitest::Assertion) { assert_plain_erb generated }
    end
  end

  test "the generated item card is plain ERB" do
    generated = render_template("item_partial.html.erb.tt", file_name: "gocardless")

    assert_plain_erb generated
    assert_equal "<%# locals: (gocardless_item:, visible_accounts:) %>\n", generated.lines.first
    assert_includes generated, "<%= tag.div id: dom_id(gocardless_item) do %>"
  end

  test "the generated item card renders the visible accounts it is given" do
    Current.session = Session.create!(user: users(:family_admin))
    item = redbark_items(:one)
    linked = accounts(:depository)
    generated = render_template("item_partial.html.erb.tt", file_name: "redbark")
    render_card = lambda do |visible|
      render_generated_view(generated, partial: "redbark_items/redbark_item",
                                       locals: { redbark_item: item.reload, visible_accounts: visible.call })
    end

    before = render_card.call(-> { item.accounts.to_a })
    AccountProvider.create!(account: linked, provider: redbark_accounts(:savings_account))
    after = render_card.call(-> { item.accounts.to_a })
    other = render_card.call(-> { [ accounts(:investment) ] })

    assert_includes after, item.name
    assert_not_includes before, linked.name
    assert_includes after, linked.name
    assert_not_includes after, accounts(:investment).name
    # The card lists the accounts it is given, not every account on the connection.
    assert_includes other, accounts(:investment).name
    assert_not_includes other, linked.name
  end

  test "the generated setup accounts view is plain ERB that renders" do
    assert_plain_erb render_template("setup_accounts.html.erb.tt", file_name: "gocardless")

    item = redbark_items(:one)
    html = render_generated_view(render_template("setup_accounts.html.erb.tt", file_name: "redbark"),
                                 template: "redbark_items/setup_accounts",
                                 assigns: { redbark_item: item, unlinked_accounts: item.redbark_accounts })

    assert_includes html, redbark_accounts(:savings_account).name
    assert_includes html, "/redbark_items/#{item.id}/complete_account_setup"
  end

  test "the generated select existing account view is plain ERB that renders" do
    assert_plain_erb render_template("select_existing_account.html.erb.tt", file_name: "gocardless")

    account = accounts(:depository)
    html = render_generated_view(render_template("select_existing_account.html.erb.tt", file_name: "redbark"),
                                 template: "redbark_items/select_existing_account",
                                 assigns: { account: account, redbark_accounts: [ redbark_accounts(:savings_account) ] })

    assert_includes html, account.name
    assert_includes html, redbark_accounts(:savings_account).name
    assert_includes html, "/redbark_items/link_existing_account"
  end
end
