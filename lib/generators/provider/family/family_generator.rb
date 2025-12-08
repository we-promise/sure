require "rails/generators"
require "rails/generators/active_record"

# Generator for creating per-family provider integrations
#
# Usage:
#   rails g provider:family NAME field:type:secret field:type ...
#
# Examples:
#   rails g provider:family lunchflow api_key:text:secret base_url:string
#   rails g provider:family my_bank access_token:text:secret refresh_token:text:secret
#
# Field format:
#   name:type[:secret]
#   - name: Field name (e.g., api_key)
#   - type: Database column type (text, string, integer, boolean)
#   - secret: Optional flag indicating this field should be encrypted
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

    # Create Provided concern
    provided_concern_path = "app/models/#{file_name}_item/provided.rb"
    if File.exist?(provided_concern_path)
      say "Provided concern already exists: #{provided_concern_path}", :skip
    else
      template "provided_concern.rb.tt", provided_concern_path
      say "Created Provided concern: #{provided_concern_path}", :green
    end

    # Create Unlinking concern
    unlinking_concern_path = "app/models/#{file_name}_item/unlinking.rb"
    if File.exist?(unlinking_concern_path)
      say "Unlinking concern already exists: #{unlinking_concern_path}", :skip
    else
      template "unlinking_concern.rb.tt", unlinking_concern_path
      say "Created Unlinking concern: #{unlinking_concern_path}", :green
    end

    # Create Family Connectable concern
    connectable_concern_path = "app/models/family/#{file_name}_connectable.rb"
    if File.exist?(connectable_concern_path)
      say "Connectable concern already exists: #{connectable_concern_path}", :skip
    else
      template "connectable_concern.rb.tt", connectable_concern_path
      say "Created Connectable concern: #{connectable_concern_path}", :green
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

        File.write(family_model_path, lines.join)
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

        File.write(controller_path, lines.join)
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
        File.write(controller_path, lines.join)
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

  <%%= settings_section title: "#{class_name}", collapsible: true, open: false do %>
    <turbo-frame id="#{file_name}-providers-panel">
      <%%= render "settings/providers/#{file_name}_panel" %>
    </turbo-frame>
  <%% end %>
      ERB

      # Insert before the final </div> at the end of file
      insert_into_file view_path, section_content, before: /^<\/div>\s*\z/
      say "Added #{class_name} section to providers view", :green
    end
  end

  def show_summary
    say "\n" + "=" * 80, :green
    say "Successfully generated per-family provider: #{class_name}", :green
    say "=" * 80, :green

    say "\nGenerated files:", :cyan
    say "  📋 Migration: db/migrate/xxx_create_#{table_name}_and_accounts.rb"
    say "  📦 Models:"
    say "     - app/models/#{file_name}_item.rb"
    say "     - app/models/#{file_name}_account.rb"
    say "     - app/models/#{file_name}_item/provided.rb"
    say "     - app/models/#{file_name}_item/unlinking.rb"
    say "     - app/models/family/#{file_name}_connectable.rb"
    say "  🔌 Adapter: app/models/provider/#{file_name}_adapter.rb"
    say "  🎮 Controller: app/controllers/#{file_name}_items_controller.rb"
    say "  🖼️  View: app/views/settings/providers/_#{file_name}_panel.html.erb"
    say "  🛣️  Routes: Updated config/routes.rb"
    say "  ⚙️  Settings: Updated controllers, views, and Family model"

    if parsed_fields.any?
      say "\nCredential fields:", :cyan
      parsed_fields.each do |field|
        secret_flag = field[:secret] ? " 🔒 (encrypted)" : ""
        default_flag = field[:default] ? " [default: #{field[:default]}]" : ""
        say "  - #{field[:name]}: #{field[:type]}#{secret_flag}#{default_flag}"
      end
    end

    say "\nDatabase tables created:", :cyan
    say "  - #{table_name} (stores per-family credentials)"
    say "  - #{file_name}_accounts (stores individual account data)"

    say "\nNext steps:", :yellow
    say "  1. Run migrations:"
    say "     rails db:migrate"
    say ""
    say "  2. Implement the provider SDK in:"
    say "     app/models/provider/#{file_name}.rb"
    say ""
    say "  3. Update #{class_name}Item::Provided concern:"
    say "     app/models/#{file_name}_item/provided.rb"
    say "     Implement the #{file_name}_provider method"
    say ""
    say "  4. Customize the adapter's build_provider method:"
    say "     app/models/provider/#{file_name}_adapter.rb"
    say ""
    say "  5. Add any custom business logic:"
    say "     - Import methods in #{class_name}Item"
    say "     - Processing logic for accounts"
    say "     - Sync strategies"
    say ""
    say "  6. Test the integration:"
    say "     Visit /settings/providers and configure credentials"
    say ""
    say "  📚 See docs/PER_FAMILY_PROVIDER_GUIDE.md for detailed documentation"
  end

  # Required for Rails::Generators::Migration
  def self.next_migration_number(dirname)
    ActiveRecord::Generators::Base.next_migration_number(dirname)
  end

  private

    def table_name
      "#{file_name}_items"
    end

    def migration_version
      "[#{Rails::VERSION::MAJOR}.#{Rails::VERSION::MINOR}]"
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
