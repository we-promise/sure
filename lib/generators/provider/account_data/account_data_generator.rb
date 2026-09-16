require "rails/generators"

# Generates the provider-specific boundary only. Persistence, scheduling, account
# linking and presentation belong to the shared account-data runtime, not templates.
class Provider::AccountDataGenerator < Rails::Generators::NamedBase
  RESERVED_KEYS = %w[
    adapter definition page record registry normalization runtime_context syncer sync_execution
    application_credentials credential_store exchange_rate_resolver nonce_generator request_grant runtime_inputs request_inputs
    generation_accounts generation_account_index transaction_group transaction_sync pagination_restart_required legacy_writer_fence legacy_writer_guard legacy_access legacy_sync_request deferred_page
    migration_value migration_copier migration_preparation migration_cutover migration_retirement migration_source_selection migration_manifest migration_manifest_catalog migration_history_proof financial_identity_manifest identity_bootstrap_plan
    auxiliary_copier retained_row retained_owner retired_owner retained_account_index retained_account_binding retained_transactions
    error unsupported_capability not_implemented_error invalid_response stale_writer incomplete_page budget_exhausted
  ].freeze

  source_root File.expand_path("templates", __dir__)
  check_unknown_options!

  argument :fields, type: :array, default: [], banner: "field:type[:secret][:default=value] ..."

  class_option :type, type: :string, default: "banking", enum: %w[banking investment],
    desc: "Banking or investment capabilities"
  class_option :credential_scope, type: :string, default: "connection", enum: %w[connection application],
    desc: "Scope of the declared configuration fields"

  def validate_input
    unless %w[banking investment].include?(options[:type])
      raise Thor::Error, "Provider type must be banking or investment."
    end
    unless %w[connection application].include?(options[:credential_scope])
      raise Thor::Error, "Credential scope must be connection or application."
    end

    unless name.match?(/\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/) && name == file_name
      raise Thor::Error, "Use a snake_case provider key, for example acme_bank (no paths or namespaces)."
    end

    if RESERVED_KEYS.include?(name)
      raise Thor::Error, "#{name} is reserved by the account-data contract."
    end

    parsed_fields
  end

  def create_integration
    template "adapter.rb.tt", "app/models/provider/account_data/#{file_name}.rb"
    template "client.rb.tt", "app/models/provider/account_data/#{file_name}/client.rb"
    template "adapter_test.rb.tt", "test/models/provider/account_data/#{file_name}_test.rb"
    template "README.md.tt", "docs/providers/#{file_name}.md"
  end

  def show_summary
    return if behavior == :revoke

    say "Generated a draft account-data integration. Implement the client and normalization, then pass the contract tests."
    say "See docs/architecture/bank-data-providers.md for the shared runtime rollout and activation gates."
    say "No tables, routes or shared application files are generated. Legacy --skip-* options are no longer needed."
  end

  private
    def capabilities
      options[:type] == "investment" ? %w[transactions holdings activities] : %w[transactions]
    end

    def parsed_fields
      @parsed_fields ||= fields.map do |specification|
        declaration, marker, default = specification.partition(":default=")
        parts = declaration.split(":", -1)
        field_name, type, flag = parts

        unless (2..3).cover?(parts.length) && field_name.match?(/\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/) &&
            %w[string text integer boolean].include?(type) && (flag.nil? || flag == "secret")
          raise Thor::Error, "Invalid field #{declaration.inspect}. Use name:type[:secret][:default=value]; types: string, text, integer, boolean."
        end

        if flag == "secret" && !marker.empty?
          raise Thor::Error, "Secret fields cannot have defaults; supply credentials at runtime."
        end

        value = if marker.empty?
          nil
        elsif type == "integer"
          raise Thor::Error, "Default for #{field_name} must be an integer." unless default.match?(/\A-?\d+\z/)
          Integer(default, 10)
        elsif type == "boolean"
          raise Thor::Error, "Default for #{field_name} must be true or false." unless %w[true false].include?(default)
          default == "true"
        else
          default
        end

        { name: field_name, type: type, secret: flag == "secret", default: value }
      end.tap do |parsed|
        duplicates = parsed.group_by { |field| field[:name] }.select { |_, group| group.size > 1 }.keys
        raise Thor::Error, "Duplicate fields: #{duplicates.join(', ')}" if duplicates.any?
      end
    end
end
