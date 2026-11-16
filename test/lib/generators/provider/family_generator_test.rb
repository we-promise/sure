require "test_helper"
require "generators/provider/family/family_generator"

# Covers the source-enum insertion, which historically emitted invalid Ruby. The failure
# mode is nasty: the generator reports success, and the damage surfaces later as a
# SyntaxError in data_enrichment.rb with nothing pointing back at the generator. So each
# case asserts the result actually PARSES, not just that it looks right.
class Provider::FamilyGeneratorTest < ActiveSupport::TestCase
  module GeneratedControllers
  end

  def append(content, name = "gocardless")
    Provider::FamilyGenerator.append_source_enum_entry(content, name)
  end

  def assert_parses(source)
    RubyVM::AbstractSyntaxTree.parse(source)
  rescue SyntaxError => e
    flunk "generated invalid Ruby: #{e.message}\n\n#{source}"
  end

  # The adapter template calls predicate helpers, which a Struct cannot name.
  def render_adapter(skip_view:, banking: true, parsed_fields: [ { name: "api_key", type: "string", secret: true, default: nil } ])
    helpers = {
      class_name: "Gocardless", file_name: "gocardless", options: { skip_view: skip_view },
      parsed_fields: parsed_fields,
      banking_provider?: banking, investment_provider?: !banking
    }
    context = Object.new
    helpers.each { |name, value| context.define_singleton_method(name) { value } }
    template = Rails.root.join("lib/generators/provider/family/templates/adapter.rb.tt").read
    ERB.new(template, trim_mode: "-").result(context.instance_eval { binding })
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

  # The one block of text the generator inserted between `before` and `after`.
  def inserted_text(before, after)
    old_lines = before.lines
    new_lines = after.lines
    prefix = old_lines.zip(new_lines).take_while { |a, b| a == b }.size
    suffix = old_lines.reverse.zip(new_lines.reverse).take_while { |a, b| a == b }.size
    new_lines[prefix...(new_lines.size - suffix)].join
  end

  # A template rendered as the generator renders it, with the generator's predicate
  # helpers, which a Struct cannot name.
  def render_provider_template(name, banking: true, parsed_fields: [ { name: "api_key", type: "string", secret: true, default: nil } ],
                               class_name: "Gocardless", file_name: "gocardless")
    helpers = {
      class_name: class_name, file_name: file_name, parsed_fields: parsed_fields,
      banking_provider?: banking, investment_provider?: !banking
    }
    context = Object.new
    helpers.each { |helper, value| context.define_singleton_method(helper) { value } }
    template = Rails.root.join("lib/generators/provider/family/templates", name).read
    ERB.new(template, trim_mode: "-").result(context.instance_eval { binding })
  end

  # The provider kit's base class supplies syncing, the syncer and unlinking, so a
  # generated connection model inherits them instead of carrying its own copies.
  test "the generated item model is a provider kit connection" do
    [ true, false ].each do |banking|
      model = render_provider_template("item_model.rb.tt", banking: banking)

      assert_parses model
      assert_includes model, "class GocardlessItem < ProviderItem\n"
      assert_includes model, "  include Provided, Encryptable, DestroyableLater, ProviderDisconnectable\n"
      assert_not_includes model, "def syncer"
      # The kit's syncer imports with the sync window's start date.
      assert_includes model, "def import_latest_gocardless_data(sync_start_date: nil)"
      # The kit's account flow lists only connections whose secret is set.
      assert_includes model, %(scope :with_credentials, -> { where.not(api_key: [ nil, *BLANK_TOKEN_SENTINELS ]) })
    end
  end

  test "the generated item model counts every connection as credentialed when it has no secret field" do
    model = render_provider_template("item_model.rb.tt", parsed_fields: [ { name: "region", type: "string", secret: false, default: nil } ])

    assert_parses model
    assert_includes model, "scope :with_credentials, -> { all }"
  end

  test "the generated account model is a provider kit account" do
    [ true, false ].each do |banking|
      model = render_provider_template("account_model.rb.tt", banking: banking)

      assert_parses model
      assert_includes model, "class GocardlessAccount < ProviderAccount\n"
      # ProviderAccount defines the link and #current_account.
      assert_not_includes model, "has_one :account_provider"
      assert_not_includes model, "def current_account"
    end
  end

  # ProviderItem::Syncer and ProviderItem::Unlinking replace both scaffolds.
  test "the generator writes no syncer or unlinking concern for the item" do
    Dir.mktmpdir do |dir|
      generator = Provider::FamilyGenerator.new([ "gocardless" ], {}, destination_root: dir)
      capture_io { Dir.chdir(dir) { generator.send(:create_item_concerns) } }

      assert File.exist?(File.join(dir, "app/models/gocardless_item/importer.rb"))
      assert_not File.exist?(File.join(dir, "app/models/gocardless_item/syncer.rb"))
      assert_not File.exist?(File.join(dir, "app/models/gocardless_item/unlinking.rb"))
    end
    assert_not Rails.root.join("lib/generators/provider/family/templates/syncer.rb.tt").exist?
    assert_not Rails.root.join("lib/generators/provider/family/templates/unlinking_concern.rb.tt").exist?
  end

  module GeneratedFlows
    GocardlessItem = Class.new
  end

  # ProviderItem::AccountFlow raises for a hook a provider has not defined, so the
  # generated flow is checked to define every hook itself, as a stub that names
  # what is left to do.
  test "the generated account flow stubs every hook the provider kit needs" do
    flow_source = render_provider_template("account_flow.rb.tt")
    assert_parses flow_source
    GeneratedFlows.module_eval(flow_source)
    flow_class = GeneratedFlows::GocardlessItem::AccountFlow
    flow = flow_class.allocate

    assert_operator flow_class, :<, ProviderItem::AccountFlow
    assert_equal flow_class.singleton_class, flow_class.method(:cache_sensitive_params).owner
    error = assert_raises(NotImplementedError) { flow_class.cache_sensitive_params }
    assert_includes error.message, "TODO"
    {
      fetch_accounts: [],
      resolve_item: [ "item-id" ],
      provider_error_class: [],
      upsert_provider_account!: [ "acc_1", {} ],
      provider_account_snapshot_changed?: [ Object.new, {} ]
    }.each do |hook, args|
      assert_equal flow_class, flow_class.instance_method(hook).owner, "#{hook} is not stubbed"
      error = assert_raises(NotImplementedError, hook.to_s) { flow.send(hook, *args) }
      assert_includes error.message, "TODO", hook.to_s
    end
  ensure
    GeneratedFlows::GocardlessItem.send(:remove_const, :AccountFlow) if GeneratedFlows::GocardlessItem.const_defined?(:AccountFlow, false)
  end

  test "the generator writes the account flow" do
    Dir.mktmpdir do |dir|
      generator = Provider::FamilyGenerator.new([ "gocardless" ], {}, destination_root: dir)
      capture_io { Dir.chdir(dir) { generator.send(:create_item_concerns) } }

      assert_includes File.read(File.join(dir, "app/models/gocardless_item/account_flow.rb")), "class GocardlessItem::AccountFlow < ProviderItem::AccountFlow"
    end
  end

  # The account flow reads a payload's name and currency through the account class.
  test "the generated account model answers the account flow's payload questions" do
    model = render_provider_template("account_model.rb.tt")

    assert_parses model
    assert_includes model, "  def self.name_for(account_data)\n    account_data.with_indifferent_access[:name]\n"
    assert_includes model, "  def self.currency_for(account_data)\n"
    assert_includes model, "  def self.default_accountable_attributes(_accountable_type)\n    {}\n"
  end

  # ProviderItem::Syncer reads its status and error messages from <key>_items.syncer.*.
  # Brex's are the reference set: the generated locale defines the same keys, plural
  # forms and interpolations.
  test "the generated locale has every syncer message the provider kit reads" do
    # Each message's plural forms, or the variables it interpolates.
    shape = ->(messages) do
      messages.deep_stringify_keys.transform_values { |value| value.is_a?(Hash) ? value.keys.sort : value.scan(/%\{(\w+)\}/).flatten.sort }
    end
    reference = shape.call(I18n.t("brex_items.syncer", locale: :en))

    [ true, false ].each do |banking|
      locale = YAML.safe_load(render_provider_template("locale.en.yml.tt", banking: banking))
      generated = locale.dig("en", "gocardless_items", "syncer")

      assert generated, "banking: #{banking}: no gocardless_items.syncer"
      assert_equal reference, shape.call(generated), "banking: #{banking}"
    end
  end

  # A generated card must require the accounts it lists, so a render that
  # forgets them fails instead of showing every account on the connection.
  # Its job has no viewer to filter for, so it sends the toast, never the card.
  test "the generated card requires visible_accounts and its job does not broadcast it" do
    card = render_template("item_partial.html.erb.tt", file_name: "gocardless")
    job = render_template("activities_fetch_job.rb.tt", class_name: "Gocardless", file_name: "gocardless")

    assert_equal "<%# locals: (gocardless_item:, visible_accounts:) %>\n", card.lines.first
    assert_includes card, "      visible_accounts: visible_accounts,\n"
    assert_parses job
    assert_not_includes job, '"gocardless_items/gocardless_item"'
    assert_includes job, "@gocardless_account.gocardless_item&.family&.broadcast_sync_complete"
  end

  test "inserts into a single-line enum before the first source that sorts after it" do
    result = append(<<~RUBY)
      class ProviderMerchant < Merchant
        enum :source, { akahu: "akahu", plaid: "plaid", redbark: "redbark" }
      end
    RUBY

    assert_parses result
    assert_includes result, '{ akahu: "akahu", gocardless: "gocardless", plaid: "plaid", redbark: "redbark" }'
  end

  test "inserts into a multiline enum on a line of its own, keeping the list sorted" do
    result = append(<<~RUBY)
      class DataEnrichment < ApplicationRecord
        enum :source, {
          akahu: "akahu",
          plaid: "plaid",
          redbark: "redbark"
        }
      end
    RUBY

    assert_parses result
    assert_includes result, %(    akahu: "akahu",\n    gocardless: "gocardless",\n    plaid: "plaid",\n)
  end

  test "ignores commented-out keys and keeps a comment with the entry it describes" do
    result = append(<<~RUBY)
      class DataEnrichment < ApplicationRecord
        enum :source, {
          akahu: "akahu", # zopa: "zopa"
          # plaid: imported from the Plaid API
          plaid: "plaid",
          redbark: "redbark"
        }
      end
    RUBY

    assert_parses result
    assert_includes result, %(    akahu: "akahu", # zopa: "zopa"\n    gocardless: "gocardless",\n    # plaid: imported from the Plaid API\n    plaid: "plaid",\n)
  end

  test "appends to a single-line enum a source that sorts last" do
    result = append('enum :source, { plaid: "plaid", redbark: "redbark" }', "zopa")

    assert_parses "x = #{result}"
    assert_includes result, 'redbark: "redbark", zopa: "zopa" }'
  end

  test "appends to a multiline enum a source that sorts last without putting it after the expression ends" do
    result = append(<<~RUBY, "zopa")
      class DataEnrichment < ApplicationRecord
        enum :source, {
          plaid: "plaid",
          redbark: "redbark"
        }
      end
    RUBY

    assert_parses result
    # The comma must attach to the previous entry, and the new entry take its indentation.
    assert_includes result, %(    redbark: "redbark",\n    zopa: "zopa"\n)
  end

  test "appends after a last entry with a trailing comment without putting the comma in the comment" do
    result = append(<<~RUBY, "zopa")
      class DataEnrichment < ApplicationRecord
        enum :source, {
          plaid: "plaid",
          redbark: "redbark" # last one
          # zebra: "zebra"
        }
      end
    RUBY

    assert_parses result
    assert_includes result, %(    redbark: "redbark", # last one\n    # zebra: "zebra"\n    zopa: "zopa"\n)
  end

  test "does not double the comma on a single-line enum with a trailing comma" do
    result = append('enum :source, { plaid: "plaid", redbark: "redbark", }', "zopa")

    assert_parses "x = #{result}"
    assert_not_includes result, ",,"
  end

  test "does not double the comma on a multiline enum with a trailing comma" do
    result = append(<<~RUBY, "zopa")
      class DataEnrichment < ApplicationRecord
        enum :source, {
          plaid: "plaid",
          redbark: "redbark",
        }
      end
    RUBY

    assert_parses result
    assert_not_includes result, ",,"
    assert_includes result, 'zopa: "zopa"'
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

  # ProviderItemsController serves the generated provider; the subclass names only
  # the params it permits, and a blank secret on an edit keeps the stored one.
  test "the generated controller is a thin provider kit controller" do
    fields = [ { name: "api_key", secret: true }, { name: "region", secret: false } ]
    rendered = render_template("controller.rb.tt", class_name: "Gocardless", file_name: "gocardless", parsed_fields: fields)

    assert_parses rendered
    GeneratedControllers.module_eval(rendered)
    controller_class = GeneratedControllers::GocardlessItemsController
    assert_operator controller_class, :<, ProviderItemsController
    assert_includes controller_class.private_instance_methods(false), :item_params
    assert_empty controller_class.public_instance_methods(false), "the kit serves every action"

    permitted = lambda do |persisted, submitted|
      controller = controller_class.new
      controller.params = ActionController::Parameters.new(gocardless_item: submitted)
      controller.instance_variable_set(:@gocardless_item, OpenStruct.new(persisted?: persisted))
      controller.send(:item_params).to_h.symbolize_keys
    end

    submitted = { name: "Main", sync_start_date: "2026-01-01", api_key: "", region: "eu", status: "good" }
    assert_equal({ name: "Main", sync_start_date: "2026-01-01", region: "eu" }, permitted.call(true, submitted))
    assert_equal({ name: "Main", sync_start_date: "2026-01-01", api_key: "", region: "eu" }, permitted.call(false, submitted))
    assert_equal "new", permitted.call(true, submitted.merge(api_key: "new"))[:api_key]
  ensure
    GeneratedControllers.send(:remove_const, :GocardlessItemsController) if GeneratedControllers.const_defined?(:GocardlessItemsController, false)
  end

  # The generated routes use the provider_items concern, so they must follow its
  # definition in config/routes.rb, and give the kit's controller every route it serves.
  test "the generated routes use the provider_items concern after it is defined" do
    Dir.mktmpdir do |dir|
      original = Rails.root.join("config/routes.rb").read
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config/routes.rb"), original)

      routes = Dir.chdir(dir) do
        capture_io { Provider::FamilyGenerator.new([ "gocardless" ], {}, destination_root: dir).add_routes }
        File.read("config/routes.rb")
      end

      line = "  resources :gocardless_items, only: %i[index new create show edit update destroy], concerns: :provider_items\n"
      assert_equal 1, routes.scan(line).size
      assert_operator routes.index(line), :>, routes.index("concern :provider_items do")
      assert_equal line, inserted_text(original, routes).lines.reject(&:blank?).join

      # A string eval sees the block's locals, so none may be named like a routing method.
      concern_source = original[/^  concern :provider_items do\n.*?^  end\n/m]
      route_set = ActionDispatch::Routing::RouteSet.new
      route_set.draw { instance_eval(concern_source + line) }
      helpers = route_set.named_routes.names.map(&:to_s)
      Rails.application.reload_routes_unless_loaded # routes load lazily in test
      brex = Rails.application.routes.named_routes.names.map(&:to_s).grep(/brex_item/).map { |name| name.sub("brex", "gocardless") }
      assert_equal brex.sort, helpers.sort
    end
  end

  # The flash and error messages ProviderItemsController and ProviderItem::AccountFlow
  # look up under <key>_items, with Brex's plural forms and interpolations.
  KIT_CONTROLLER_KEYS = %w[
    default_connection_name create.success update.success destroy.success errors.unexpected_error
    link_accounts.all_already_linked link_accounts.api_error link_accounts.invalid_account_names
    link_accounts.invalid_account_type link_accounts.link_failed link_accounts.no_accounts_selected
    link_accounts.no_api_token link_accounts.partial_invalid link_accounts.partial_success
    link_accounts.select_connection link_accounts.success
    link_existing_account.account_already_linked link_existing_account.api_error
    link_existing_account.invalid_account_name link_existing_account.missing_parameters
    link_existing_account.no_account_specified link_existing_account.no_api_token
    link_existing_account.provider_account_already_linked link_existing_account.provider_account_not_found
    link_existing_account.select_connection link_existing_account.success
    select_accounts.no_accounts_found select_accounts.no_api_token select_accounts.no_credentials_configured
    select_accounts.select_connection select_accounts.unexpected_error
    select_existing_account.account_already_linked select_existing_account.all_accounts_already_linked
    select_existing_account.no_account_specified select_existing_account.no_api_token
    select_existing_account.no_credentials_configured select_existing_account.select_connection
    select_existing_account.unexpected_error
    setup_accounts.api_error setup_accounts.no_api_token
    complete_account_setup.all_skipped complete_account_setup.creation_failed
    complete_account_setup.creation_failed_count complete_account_setup.no_accounts
    complete_account_setup.partial_skipped complete_account_setup.partial_success
    complete_account_setup.success complete_account_setup.unexpected_error
  ].freeze

  test "the generated locale has every message the provider kit's controller and account flow read" do
    shape = ->(value) { value.is_a?(Hash) ? value.keys.map(&:to_s).sort : value.to_s.scan(/%\{(\w+)\}/).flatten.sort }

    [ true, false ].each do |banking|
      messages = YAML.safe_load(render_provider_template("locale.en.yml.tt", banking: banking)).dig("en", "gocardless_items")

      KIT_CONTROLLER_KEYS.each do |key|
        generated = messages.dig(*key.split("."))
        assert generated, "banking: #{banking}: no gocardless_items.#{key}"
        assert_equal shape.call(I18n.t("brex_items.#{key}", locale: :en)), shape.call(generated), "banking: #{banking}: #{key}"
      end
    end
  end

  # Bank sync lists a provider through FAMILY_PANELS, which reads the adapter's
  # panel: declaration, and every account provider has a panel, so the generated
  # adapter declares one even when the item views are skipped.
  test "the generated adapter declares its connection and panel, with or without the item views" do
    [ false, true ].each do |skip_view|
      adapter = render_adapter(skip_view: skip_view)

      assert_parses adapter
      assert_includes adapter, %(declares_connection key: "gocardless", name: "Gocardless", panel: true,\n), "skip_view: #{skip_view}"
    end
  end

  # Provider::Metadata::REGISTRY is built from declares_connection metadata:, and every
  # declared provider needs these fields, so the generated adapter starts with them.
  test "the generated adapter declares the metadata every provider needs" do
    { banking: %w[Bank], investment: %w[Investment] }.each do |type, kinds|
      adapter = render_adapter(skip_view: false, banking: type == :banking)
      metadata = eval(adapter[/^\s*metadata: (\{.*\}),?$/, 1].to_s)

      assert_kind_of Hash, metadata, "#{type} adapter has no metadata"
      %i[region kinds maturity logo_text].each { |field| assert metadata[field].present?, "#{type} metadata has no #{field}" }
      assert_equal kinds, metadata[:kinds]
      assert_equal "GO", metadata[:logo_text]
    end
  end

  # The declared panel renders <key>_panel, so the partial is written even with
  # --skip-view, which skips only the item views.
  test "writes the panel partial with or without the item views" do
    [ false, true ].each do |skip_view|
      Dir.mktmpdir do |dir|
        generator = Provider::FamilyGenerator.new([ "gocardless" ], { skip_view: skip_view }, destination_root: dir)
        capture_io { generator.create_panel_view }

        assert File.exist?(File.join(dir, "app/views/settings/providers/_gocardless_panel.html.erb")), "skip_view: #{skip_view}"
      end
    end
  end

  # The Bank sync wiring runs with --skip-view too: with no adapter declaring the
  # panel (an empty directory), both runs say what to add.
  test "wires Bank sync with or without the item views" do
    [ false, true ].each do |skip_view|
      Dir.mktmpdir do |dir|
        output = Dir.chdir(dir) do
          capture_io { Provider::FamilyGenerator.new([ "gocardless" ], skip_view: skip_view).add_bank_sync_entries }.first
        end

        assert_includes output, "Bank sync will not list gocardless", "skip_view: #{skip_view}"
        assert_includes output, "metadata: {", "skip_view: #{skip_view}"
      end
    end
  end

  # The generated panel lists every active connection, so one whose credentials
  # are missing can still be edited, as Brex's does. Settings > Providers hands the
  # panel its settings_page list, so that list loads whole records too: the
  # default selects only ids, and the panel then fails reading a connection's name.
  test "the generated adapter's panel lists the family's active connections" do
    [ false, true ].each do |skip_view|
      adapter = render_adapter(skip_view: skip_view)

      assert_includes adapter, "settings_page: %i[active ordered],\n", "skip_view: #{skip_view}"
      assert_includes adapter, "settings_panel: ->(items) { items.active.ordered.includes(:syncs, :gocardless_accounts) }\n", "skip_view: #{skip_view}"
    end
  end

  # Bank sync's lists all derive from the declaration, so the generator only checks
  # it is there.
  test "warns only when the adapter does not declare its panel" do
    output = ->(key) { capture_io { Provider::FamilyGenerator.new([ key ]).add_bank_sync_entries }.first }

    assert_includes output.call("gocardless"), "Bank sync will not list gocardless"
    assert_empty output.call("redbark"), "Redbark's adapter declares its panel"
  end

  # /accounts loads a provider's items through its adapter's declaration. An adapter
  # without one (it existed, or --skip-adapter) leaves @<key>_items unset, so the code
  # the generator adds there must not fail on nil.
  test "the code added to /accounts runs when the provider's items are not loaded" do
    Dir.mktmpdir do |dir|
      files = %w[app/controllers/accounts_controller.rb app/views/accounts/index.html.erb]
      originals = files.index_with { |path| Rails.root.join(path).read }
      files.each do |path|
        FileUtils.mkdir_p(File.join(dir, File.dirname(path)))
        File.write(File.join(dir, path), originals[path])
      end

      added = Dir.chdir(dir) do
        generator = Provider::FamilyGenerator.new([ "gocardless" ])
        capture_io { generator.update_accounts_controller && generator.update_accounts_index_view }
        files.index_with { |path| inserted_text(originals[path], File.read(path)) }
      end

      stats = added["app/controllers/accounts_controller.rb"]
      section = added["app/views/accounts/index.html.erb"]
      assert_includes stats, "@gocardless_items"
      assert_includes section, "@gocardless_items"

      Object.new.instance_eval(stats)
      Object.new.instance_eval(ActionView::Template::Handlers::ERB::Erubi.new(section).src)
    end
  end

  # The /accounts section renders the item partial, which --skip-view does not write,
  # so adding it would break /accounts for every family once a connection exists.
  test "--skip-view leaves /accounts alone and says what to add" do
    Dir.mktmpdir do |dir|
      path = "app/views/accounts/index.html.erb"
      original = Rails.root.join(path).read
      FileUtils.mkdir_p(File.join(dir, File.dirname(path)))

      results = [ false, true ].index_with do |skip_view|
        File.write(File.join(dir, path), original)
        Dir.chdir(dir) do
          output = capture_io { Provider::FamilyGenerator.new([ "gocardless" ], skip_view: skip_view).update_accounts_index_view }.first
          [ File.read(path), output ]
        end
      end

      assert_includes results[false].first, "<%= render item, visible_accounts: visible_card_accounts(item) %>"
      assert_equal original, results[true].first
      assert_includes results[true].last, "app/views/gocardless_items/_gocardless_item.html.erb"
    end
  end

  # An adapter the generator did not write (it existed, or --skip-adapter) lacks the
  # template's declaration, so the generator has to say what to add.
  test "recognises an adapter that declares its panel" do
    assert Provider::FamilyGenerator.panel_declared?(render_adapter(skip_view: false), key: "gocardless")
    assert_not Provider::FamilyGenerator.panel_declared?(%(  declares_connection key: "gocardless"\n), key: "gocardless")
    assert_not Provider::FamilyGenerator.panel_declared?("class Provider::GocardlessAdapter < Provider::Base\nend\n", key: "gocardless")
    assert_not Provider::FamilyGenerator.panel_declared?(%(  declares_connection key: "gocardless_bank", name: "X", panel: true\n), key: "gocardless")
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

  GENERATED_VIEWS = {
    "panel.html.erb.tt" => "settings/providers/_%s_panel",
    "credential_fields.html.erb.tt" => "%s_items/_credential_fields",
    "item_partial.html.erb.tt" => "%s_items/_%s_item",
    "select_accounts.html.erb.tt" => "%s_items/select_accounts",
    "select_existing_account.html.erb.tt" => "%s_items/select_existing_account",
    "api_error.html.erb.tt" => "%s_items/_api_error",
    "setup_required.html.erb.tt" => "%s_items/_setup_required",
    "setup_accounts.html.erb.tt" => "%s_items/setup_accounts"
  }.freeze

  test "every generated view is plain ERB" do
    fields = [ { name: "api_key", type: "string", secret: true }, { name: "region", type: "string", default: "eu" },
               { name: "client_id", type: "integer" }, { name: "sandbox", type: "boolean" } ]
    GENERATED_VIEWS.each_key do |name|
      assert_plain_erb render_provider_template(name, parsed_fields: fields)
    end
  end

  module GeneratedHelpers
  end

  # Brex runs on the provider kit and has the model, routes and fixtures a
  # generated provider's views use, so it stands in for one here: the generated
  # views, helper and translations replace Brex's own while each view renders.
  # Brex's translations are removed first, so a key the generated locale lacks
  # shows as missing rather than falling back to Brex's.
  BREX_FIELDS = [ { name: "token", type: "text", secret: true }, { name: "base_url", type: "string" } ].freeze

  def render_as_generated_brex(target, **options)
    I18n.t("brex_items.default_connection_name") # loads the translations before replacing them
    I18n.backend.store_translations(:en, { brex_items: nil })
    generated = YAML.safe_load(render_provider_template("locale.en.yml.tt", class_name: "Brex", file_name: "brex", parsed_fields: BREX_FIELDS))
    I18n.backend.store_translations(:en, generated["en"])
    assert_not I18n.exists?("brex_items.provider_panel.token_label", :en), "Brex's own translations are still loaded"

    GeneratedHelpers.module_eval(render_provider_template("items_helper.rb.tt", class_name: "Brex", file_name: "brex")) unless GeneratedHelpers.const_defined?(:BrexItemsHelper, false)

    Dir.mktmpdir do |dir|
      GENERATED_VIEWS.each do |name, path|
        file = File.join(dir, "#{format(path, 'brex', 'brex')}.html.erb")
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, render_provider_template(name, class_name: "Brex", file_name: "brex", parsed_fields: BREX_FIELDS))
      end

      controller = Class.new(ApplicationController) do
        prepend_view_path dir
        helper GeneratedHelpers::BrexItemsHelper
      end
      html = controller.renderer.render(**target, **options)
      assert_not_includes html, "translation_missing"
      html
    end
  ensure
    I18n.reload!
  end

  test "a generated provider's panel renders through the kit with its own translations" do
    Current.session = Session.create!(user: users(:family_admin))
    item = brex_items(:one)
    ProviderItem::PanelComponent.any_instance.expects(:before_render).once

    html = render_as_generated_brex({ partial: "settings/providers/brex_panel" }, locals: { brex_items: BrexItem.where(id: item.id), error_message: nil })

    assert_includes html, item.name
    assert_includes html, "Visit your Brex dashboard to get your credentials"
    assert_includes html, "Leave blank to keep the current token"
    assert_includes html, "Paste token here"
    assert_not_includes html, item.token
  end

  test "a generated provider's card renders through the kit with the accounts it is given" do
    Current.session = Session.create!(user: users(:family_admin))
    item = brex_items(:one)
    linked = item.family.accounts.create!(name: "Brex Ops", balance: 10, currency: "USD", accountable: Depository.new)
    AccountProvider.create!(account: linked, provider: item.brex_accounts.first)
    ProviderItem::CardComponent.any_instance.expects(:before_render).twice

    shown = render_as_generated_brex({ partial: "brex_items/brex_item" }, locals: { brex_item: item, visible_accounts: [ linked ] })
    hidden = render_as_generated_brex({ partial: "brex_items/brex_item" }, locals: { brex_item: item, visible_accounts: [] })

    assert_includes shown, item.name
    assert_includes shown, "Brex Ops"
    assert_not_includes hidden, "Brex Ops"
  end

  test "a generated provider's selection dialogs render through the kit with the generated helper" do
    Current.session = Session.create!(user: users(:family_admin))
    item = brex_items(:one)
    account = accounts(:depository)
    payloads = [ { id: "acc_ops", name: "Ops", account_kind: "cash", current_balance: { amount: 1, currency: "USD" } } ]
    ProviderItem::AccountSelectionComponent.any_instance.expects(:before_render).twice

    new_accounts = render_as_generated_brex({ template: "brex_items/select_accounts", layout: false },
                                            assigns: { brex_item: item, available_accounts: payloads, accountable_type: "Depository", return_to: nil })
    existing = render_as_generated_brex({ template: "brex_items/select_existing_account", layout: false },
                                        assigns: { brex_item: item, available_accounts: payloads, account: account, return_to: nil })

    assert_includes new_accounts, "Select Brex Accounts"
    assert_includes new_accounts, %(value="acc_ops")
    assert_includes new_accounts, "/brex_items/link_accounts"
    assert_includes existing, "Link #{account.name} with Brex"
    assert_includes existing, "/brex_items/link_existing_account"
  end

  test "a generated provider's error dialogs render through the kit" do
    Current.session = Session.create!(user: users(:family_admin))

    api_error = render_as_generated_brex({ partial: "brex_items/api_error" }, locals: { error_message: "Unauthorized", return_path: "/accounts/new" })
    setup_required = render_as_generated_brex({ partial: "brex_items/setup_required" })

    assert_includes api_error, "Unable to connect to Brex"
    assert_includes api_error, "Unauthorized"
    assert_includes api_error, %(href="/accounts/new")
    assert_includes setup_required, "Credentials not configured"
  end

  test "a generated provider's setup page renders through the kit" do
    Current.session = Session.create!(user: users(:family_admin))
    item = brex_items(:one)
    flow = BrexItem::AccountFlow.new(family: item.family, item: item)
    ProviderItem::AccountSetupComponent.any_instance.expects(:before_render).once

    html = render_as_generated_brex({ template: "brex_items/setup_accounts", layout: false },
                                    assigns: { brex_item: item, brex_accounts: item.brex_accounts, api_error: nil,
                                               account_type_options: flow.account_type_options,
                                               displayable_account_type_options: flow.displayable_account_type_options,
                                               subtype_options: flow.subtype_options })

    assert_includes html, item.brex_accounts.first.name
    assert_includes html, "/brex_items/#{item.id}/complete_account_setup"
    assert_includes html, %(<option selected="selected" value="skip">)
  end

  # The messages the kit's view components read under <key>_items; %s is the
  # provider key. Rendering covers the common branches, this list every branch.
  KIT_VIEW_KEYS = %w[
    %s_item.delete %s_item.deletion_in_progress %s_item.error %s_item.no_accounts_description
    %s_item.no_accounts_title %s_item.setup_action %s_item.setup_description %s_item.setup_needed
    %s_item.status %s_item.status_never %s_item.status_with_summary %s_item.syncing
    provider_panel.add_connection provider_panel.connection_name_label provider_panel.connection_name_placeholder
    provider_panel.disconnect provider_panel.disconnect_confirm provider_panel.disconnect_label
    provider_panel.setup_accounts provider_panel.sync provider_panel.update_connection
    select_accounts.title select_accounts.description select_accounts.no_name_placeholder
    select_accounts.configure_name_in_%s select_accounts.cancel select_accounts.link_accounts
    select_existing_account.title select_existing_account.description select_existing_account.no_name_placeholder
    select_existing_account.configure_name_in_%s select_existing_account.cancel select_existing_account.link_account
    api_error.title api_error.heading api_error.common_issues api_error.invalid_token_label api_error.invalid_token
    api_error.expired_credentials_label api_error.expired_credentials api_error.permissions_label api_error.permissions
    api_error.network_label api_error.network api_error.service_label api_error.service api_error.settings_link
    setup_required.title setup_required.heading setup_required.description setup_required.setup_steps
    setup_required.steps.open_settings_html setup_required.steps.find_section_html setup_required.steps.enter_token
    setup_required.steps.return_to_link setup_required.settings_link
    setup_accounts.title setup_accounts.subtitle setup_accounts.creating_accounts setup_accounts.fetch_failed
    setup_accounts.no_accounts_to_setup setup_accounts.all_accounts_linked setup_accounts.choose_account_type
    setup_accounts.account_type_label setup_accounts.create_accounts setup_accounts.cancel
    subtype_select.placeholder.subtype subtype_select.placeholder.type
  ].freeze

  test "the generated locale has every message the provider kit's views read" do
    shape = ->(value) { value.is_a?(Hash) ? value.keys.map(&:to_s).sort : value.to_s.scan(/%\{(\w+)\}/).flatten.sort }

    [ true, false ].each do |banking|
      messages = YAML.safe_load(render_provider_template("locale.en.yml.tt", banking: banking)).dig("en", "gocardless_items")

      KIT_VIEW_KEYS.each do |key|
        generated = messages.dig(*format(key, "gocardless").split("."))
        assert generated, "banking: #{banking}: no gocardless_items.#{format(key, 'gocardless')}"
        assert_equal shape.call(I18n.t("brex_items.#{format(key, 'brex')}", locale: :en)), shape.call(generated), "banking: #{banking}: #{key}"
      end
    end
  end

  test "the generator writes the kit's views and helper, and the panel's with --skip-view" do
    { false => 9, true => 2 }.each do |skip_view, count|
      Dir.mktmpdir do |dir|
        generator = Provider::FamilyGenerator.new([ "gocardless" ], { skip_view: skip_view }, destination_root: dir)
        capture_io { Dir.chdir(dir) { generator.create_panel_view && generator.create_item_views } }
        written = Dir.glob("**/*", base: dir).select { |path| File.file?(File.join(dir, path)) }

        assert_equal count, written.size, "skip_view: #{skip_view}: #{written.sort}"
        assert_includes written, "app/views/gocardless_items/_credential_fields.html.erb"
        assert_includes written, "app/helpers/gocardless_items_helper.rb" unless skip_view
      end
    end
  end
end
