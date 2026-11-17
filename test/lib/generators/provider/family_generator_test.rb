require "test_helper"
require "generators/provider/family/family_generator"

# Covers the source-enum insertion, which historically emitted invalid Ruby. The failure
# mode is nasty: the generator reports success, and the damage surfaces later as a
# SyntaxError in data_enrichment.rb with nothing pointing back at the generator. So each
# case asserts the result actually PARSES, not just that it looks right.
class Provider::FamilyGeneratorTest < ActiveSupport::TestCase
  module GeneratedControllers
  end

  # Holds each evaluated importer template, apart from the app's own constants.
  module GeneratedImporters
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

  # A template rendered as the generator renders it, with the generator's predicate
  # helpers, which a Struct cannot name.
  def render_provider_template(name, banking: true, parsed_fields: [ { name: "api_key", type: "string", secret: true, default: nil } ], **extra_helpers)
    helpers = {
      class_name: "Gocardless", file_name: "gocardless", parsed_fields: parsed_fields,
      banking_provider?: banking, investment_provider?: !banking
    }.merge(extra_helpers)
    context = Object.new
    helpers.each { |helper, value| context.define_singleton_method(helper) { value } }
    template = Rails.root.join("lib/generators/provider/family/templates", name).read
    ERB.new(template, trim_mode: "-").result(context.instance_eval { binding })
  end

  # Evaluates the importer template in its own module, with one linked account, and
  # returns what #import returns.
  def run_generated_importer(banking:)
    namespace = Module.new
    GeneratedImporters.const_set("Run#{GeneratedImporters.constants.size}", namespace)
    namespace.const_set(:GocardlessItem, Class.new)
    namespace.const_set(:GocardlessAccount, Module.new)
    namespace::GocardlessAccount.const_set(:DataHelpers, Module.new)
    namespace.module_eval(render_provider_template("importer.rb.tt", banking: banking))

    linked_account = OpenStruct.new(id: "account-1", sync_start_date: nil, last_activities_sync: 1.day.ago, raw_transactions_payload: [], raw_activities_payload: [])
    relation = mock("linked_accounts")
    relation.stubs(:joins).returns(relation)
    relation.stubs(:count).returns(1)
    relation.stubs(:each).yields(linked_account)
    namespace::GocardlessAccount.stubs(:where).returns(relation)

    item = mock("item")
    item.stubs(id: "item-1", gocardless_credentials: { api_key: "key" }, upsert_gocardless_snapshot!: true, last_synced_at: nil)
    item.stubs(:gocardless_accounts).returns(stub(where: stub(not: [])))

    importer = namespace::GocardlessItem::Importer.new(item, gocardless_provider: Object.new)
    yield importer if block_given?
    importer.import
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

  # A blank name from a form must fall back to the default, as Brex, Lunch Flow
  # and Mercury do: an empty string fails the item's name presence validation.
  test "the generated connectable concern defaults a blank connection name" do
    namespace = Module.new
    GeneratedImporters.const_set("Run#{GeneratedImporters.constants.size}", namespace)
    namespace.const_set(:Family, Module.new)
    namespace.module_eval(render_provider_template("connectable_concern.rb.tt"))

    family_class = Class.new do
      def self.has_many(*) = nil
      attr_accessor :gocardless_items
    end
    family_class.include(namespace::Family::GocardlessConnectable)
    family = family_class.new

    [ nil, "" ].each do |blank|
      item = mock("item")
      item.expects(:sync_later)
      family.gocardless_items = mock("items")
      family.gocardless_items.expects(:create!).with(name: "Gocardless Connection", api_key: "key").returns(item)

      assert_same item, family.create_gocardless_item!(api_key: "key", item_name: blank)
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

  # ProviderItem::AccountFlow plucks and indexes provider accounts by account_id,
  # as the Brex, Lunch Flow and Mercury tables name it.
  test "the generated migration stores the provider id in account_id" do
    [ true, false ].each do |banking|
      migration = render_provider_template("migration.rb.tt", banking: banking, table_name: "gocardless_items", migration_version: "[7.2]")
      model = render_provider_template("account_model.rb.tt", banking: banking)
      importer = render_provider_template("importer.rb.tt", banking: banking)

      assert_parses migration
      assert_includes migration, "      t.string :account_id\n"
      # Two connections may see the same provider account, so the id is unique
      # per item, as Brex and Mercury index it, not across the table.
      assert_includes migration, <<~RUBY.indent(4)
        add_index :gocardless_accounts,
                  [ :gocardless_item_id, :account_id ],
                  unique: true,
                  name: "index_gocardless_accounts_on_item_and_account_id"
      RUBY
      assert_no_match(/add_index :gocardless_accounts, :account_id/, migration)
      assert_match(/^      account_id: \(data\[:id\] \|\| data\[:account_id\]\)&\.to_s,$/, model)
      assert_includes importer, ".where.not(account_id: upstream_account_ids)"
      [ migration, model, importer ].each { |source| assert_not_includes source, "gocardless_account_id" }
    end
  end

  # Postgres caps an index name at 63 characters, and Rails raises on an explicit
  # name past that instead of shortening it as it does the names it derives.
  test "the generated migration names the item and account id index only when the name fits" do
    long_key = "a" * 26
    migration = render_provider_template("migration.rb.tt", file_name: long_key, table_name: "#{long_key}_items", migration_version: "[7.2]")

    assert_parses migration
    assert_includes migration, "[ :#{long_key}_item_id, :account_id ],\n              unique: true\n"
    assert_not_includes migration, "_on_item_and_account_id"

    fits = "a" * 25
    migration = render_provider_template("migration.rb.tt", file_name: fits, table_name: "#{fits}_items", migration_version: "[7.2]")
    name = migration[/name: "(index_a+_accounts_on_item_and_account_id)"/, 1]
    assert_equal 63, name.length
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
    {
      fetch_accounts: [],
      resolve_item: [ "item-id" ],
      provider_error_class: [],
      upsert_provider_account!: [ "acc_1", {} ],
      provider_account_snapshot_changed?: [ Object.new, {} ]
    }.each do |hook, args|
      assert_equal flow_class, flow_class.instance_method(hook).owner, "#{hook} is not stubbed"
      error = assert_raises(NotImplementedError, hook.to_s) { flow.send(hook, *args) }
      assert_includes error.message, "TODO: GocardlessItem::AccountFlow##{hook}", hook.to_s
    end
  ensure
    GeneratedFlows::GocardlessItem.send(:remove_const, :AccountFlow) if GeneratedFlows::GocardlessItem.const_defined?(:AccountFlow, false)
  end

  # ProviderItemsController#update asks the flow which params expire the cached
  # account list before saving, so this hook works without being filled in.
  test "the generated account flow expires the account cache on the declared fields" do
    flow_source = render_provider_template("account_flow.rb.tt", parsed_fields: [
      { name: "api_key", type: "string", secret: true, default: nil },
      { name: "base_url", type: "string", secret: false, default: "https://api.example.com" }
    ])
    assert_parses flow_source
    GeneratedFlows.module_eval(flow_source)
    flow_class = GeneratedFlows::GocardlessItem::AccountFlow

    assert_equal flow_class.singleton_class, flow_class.method(:cache_sensitive_params).owner
    assert_equal %i[api_key base_url], flow_class.cache_sensitive_params
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

  # ProviderItem::Syncer treats anything but a Hash with success: as a failed import,
  # so the generated importer has to return one, counting the failures it rescued.
  test "the generated importer's result reads as a clean or failed import to the kit syncer" do
    syncer = BrexItem::Syncer.new(brex_items(:one))

    [ true, false ].each do |banking|
      clean = run_generated_importer(banking: banking)
      assert_equal({ success: true, accounts_failed: 0, transactions_failed: 0 }, clean)
      assert_empty syncer.send(:import_result_errors, clean)
    end

    failed = run_generated_importer(banking: true) do |importer|
      importer.stubs(:calculate_transaction_start_date).raises(StandardError, "transactions unavailable")
    end
    assert_equal({ success: false, accounts_failed: 0, transactions_failed: 1 }, failed)
    assert_equal [ "transaction_import_error" ], syncer.send(:import_result_errors, failed).map { |error| error[:category] }

    failed = run_generated_importer(banking: false) do |importer|
      importer.stubs(:calculate_start_date).raises(StandardError, "activities unavailable")
    end
    assert_equal [ "transaction_import_error" ], syncer.send(:import_result_errors, failed).map { |error| error[:category] }
  end

  test "the summary gives the account flow its own step after the importer" do
    generator = Provider::FamilyGenerator.new([ "gocardless" ], {}, destination_root: Dir.tmpdir)
    summary = capture_io { generator.show_summary }.first
    importer_step = summary[/  3\. Customize the Importer class:.*?(?=\n\n)/m]

    assert_includes summary, "  4. Implement the account flow:\n     app/models/gocardless_item/account_flow.rb\n"
    assert_not_includes importer_step, "account_flow.rb"
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
    assert_includes card, '<%= render "accounts/index/account_groups", accounts: visible_accounts %>'
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

  # The generated panel counts only connections that have their secret, so the panel
  # list loads those rather than the default.
  test "the generated adapter's panel loads only connections that have their secret" do
    [ false, true ].each do |skip_view|
      assert_includes render_adapter(skip_view: skip_view),
                      %(lists: { settings_panel: ->(items) { items.where.not(api_key: [ nil, "" ]) } }\n), "skip_view: #{skip_view}"
    end

    access_token = render_adapter(skip_view: false, parsed_fields: [
      { name: "region", type: "string", secret: false, default: "eu" },
      { name: "access_token", type: "string", secret: true, default: nil }
    ])
    assert_includes access_token,
                    %(lists: { settings_panel: ->(items) { items.where.not(access_token: [ nil, "" ]) } }\n)
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

  test "the generated item card is plain ERB" do
    generated = render_template("item_partial.html.erb.tt", file_name: "gocardless")

    assert_plain_erb generated
    assert_equal "<%# locals: (gocardless_item:, visible_accounts:) %>\n", generated.lines.first
    assert_includes generated, "<%= tag.div id: dom_id(gocardless_item) do %>"
  end

  test "the generated item card renders sync frequency and the visible accounts it is given" do
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
    assert_includes after, I18n.t("sync_schedules.menu_item")
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
