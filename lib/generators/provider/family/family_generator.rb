require "rails/generators"
require "rails/generators/active_record"

# Generator for creating per-family provider integrations
#
# Usage:
#   rails g provider:family NAME field:type:secret field:type ... [--type=banking|investment]
#
# Examples:
#   rails g provider:family lunchflow api_key:text:secret base_url:string --type=banking
#   rails g provider:family my_broker access_token:text:secret --type=investment
#
# Field format:
#   name:type[:secret]
#   - name: Field name (e.g., api_key)
#   - type: Database column type (text, string, integer, boolean)
#   - secret: Optional flag indicating this field should be encrypted
#
# Provider type:
#   --type=banking    - For bank/credit card providers (transactions only, no holdings/activities)
#   --type=investment - For brokerage providers (holdings + activities) [default]
#
# This generates:
#   - Migration creating complete provider_items and provider_accounts tables
#   - Models for items, accounts, and provided concern
#   - Adapter class
#   - Manual panel view for provider settings
#   - Simple controller for CRUD operations
#   - Routes
class Provider::FamilyGenerator < Rails::Generators::NamedBase
  include Rails::Generators::Migration

  source_root File.expand_path("templates", __dir__)

  argument :fields, type: :array, default: [], banner: "field:type[:secret] field:type[:secret]"

  class_option :skip_migration, type: :boolean, default: false, desc: "Skip generating migration"
  class_option :skip_routes, type: :boolean, default: false, desc: "Skip adding routes"
  class_option :skip_view, type: :boolean, default: false, desc: "Skip generating view"
  class_option :skip_controller, type: :boolean, default: false, desc: "Skip generating controller"
  class_option :skip_adapter, type: :boolean, default: false, desc: "Skip generating adapter"
  class_option :type, type: :string, default: "investment",
               enum: %w[banking investment],
               desc: "Provider type: banking (transactions only) or investment (holdings + activities)"

  def validate_fields
    if parsed_fields.empty?
      say "Warning: No fields specified. You'll need to add them manually later.", :yellow
    end

    # Validate field types
    parsed_fields.each do |field|
      unless %w[text string integer boolean].include?(field[:type])
        raise Thor::Error, "Invalid field type '#{field[:type]}' for #{field[:name]}. Must be one of: text, string, integer, boolean"
      end
    end
  end

  def generate_migration
    return if options[:skip_migration]

    migration_template "migration.rb.tt",
                       "db/migrate/create_#{table_name}_and_accounts.rb",
                       migration_version: migration_version
  end

  def create_adapter
    return if options[:skip_adapter]

    adapter_path = "app/models/provider/#{file_name}_adapter.rb"

    if File.exist?(adapter_path)
      say "Adapter already exists: #{adapter_path}", :skip
    else
      # Create new adapter
      template "adapter.rb.tt", adapter_path
      say "Created new adapter: #{adapter_path}", :green
    end
  end

  def create_models
    # Create item model
    item_model_path = "app/models/#{file_name}_item.rb"
    if File.exist?(item_model_path)
      say "Item model already exists: #{item_model_path}", :skip
    else
      template "item_model.rb.tt", item_model_path
      say "Created item model: #{item_model_path}", :green
    end

    # Create account model
    account_model_path = "app/models/#{file_name}_account.rb"
    if File.exist?(account_model_path)
      say "Account model already exists: #{account_model_path}", :skip
    else
      template "account_model.rb.tt", account_model_path
      say "Created account model: #{account_model_path}", :green
    end

    # Create item subdirectory models/concerns
    create_item_concerns

    # Create account subdirectory models/concerns
    create_account_concerns

    # Create Family Connectable concern
    connectable_concern_path = "app/models/family/#{file_name}_connectable.rb"
    if File.exist?(connectable_concern_path)
      say "Connectable concern already exists: #{connectable_concern_path}", :skip
    else
      template "connectable_concern.rb.tt", connectable_concern_path
      say "Created Connectable concern: #{connectable_concern_path}", :green
    end
  end

  def create_provider_sdk
    return if options[:skip_adapter]

    sdk_path = "app/models/provider/#{file_name}.rb"
    if File.exist?(sdk_path)
      say "Provider SDK already exists: #{sdk_path}", :skip
    else
      template "provider_sdk.rb.tt", sdk_path
      say "Created Provider SDK: #{sdk_path}", :green
    end
  end

  def create_background_jobs
    # Activities fetch job (investment providers only)
    if investment_provider?
      activities_job_path = "app/jobs/#{file_name}_activities_fetch_job.rb"
      if File.exist?(activities_job_path)
        say "Activities fetch job already exists: #{activities_job_path}", :skip
      else
        template "activities_fetch_job.rb.tt", activities_job_path
        say "Created Activities fetch job: #{activities_job_path}", :green
      end
    end

    # Connection cleanup job (both types may need cleanup on unlink)
    cleanup_job_path = "app/jobs/#{file_name}_connection_cleanup_job.rb"
    if File.exist?(cleanup_job_path)
      say "Connection cleanup job already exists: #{cleanup_job_path}", :skip
    else
      template "connection_cleanup_job.rb.tt", cleanup_job_path
      say "Created Connection cleanup job: #{cleanup_job_path}", :green
    end
  end

  def create_tests
    # Create test directory
    test_dir = "test/models/#{file_name}_account"
    FileUtils.mkdir_p(test_dir) unless options[:pretend]

    # DataHelpers test
    data_helpers_test_path = "#{test_dir}/data_helpers_test.rb"
    if File.exist?(data_helpers_test_path)
      say "DataHelpers test already exists: #{data_helpers_test_path}", :skip
    else
      template "data_helpers_test.rb.tt", data_helpers_test_path
      say "Created DataHelpers test: #{data_helpers_test_path}", :green
    end

    # Processor test
    processor_test_path = "#{test_dir}/processor_test.rb"
    if File.exist?(processor_test_path)
      say "Processor test already exists: #{processor_test_path}", :skip
    else
      template "processor_test.rb.tt", processor_test_path
      say "Created Processor test: #{processor_test_path}", :green
    end
  end

  def update_family_model
    family_model_path = "app/models/family.rb"
    return unless File.exist?(family_model_path)

    content = File.read(family_model_path)
    connectable_module = "#{class_name}Connectable"

    # Check if already included
    if content.include?(connectable_module)
      say "Family model already includes #{connectable_module}", :skip
    else
      # Insert a new include line after the class declaration
      # This approach is more robust than trying to append to an existing include line
      lines = content.lines
      class_line_index = nil

      lines.each_with_index do |line, index|
        if line =~ /^\s*class\s+Family\s*<\s*ApplicationRecord/
          class_line_index = index
          break
        end
      end

      if class_line_index
        # Find the indentation used in the file (check next non-empty line)
        indentation = "  " # default
        ((class_line_index + 1)...lines.length).each do |i|
          if lines[i] =~ /^(\s+)\S/
            indentation = ::Regexp.last_match(1)
            break
          end
        end

        # Insert include line right after the class declaration
        new_include_line = "#{indentation}include #{connectable_module}\n"
        lines.insert(class_line_index + 1, new_include_line)

        write_file(family_model_path, lines.join)
        say "Added #{connectable_module} to Family model", :green
      else
        say "Could not find class declaration in Family model, please add manually: include #{connectable_module}", :yellow
      end
    end
  end

  def create_panel_view
    return if options[:skip_view]

    # Create a simple manual panel view
    template "panel.html.erb.tt",
             "app/views/settings/providers/_#{file_name}_panel.html.erb"
  end

  def create_item_views
    return if options[:skip_view]

    # Create views directory
    view_dir = "app/views/#{file_name}_items"
    FileUtils.mkdir_p(view_dir) unless options[:pretend]

    # Setup accounts dialog
    setup_accounts_path = "#{view_dir}/setup_accounts.html.erb"
    if File.exist?(setup_accounts_path)
      say "Setup accounts view already exists: #{setup_accounts_path}", :skip
    else
      template "setup_accounts.html.erb.tt", setup_accounts_path
      say "Created setup_accounts view: #{setup_accounts_path}", :green
    end

    # Select existing account dialog
    select_existing_path = "#{view_dir}/select_existing_account.html.erb"
    if File.exist?(select_existing_path)
      say "Select existing account view already exists: #{select_existing_path}", :skip
    else
      template "select_existing_account.html.erb.tt", select_existing_path
      say "Created select_existing_account view: #{select_existing_path}", :green
    end

    # Item partial for accounts index
    item_partial_path = "#{view_dir}/_#{file_name}_item.html.erb"
    if File.exist?(item_partial_path)
      say "Item partial already exists: #{item_partial_path}", :skip
    else
      template "item_partial.html.erb.tt", item_partial_path
      say "Created item partial: #{item_partial_path}", :green
    end
  end

  def create_controller
    return if options[:skip_controller]

    controller_path = "app/controllers/#{file_name}_items_controller.rb"

    if File.exist?(controller_path)
      say "Controller already exists: #{controller_path}", :skip
    else
      # Create new controller
      template "controller.rb.tt", controller_path
      say "Created new controller: #{controller_path}", :green
    end
  end

  def add_routes
    return if options[:skip_routes]

    route_content = <<~RUBY.strip
          resources :#{file_name}_items, only: [:index, :new, :create, :show, :edit, :update, :destroy] do
            collection do
              get :preload_accounts
              get :select_accounts
              post :link_accounts
              get :select_existing_account
              post :link_existing_account
            end

            member do
              post :sync
              get :setup_accounts
              post :complete_account_setup
            end
          end
        RUBY

    # Check if routes already exist
    routes_file = "config/routes.rb"
    if File.read(routes_file).include?("resources :#{file_name}_items")
      say "Routes already exist for :#{file_name}_items", :skip
    else
      route route_content
      say "Added routes for :#{file_name}_items", :green
    end
  end

  def update_settings_controller
    controller_path = "app/controllers/settings/providers_controller.rb"
    return unless File.exist?(controller_path)

    content = File.read(controller_path)
    new_condition = "config.provider_key.to_s.casecmp(\"#{file_name}\").zero?"

    # Check if provider is already excluded
    if content.include?(new_condition)
      say "Settings controller already excludes #{file_name}", :skip
      return
    end

    # Add to the rejection list in prepare_show_context
    # Look for the end of the reject block and insert before it
    if content.include?("reject do |config|")
      # Find the reject block's end and insert our condition before it
      # The block ends with "end" on its own line after the conditions
      lines = content.lines
      reject_block_start = nil
      reject_block_end = nil

      lines.each_with_index do |line, index|
        if line.include?("Provider::ConfigurationRegistry.all.reject do |config|")
          reject_block_start = index
        elsif reject_block_start && line.strip == "end" && reject_block_end.nil?
          reject_block_end = index
          break
        end
      end

      if reject_block_start && reject_block_end
        # Find the last condition line (the one before 'end')
        last_condition_index = reject_block_end - 1

        # Get indentation from the last condition line
        last_condition_line = lines[last_condition_index]
        indentation = last_condition_line[/^\s*/]

        # Append our condition with || to the last condition line
        # Remove trailing whitespace/newline, add || and new condition
        lines[last_condition_index] = last_condition_line.rstrip + " || \\\n#{indentation}#{new_condition}\n"

        write_file(controller_path, lines.join)
        say "Added #{file_name} to provider exclusion list", :green
      else
        say "Could not find reject block boundaries in settings controller", :yellow
      end
    elsif content.include?("@provider_configurations = Provider::ConfigurationRegistry.all")
      # No reject block exists yet, create one
      gsub_file controller_path,
                "@provider_configurations = Provider::ConfigurationRegistry.all\n",
                "@provider_configurations = Provider::ConfigurationRegistry.all.reject do |config|\n        #{new_condition}\n      end\n"
      say "Created provider exclusion block with #{file_name}", :green
    else
      say "Could not find provider_configurations assignment in settings controller", :yellow
    end

    # Re-read content after potential modifications
    content = File.read(controller_path)

    # Add instance variable for items
    items_var = "@#{file_name}_items"
    unless content.include?(items_var)
      # Find the last @*_items assignment line and insert after it
      lines = content.lines
      last_items_index = nil

      lines.each_with_index do |line, index|
        if line =~ /@\w+_items = Current\.family\.\w+_items/
          last_items_index = index
        end
      end

      if last_items_index
        # Get indentation from the found line
        indentation = lines[last_items_index][/^\s*/]
        new_line = "#{indentation}#{items_var} = Current.family.#{file_name}_items.ordered.select(:id)\n"
        lines.insert(last_items_index + 1, new_line)
        write_file(controller_path, lines.join)
        say "Added #{items_var} instance variable", :green
      else
        say "Could not find existing @*_items assignments, please add manually: #{items_var} = Current.family.#{file_name}_items.ordered.select(:id)", :yellow
      end
    end
  end

  def update_providers_view
    return if options[:skip_view]

    view_path = "app/views/settings/providers/show.html.erb"
    return unless File.exist?(view_path)

    content = File.read(view_path)

    # Check if section already exists
    if content.include?("\"#{file_name}-providers-panel\"")
      say "Providers view already has #{class_name} section", :skip
    else
      # Add section before the last closing div (at end of file)
      section_content = <<~ERB

  <%= settings_section title: "#{class_name}", collapsible: true, open: false do %>
    <turbo-frame id="#{file_name}-providers-panel">
      <%= render "settings/providers/#{file_name}_panel" %>
    </turbo-frame>
  <% end %>
      ERB

      # Insert before the final </div> at the end of file
      insert_into_file view_path, section_content, before: /^<\/div>\s*\z/
      say "Added #{class_name} section to providers view", :green
    end
  end

  def update_accounts_controller
    controller_path = "app/controllers/accounts_controller.rb"
    return unless File.exist?(controller_path)

    content = File.read(controller_path)
    items_var = "@#{file_name}_items"

    # Check if already added
    if content.include?(items_var)
      say "Accounts controller already has #{items_var}", :skip
      return
    end

    # Add to index action - find the last @*_items line and insert after it
    lines = content.lines
    last_items_index = nil
    lines.each_with_index do |line, index|
      if line =~ /@\w+_items = family\.\w+_items\.ordered/
        last_items_index = index
      end
    end

    if last_items_index
      indentation = lines[last_items_index][/^\s*/]
      new_line = "#{indentation}#{items_var} = family.#{file_name}_items.ordered.includes(:syncs, :#{file_name}_accounts)\n"
      lines.insert(last_items_index + 1, new_line)
      write_file(controller_path, lines.join)
      say "Added #{items_var} to accounts controller index", :green
    else
      say "Could not find @*_items assignments in accounts controller", :yellow
    end

    # Add sync stats map
    add_accounts_controller_sync_stats_map(controller_path)
  end

  def update_accounts_index_view
    view_path = "app/views/accounts/index.html.erb"
    return unless File.exist?(view_path)

    content = File.read(view_path)
    items_var = "@#{file_name}_items"

    if content.include?(items_var)
      say "Accounts index view already has #{class_name} section", :skip
      return
    end

    # Add to empty check - find the existing pattern and append our check
    content = content.gsub(
      /@coinstats_items\.empty\? %>/,
      "@coinstats_items.empty? && #{items_var}.empty? %>"
    )

    # Add provider section before manual_accounts
    section = <<~ERB

    <% if #{items_var}.any? %>
      <%= render #{items_var}.sort_by(&:created_at) %>
    <% end %>

    ERB

    content = content.gsub(
      /<% if @manual_accounts\.any\? %>/,
      "#{section.strip}\n\n    <% if @manual_accounts.any? %>"
    )

    write_file(view_path, content)
    say "Added #{class_name} section to accounts index view", :green
  end

  def create_locale_file
    locale_dir = "config/locales/views/#{file_name}_items"
    locale_path = "#{locale_dir}/en.yml"

    if File.exist?(locale_path)
      say "Locale file already exists: #{locale_path}", :skip
      return
    end

    FileUtils.mkdir_p(locale_dir) unless options[:pretend]
    template "locale.en.yml.tt", locale_path
    say "Created locale file: #{locale_path}", :green
  end

  def update_source_enums
    # Add the new provider to the source enum in ProviderMerchant and DataEnrichment
    # These enums track which provider created a merchant or enrichment record
    update_source_enum("app/models/provider_merchant.rb")
    update_source_enum("app/models/data_enrichment.rb")
  end

  def show_summary
    say "\n" + "=" * 80, :green
    say "Successfully generated per-family #{options[:type]} provider: #{class_name}", :green
    say "=" * 80, :green

    say "\nGenerated files:", :cyan
    say "  📋 Migration: db/migrate/xxx_create_#{table_name}_and_accounts.rb"
    say "  📦 Models:"
    say "     - app/models/#{file_name}_item.rb"
    say "     - app/models/#{file_name}_account.rb"
    say "     - app/models/#{file_name}_item/provided.rb"
    say "     - app/models/#{file_name}_item/unlinking.rb"
    say "     - app/models/#{file_name}_item/syncer.rb"
    say "     - app/models/#{file_name}_item/importer.rb"
    say "     - app/models/#{file_name}_account/data_helpers.rb"
    say "     - app/models/#{file_name}_account/processor.rb"
    if investment_provider?
      say "     - app/models/#{file_name}_account/holdings_processor.rb"
      say "     - app/models/#{file_name}_account/activities_processor.rb"
    end
    if banking_provider?
      say "     - app/models/#{file_name}_account/transactions/processor.rb"
    end
    say "     - app/models/family/#{file_name}_connectable.rb"
    say "  🔌 Provider:"
    say "     - app/models/provider/#{file_name}.rb (SDK wrapper)"
    say "     - app/models/provider/#{file_name}_adapter.rb"
    say "  🎮 Controller: app/controllers/#{file_name}_items_controller.rb"
    say "  🖼️  Views:"
    say "     - app/views/settings/providers/_#{file_name}_panel.html.erb"
    say "     - app/views/#{file_name}_items/setup_accounts.html.erb"
    say "     - app/views/#{file_name}_items/select_existing_account.html.erb"
    say "     - app/views/#{file_name}_items/_#{file_name}_item.html.erb"
    say "  ⚡ Jobs:"
    if investment_provider?
      say "     - app/jobs/#{file_name}_activities_fetch_job.rb"
    end
    say "     - app/jobs/#{file_name}_connection_cleanup_job.rb"
    say "  🧪 Tests:"
    say "     - test/models/#{file_name}_account/data_helpers_test.rb"
    say "     - test/models/#{file_name}_account/processor_test.rb"
    say "  🛣️  Routes: Updated config/routes.rb"
    say "  🌐 Locale: config/locales/views/#{file_name}_items/en.yml"
    say "  ⚙️  Settings: Updated controllers, views, and Family model"

    if parsed_fields.any?
      say "\nCredential fields:", :cyan
      parsed_fields.each do |field|
        secret_flag = field[:secret] ? " (encrypted)" : ""
        default_flag = field[:default] ? " [default: #{field[:default]}]" : ""
        say "  - #{field[:name]}: #{field[:type]}#{secret_flag}#{default_flag}"
      end
    end

    say "\nDatabase tables created:", :cyan
    say "  - #{table_name} (stores per-family credentials)"
    if investment_provider?
      say "  - #{file_name}_accounts (stores individual account data with holdings/activities support)"
    else
      say "  - #{file_name}_accounts (stores individual account data with transactions support)"
    end

    say "\nNext steps:", :yellow
    say "  1. Run migrations:"
    say "     rails db:migrate"
    say ""
    say "  2. Implement the provider SDK in:"
    say "     app/models/provider/#{file_name}.rb"
    say "     - Add API client initialization"
    if investment_provider?
      say "     - Implement list_accounts, get_holdings, get_activities methods"
    else
      say "     - Implement list_accounts, get_transactions methods"
    end
    say ""
    say "  3. Customize the Importer class:"
    say "     app/models/#{file_name}_item/importer.rb"
    say "     - Map API response fields to account fields"
    say ""
    say "  4. Customize the Processors:"
    if investment_provider?
      say "     app/models/#{file_name}_account/holdings_processor.rb"
      say "     app/models/#{file_name}_account/activities_processor.rb"
      say "     - Map provider field names to Sure fields"
      say "     - Customize activity type mappings"
    else
      say "     app/models/#{file_name}_account/transactions/processor.rb"
      say "     - Map provider transaction format to Sure entries"
    end
    say ""
    say "  5. Test the integration:"
    say "     Visit /settings/providers and configure credentials"
    say ""
    say "  📚 See docs/PER_FAMILY_PROVIDER_GUIDE.md for detailed documentation"
  end

  # Required for Rails::Generators::Migration
  def self.next_migration_number(dirname)
    ActiveRecord::Generators::Base.next_migration_number(dirname)
  end

  private

    def update_source_enum(model_path)
      return unless File.exist?(model_path)

      content = File.read(model_path)
      model_name = File.basename(model_path, ".rb").camelize

      # Check if provider is already in the enum
      if content.include?("#{file_name}: \"#{file_name}\"")
        say "#{model_name} source enum already includes #{file_name}", :skip
        return
      end

      # Find the enum :source line and add the new provider
      # Pattern: enum :source, { key: "value", ... }
      if content =~ /(enum :source, \{[^}]+)(})/
        # Insert the new provider before the closing brace
        updated_content = content.sub(
          /(enum :source, \{[^}]+)(})/,
          "\\1, #{file_name}: \"#{file_name}\"\\2"
        )
        write_file(model_path, updated_content)
        say "Added #{file_name} to #{model_name} source enum", :green
      else
        say "Could not find source enum in #{model_name}", :yellow
      end
    end

    def add_accounts_controller_sync_stats_map(controller_path)
      content = File.read(controller_path)
      stats_var = "@#{file_name}_sync_stats_map"

      if content.include?(stats_var)
        say "Accounts controller already has #{stats_var}", :skip
        return
      end

      # Find the build_sync_stats_maps method and add our stats map before the closing 'end'
      sync_stats_block = <<~RUBY

      # #{class_name} sync stats
      #{stats_var} = {}
      @#{file_name}_items.each do |item|
        latest_sync = item.syncs.ordered.first
        #{stats_var}[item.id] = latest_sync&.sync_stats || {}
      end
      RUBY

      lines = content.lines
      method_start = nil
      method_end = nil
      indent_level = 0

      lines.each_with_index do |line, index|
        if line.include?("def build_sync_stats_maps")
          method_start = index
          indent_level = line[/^\s*/].length
        elsif method_start && line =~ /^#{' ' * indent_level}end\s*$/
          method_end = index
          break
        end
      end

      if method_end
        lines.insert(method_end, sync_stats_block)
        write_file(controller_path, lines.join)
        say "Added #{stats_var} to build_sync_stats_maps", :green
      else
        say "Could not find build_sync_stats_maps method end", :yellow
      end
    end

    def create_item_concerns
      # Create item subdirectory
      item_dir = "app/models/#{file_name}_item"
      FileUtils.mkdir_p(item_dir) unless options[:pretend]

      # Provided concern
      provided_concern_path = "#{item_dir}/provided.rb"
      if File.exist?(provided_concern_path)
        say "Provided concern already exists: #{provided_concern_path}", :skip
      else
        template "provided_concern.rb.tt", provided_concern_path
        say "Created Provided concern: #{provided_concern_path}", :green
      end

      # Unlinking concern
      unlinking_concern_path = "#{item_dir}/unlinking.rb"
      if File.exist?(unlinking_concern_path)
        say "Unlinking concern already exists: #{unlinking_concern_path}", :skip
      else
        template "unlinking_concern.rb.tt", unlinking_concern_path
        say "Created Unlinking concern: #{unlinking_concern_path}", :green
      end

      # Syncer class
      syncer_path = "#{item_dir}/syncer.rb"
      if File.exist?(syncer_path)
        say "Syncer class already exists: #{syncer_path}", :skip
      else
        template "syncer.rb.tt", syncer_path
        say "Created Syncer class: #{syncer_path}", :green
      end

      # Importer class
      importer_path = "#{item_dir}/importer.rb"
      if File.exist?(importer_path)
        say "Importer class already exists: #{importer_path}", :skip
      else
        template "importer.rb.tt", importer_path
        say "Created Importer class: #{importer_path}", :green
      end
    end

    def create_account_concerns
      # Create account subdirectory
      account_dir = "app/models/#{file_name}_account"
      FileUtils.mkdir_p(account_dir) unless options[:pretend]

      # DataHelpers concern (both types benefit from parse_decimal, parse_date, extract_currency)
      data_helpers_path = "#{account_dir}/data_helpers.rb"
      if File.exist?(data_helpers_path)
        say "DataHelpers concern already exists: #{data_helpers_path}", :skip
      else
        template "data_helpers.rb.tt", data_helpers_path
        say "Created DataHelpers concern: #{data_helpers_path}", :green
      end

      # Processor class
      processor_path = "#{account_dir}/processor.rb"
      if File.exist?(processor_path)
        say "Processor class already exists: #{processor_path}", :skip
      else
        template "account_processor.rb.tt", processor_path
        say "Created Processor class: #{processor_path}", :green
      end

      if investment_provider?
        # HoldingsProcessor class (investment only)
        holdings_processor_path = "#{account_dir}/holdings_processor.rb"
        if File.exist?(holdings_processor_path)
          say "HoldingsProcessor class already exists: #{holdings_processor_path}", :skip
        else
          template "holdings_processor.rb.tt", holdings_processor_path
          say "Created HoldingsProcessor class: #{holdings_processor_path}", :green
        end

        # ActivitiesProcessor class (investment only)
        activities_processor_path = "#{account_dir}/activities_processor.rb"
        if File.exist?(activities_processor_path)
          say "ActivitiesProcessor class already exists: #{activities_processor_path}", :skip
        else
          template "activities_processor.rb.tt", activities_processor_path
          say "Created ActivitiesProcessor class: #{activities_processor_path}", :green
        end
      end

      if banking_provider?
        # TransactionsProcessor class (banking only)
        transactions_dir = "#{account_dir}/transactions"
        FileUtils.mkdir_p(transactions_dir) unless options[:pretend]

        transactions_processor_path = "#{transactions_dir}/processor.rb"
        if File.exist?(transactions_processor_path)
          say "TransactionsProcessor class already exists: #{transactions_processor_path}", :skip
        else
          template "transactions_processor.rb.tt", transactions_processor_path
          say "Created TransactionsProcessor class: #{transactions_processor_path}", :green
        end
      end
    end

    # Helper to write files while respecting --pretend flag
    def write_file(path, content)
      if options[:pretend]
        say "Would modify: #{path}", :yellow
        return
      end
      File.write(path, content)
    end

    def table_name
      "#{file_name}_items"
    end

    def migration_version
      "[#{Rails::VERSION::MAJOR}.#{Rails::VERSION::MINOR}]"
    end

    def banking_provider?
      options[:type] == "banking"
    end

    def investment_provider?
      options[:type] == "investment"
    end

    def parsed_fields
      @parsed_fields ||= fields.map do |field_def|
        # Handle default values with colons (like URLs) by extracting them first
        # Format: field:type[:secret][:default=value]
        default_match = field_def.match(/default=(.+)$/)
        default_value = nil
        if default_match
          default_value = default_match[1]
          # Remove the default part for further parsing
          field_def = field_def.sub(/:?default=.+$/, "")
        end

        parts = field_def.split(":")
        field = {
          name: parts[0],
          type: parts[1] || "string",
          secret: parts.include?("secret"),
          default: default_value
        }

        field
      end
    end
end
