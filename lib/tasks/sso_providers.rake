# frozen_string_literal: true

namespace :sso_providers do
  desc "Seed SSO providers from config/auth.yml into the database"
  task seed: :environment do
    dry_run = ENV["DRY_RUN"] == "true"

    puts "=" * 80
    puts "SSO Provider Seeding Task"
    puts "=" * 80
    puts "Mode: #{dry_run ? 'DRY RUN (no changes will be saved)' : 'LIVE (changes will be saved)'}"
    puts "Source: config/auth.yml"
    puts "-" * 80

    begin
      # Load auth.yml safely
      auth_config_path = Rails.root.join("config", "auth.yml")
      unless File.exist?(auth_config_path)
        puts "ERROR: config/auth.yml not found"
        exit 1
      end

      # Use safe_load to prevent code injection
      auth_config = YAML.safe_load(
        ERB.new(File.read(auth_config_path)).result,
        permitted_classes: [ Symbol ],
        aliases: true
      )

      # Get providers for current environment
      env_config = auth_config[Rails.env] || auth_config["default"]
      providers = env_config&.dig("providers") || []

      if providers.empty?
        puts "WARNING: No providers found in config/auth.yml for #{Rails.env} environment"
        exit 0
      end

      puts "Found #{providers.count} provider(s) in config/auth.yml"
      puts "-" * 80

      created_count = 0
      updated_count = 0
      skipped_count = 0
      errors = []

      ActiveRecord::Base.transaction do
        providers.each do |provider_config|
          provider_config = provider_config.deep_symbolize_keys

          # Extract provider attributes
          name = provider_config[:name] || provider_config[:id]
          strategy = provider_config[:strategy]

          unless name.present? && strategy.present?
            puts "SKIP: Provider missing name or strategy: #{provider_config.inspect}"
            skipped_count += 1
            next
          end

          # Find or initialize provider
          provider = SsoProvider.find_or_initialize_by(name: name)
          is_new = provider.new_record?

          # Build attributes hash
          attributes = {
            strategy: strategy,
            label: provider_config[:label] || name.titleize,
            icon: provider_config[:icon],
            enabled: provider_config.key?(:enabled) ? provider_config[:enabled] : true,
            issuer: provider_config[:issuer],
            client_id: provider_config[:client_id],
            redirect_uri: provider_config[:redirect_uri],
            settings: provider_config[:settings] || {}
          }

          # Only set client_secret if provided (don't overwrite existing)
          if provider_config[:client_secret].present?
            attributes[:client_secret] = provider_config[:client_secret]
          end

          # Assign attributes
          provider.assign_attributes(attributes.compact)

          # Check if changed
          if provider.changed?
            if dry_run
              puts "#{is_new ? 'CREATE' : 'UPDATE'} (dry-run): #{name} (#{strategy})"
              puts "  Changes: #{provider.changes.keys.join(', ')}"
            else
              if provider.save
                puts "#{is_new ? 'CREATE' : 'UPDATE'}: #{name} (#{strategy})"
                is_new ? created_count += 1 : updated_count += 1
              else
                error_msg = "Failed to save #{name}: #{provider.errors.full_messages.join(', ')}"
                puts "ERROR: #{error_msg}"
                errors << error_msg
              end
            end
          else
            puts "SKIP: #{name} (no changes)"
            skipped_count += 1
          end
        end

        # Rollback transaction if dry run
        raise ActiveRecord::Rollback if dry_run
      end

      puts "-" * 80
      puts "Summary:"
      puts "  Created: #{created_count}"
      puts "  Updated: #{updated_count}"
      puts "  Skipped: #{skipped_count}"
      puts "  Errors: #{errors.count}"

      if errors.any?
        puts "\nErrors encountered:"
        errors.each { |error| puts "  - #{error}" }
      end

      if dry_run
        puts "\nDRY RUN: No changes were saved to the database"
        puts "Run without DRY_RUN=true to apply changes"
      else
        puts "\nSeeding completed successfully!"
        puts "Note: Clear provider cache or restart server for changes to take effect"
      end

      puts "=" * 80

    rescue => e
      puts "ERROR: #{e.class}: #{e.message}"
      puts e.backtrace.first(5).join("\n")
      exit 1
    end
  end

  desc "List all SSO providers in the database"
  task list: :environment do
    providers = SsoProvider.order(:name)

    if providers.empty?
      puts "No SSO providers found in database"
    else
      puts "SSO Providers (#{providers.count}):"
      puts "-" * 80
      providers.each do |provider|
        status = provider.enabled? ? "✓ enabled" : "✗ disabled"
        puts "#{provider.name.ljust(20)} | #{provider.strategy.ljust(20)} | #{status}"
      end
    end
  end
end
