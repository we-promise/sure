# frozen_string_literal: true

require "zlib"

module PlatformBootstrap
  class MultiCompanyOwners
    COMPANY_NAMES = [
      "Risingstone infra pvt ltd",
      "Risingstone ventures pvt ltd",
      "Risingstone projects pvt Ltd",
      "Mahetel pvt ltd"
    ].freeze

    PRIMARY_FAMILY_NAME = "Risingstone infra pvt ltd"

    OWNERS = [
      { email: "adminF0@bookeepz.net", label: "F0-SU-1" },
      { email: "adminF1@bookeepz.net", label: "F0-SU-2" }
    ].freeze

    SPECIAL_CHARACTER_PATTERN = /[!@#$%^&*(),.?":{}|<>]/
    ADVISORY_LOCK_KEY = Zlib.crc32("platform_bootstrap:multi_company_owners")

    Result = Data.define(:families, :users, :dry_run) do
      def success?
        true
      end
    end

    def initialize(passwords:, dry_run: false)
      @passwords = passwords.to_h.transform_keys { |email| normalize_email(email) }
      @dry_run = dry_run
    end

    def call
      validate_passwords!

      families = nil
      users = nil

      ActiveRecord::Base.transaction(requires_new: true) do
        acquire_advisory_lock!
        families = upsert_families
        users = upsert_users(primary_family: families.fetch(PRIMARY_FAMILY_NAME))

        raise ActiveRecord::Rollback if dry_run?
      end

      if dry_run?
        families, users = dry_run_previews(families: families, users: users)
      end

      Result.new(families: families.values, users: users, dry_run: dry_run?)
    end

    private
      attr_reader :passwords, :dry_run

      def dry_run?
        dry_run == true
      end

      def acquire_advisory_lock!
        return unless ActiveRecord::Base.connection.adapter_name == "PostgreSQL"

        sql = ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?)", ADVISORY_LOCK_KEY ])
        ActiveRecord::Base.connection.execute(sql)
      end

      def upsert_families
        COMPANY_NAMES.index_with do |name|
          family = Family.find_or_initialize_by(name: name)
          family.currency = "USD" if family.currency.blank?
          family.locale = I18n.default_locale.to_s if family.locale.blank?
          family.save!
          family
        end
      end

      def upsert_users(primary_family:)
        OWNERS.map do |owner|
          email = normalize_email(owner.fetch(:email))
          password = passwords.fetch(email)
          user = User.find_or_initialize_by(email: email)
          existing_preferences = user.persisted? ? owner_preferences(user) : nil

          user.assign_attributes(
            family: primary_family,
            role: :super_admin,
            password: password,
            password_confirmation: password,
            onboarded_at: user.onboarded_at || Time.current
          )

          if user.new_record?
            user.assign_attributes(
              first_name: owner.fetch(:label),
              last_name: nil,
              ui_layout: :dashboard,
              show_sidebar: true,
              show_ai_sidebar: true
            )
          end

          user.save!
          restore_owner_preferences(user, existing_preferences) if existing_preferences
          user
        end
      end

      def owner_preferences(user)
        user.slice(
          "first_name",
          "last_name",
          "ui_layout",
          "show_sidebar",
          "show_ai_sidebar"
        )
      end

      def restore_owner_preferences(user, preferences)
        return if preferences.all? { |attribute, value| user.public_send(attribute) == value }

        user.update_columns(preferences)
        user.reload
      end

      def dry_run_previews(families:, users:)
        family_previews = families.transform_values do |family|
          Family.new(
            name: family.name,
            currency: family.currency,
            locale: family.locale
          )
        end

        user_previews = users.map do |user|
          User.new(
            email: user.email,
            first_name: user.first_name,
            last_name: user.last_name,
            family: family_previews.fetch(user.family.name),
            role: user.role,
            onboarded_at: user.onboarded_at,
            ui_layout: user.ui_layout,
            show_sidebar: user.show_sidebar,
            show_ai_sidebar: user.show_ai_sidebar
          )
        end

        [ family_previews, user_previews ]
      end

      def validate_passwords!
        OWNERS.each do |owner|
          raw_email = owner.fetch(:email)
          email = normalize_email(raw_email)
          password = passwords[email]

          raise ArgumentError, "Missing password for #{raw_email}" if password.blank?

          errors = password_errors(password)
          raise ArgumentError, "Password for #{raw_email} #{errors.join("; ")}" if errors.any?
        end
      end

      def password_errors(password)
        [
          ("must be at least 8 characters" if password.length < 8),
          ("must include both uppercase and lowercase letters" unless password.match?(/[A-Z]/) && password.match?(/[a-z]/)),
          ("must include at least one number" unless password.match?(/\d/)),
          ("must include at least one special character" unless password.match?(SPECIAL_CHARACTER_PATTERN))
        ].compact
      end

      def normalize_email(email)
        email.to_s.strip.downcase
      end
  end
end
