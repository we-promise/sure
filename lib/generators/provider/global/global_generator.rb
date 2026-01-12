require "rails/generators"
require "rails/generators/active_record"

# Generator for creating global provider integrations
#
# Usage:
#   rails g provider:global NAME field:type[:secret] field:type ...
#
# Examples:
#   rails g provider:global plaid client_id:string:secret secret:string:secret environment:string
#   rails g provider:global openai api_key:string:secret model:string
#
# Field format:
#   name:type[:secret][:default=value]
#   - name: Field name (e.g., api_key)
#   - type: Database column type (text, string, integer, boolean)
#   - secret: Optional flag indicating this field should be masked in UI
#   - default: Optional default value (e.g., default=sandbox)
#
# This generates:
#   - Migration creating provider_items and provider_accounts tables (WITHOUT credential fields)
#   - Models for items, accounts, and provided concern
#   - Adapter class with Provider::Configurable (credentials stored globally in settings table)
#
# Key difference from provider:family:
#   - Credentials stored in `settings` table (global, shared by all families)
#   - Item/account tables store connections per family (but not credentials)
#   - No controller/view/routes needed (configuration via /settings/providers)
class Provider::GlobalGenerator < Rails::Generators::NamedBase
  include Rails::Generators::Migration

  source_root File.expand_path("templates", __dir__)

  argument :fields, type: :array, default: [], banner: "field:type[:secret][:default=value] field:type[:secret]"

  class_option :skip_migration, type: :boolean, default: false, desc: "Skip generating migration"
  class_option :skip_models, type: :boolean, default: false, desc: "Skip generating models"
  class_option :skip_adapter, type: :boolean, default: false, desc: "Skip generating adapter"

  def validate_fields
    if parsed_fields.empty?
      raise Thor::Error, "At least one credential field is required. Example: api_key:text:secret"
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

    migration_template "global_migration.rb.tt",
                       "db/migrate/create_#{table_name}_and_accounts.rb",
                       migration_version: migration_version
  end

  def create_models
    return if options[:skip_models]

    # Create item model
    item_model_path = "app/models/#{file_name}_item.rb"
    if File.exist?(item_model_path)
      say "Item model already exists: #{item_model_path}", :skip
    else
      template "global_item_model.rb.tt", item_model_path
      say "Created item model: #{item_model_path}", :green
    end

    # Create account model
    account_model_path = "app/models/#{file_name}_account.rb"
    if File.exist?(account_model_path)
      say "Account model already exists: #{account_model_path}", :skip
    else
      template "global_account_model.rb.tt", account_model_path
      say "Created account model: #{account_model_path}", :green
    end

    # Create Provided concern
    provided_concern_path = "app/models/#{file_name}_item/provided.rb"
    if File.exist?(provided_concern_path)
      say "Provided concern already exists: #{provided_concern_path}", :skip
    else
      template "global_provided_concern.rb.tt", provided_concern_path
      say "Created Provided concern: #{provided_concern_path}", :green
    end
  end

  def create_adapter
    return if options[:skip_adapter]

    adapter_path = "app/models/provider/#{file_name}_adapter.rb"

    if File.exist?(adapter_path)
      say "Adapter already exists: #{adapter_path}", :skip
    else
      template "global_adapter.rb.tt", adapter_path
      say "Created adapter: #{adapter_path}", :green
    end
  end

  def show_summary
    say "\n" + "=" * 80, :green
    say "Successfully generated global provider: #{class_name}", :green
    say "=" * 80, :green

    say "\nGenerated files:", :cyan
    say "  📋 Migration: db/migrate/xxx_create_#{table_name}_and_accounts.rb"
    say "  📦 Models:"
    say "     - app/models/#{file_name}_item.rb"
    say "     - app/models/#{file_name}_account.rb"
    say "     - app/models/#{file_name}_item/provided.rb"
    say "  🔌 Adapter: app/models/provider/#{file_name}_adapter.rb"

    if parsed_fields.any?
      say "\nGlobal credential fields (stored in settings table):", :cyan
      parsed_fields.each do |field|
        secret_flag = field[:secret] ? " 🔒 (secret, masked in UI)" : ""
        default_flag = field[:default] ? " [default: #{field[:default]}]" : ""
        env_flag = " [ENV: #{field[:env_key]}]"
        say "  - #{field[:name]}: #{field[:type]}#{secret_flag}#{default_flag}#{env_flag}"
      end
    end

    say "\nDatabase tables created:", :cyan
    say "  - #{table_name} (stores per-family connections, NO credentials)"
    say "  - #{file_name}_accounts (stores individual account data)"

    say "\n⚠️  Global Provider Pattern:", :yellow
    say "  - Credentials stored GLOBALLY in 'settings' table"
    say "  - All families share the same credentials"
    say "  - Configuration UI auto-generated at /settings/providers"
    say "  - Only available in self-hosted mode"

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
    say "  4. Customize the adapter:"
    say "     app/models/provider/#{file_name}_adapter.rb"
    say "     - Update configure block descriptions"
    say "     - Implement reload_configuration if needed"
    say "     - Implement build_provider method"
    say ""
    say "  5. Configure credentials:"
    say "     Visit /settings/providers (self-hosted mode only)"
    say "     Or set ENV variables:"
    parsed_fields.each do |field|
      say "       export #{field[:env_key]}=\"your_value\""
    end
    say ""
    say "  6. Add item creation flow:"
    say "     - Users connect their #{class_name} account"
    say "     - Creates #{class_name}Item with family association"
    say "     - Syncs accounts using global credentials"
    say ""
    say "  📚 See PROVIDER_ARCHITECTURE.md for global provider documentation"
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
        name = parts[0]
        type = parts[1] || "string"
        secret = parts.include?("secret")
        default = extract_default(parts)

        {
          name: name,
          type: type,
          secret: secret,
          default: default,
          env_key: "#{file_name.upcase}_#{name.upcase}"
        }
      end
    end

    def extract_default(parts)
      default_part = parts.find { |p| p.start_with?("default=") }
      default_part&.sub("default=", "")
    end

    def configure_block_content
      return "" if parsed_fields.empty?

      fields_code = parsed_fields.map do |field|
        field_attrs = [
          "label: \"#{field[:name].titleize}\"",
          ("required: true" if field[:secret]),
          ("secret: true" if field[:secret]),
          "env_key: \"#{field[:env_key]}\"",
          ("default: \"#{field[:default]}\"" if field[:default]),
          "description: \"Your #{class_name} #{field[:name].humanize.downcase}\""
        ].compact.join(",\n          ")

        "    field :#{field[:name]},\n          #{field_attrs}\n"
      end.join("\n")

      <<~RUBY

      configure do
        description <<~DESC
          Setup instructions for #{class_name}:
          1. Visit your #{class_name} dashboard to get your credentials
          2. Enter your credentials below
          3. These credentials will be used by all families (global configuration)

          **Note:** This is a global configuration for self-hosted mode only.
          In managed mode, credentials are configured by the platform operator.
        DESC

    #{fields_code}
      end

    RUBY
    end
end
