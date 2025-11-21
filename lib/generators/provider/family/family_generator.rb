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
          resources :#{file_name}_items, only: [:create, :update, :destroy] do
            member do
              post :sync
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

    # Check if provider is already excluded
    if content.include?("config.provider_key.to_s.casecmp(\"#{file_name}\").zero?")
      say "Settings controller already excludes #{file_name}", :skip
    else
      # Add to the rejection list in prepare_show_context
      if content.include?("reject do |config|")
        # Add to existing reject block - find last .zero? and append new condition
        gsub_file controller_path,
                  /(config\.provider_key\.to_s\.casecmp\("[^"]+"\)\.zero\?)(\s*$)/,
                  "\\1 || \\\\\n        config.provider_key.to_s.casecmp(\"#{file_name}\").zero?\\2"
      else
        # Create new reject block
        gsub_file controller_path,
                  /@provider_configurations = Provider::ConfigurationRegistry\.all$/,
                  "@provider_configurations = Provider::ConfigurationRegistry.all.reject { |config| config.provider_key.to_s.casecmp(\"#{file_name}\").zero? }"
      end

      # Add instance variable for items - find last similar line and add after it
      if content =~ /@\w+_items = Current\.family\.\w+_items\.ordered\.select\(:id\)/
        insert_into_file controller_path,
                         after: /@\w+_items = Current\.family\.\w+_items\.ordered\.select\(:id\)\n/ do
          "      @#{file_name}_items = Current.family.#{file_name}_items.ordered.select(:id)\n"
        end
      else
        # Fallback: insert before end of prepare_show_context method
        insert_into_file controller_path,
                         before: /^    end\n  end\nend/ do
          "      @#{file_name}_items = Current.family.#{file_name}_items.ordered.select(:id)\n"
        end
      end

      say "Updated settings controller to exclude #{file_name} from global configs", :green
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

  <%= settings_section title: "#{class_name}" do %>
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
    say "  🔌 Adapter: app/models/provider/#{file_name}_adapter.rb"
    say "  🎮 Controller: app/controllers/#{file_name}_items_controller.rb"
    say "  🖼️  View: app/views/settings/providers/_#{file_name}_panel.html.erb"
    say "  🛣️  Routes: Updated config/routes.rb"
    say "  ⚙️  Settings: Updated controllers and views"

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
        parts = field_def.split(":")
        field = {
          name: parts[0],
          type: parts[1] || "string",
          secret: parts.include?("secret")
        }

        # Extract default value if present (format: field:type:default=value)
        parts.each do |part|
          if part.start_with?("default=")
            field[:default] = part.sub("default=", "")
          end
        end

        field
      end
    end
end
