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
    STARTER_EXPENDITURE_ACCOUNT_NAME = "Expenditure"

    OWNERS = [
      { email: "adminF0@bookeepz.net", label: "F0-SU-1" },
      { email: "adminF1@bookeepz.net", label: "F0-SU-2" }
    ].freeze

    FAMILY_ADMINS = [
      {
        email: "admin+rsinfra@bookeepz.net",
        label: "RS-INFRA-ADMIN",
        family_name: "Risingstone infra pvt ltd",
        password_env_key: "ADMIN_RSINFRA_PASSWORD"
      },
      {
        email: "admin+rsventures@bookeepz.net",
        label: "RS-VENTURES-ADMIN",
        family_name: "Risingstone ventures pvt ltd",
        password_env_key: "ADMIN_RSVENTURES_PASSWORD"
      },
      {
        email: "admin+rsprojects@bookeepz.net",
        label: "RS-PROJECTS-ADMIN",
        family_name: "Risingstone projects pvt Ltd",
        password_env_key: "ADMIN_RSPROJECTS_PASSWORD"
      },
      {
        email: "admin+mahetel@bookeepz.net",
        label: "MAHETEL-ADMIN",
        family_name: "Mahetel pvt ltd",
        password_env_key: "ADMIN_MAHETEL_PASSWORD"
      }
    ].freeze

    WORKSPACE_TARGET_ROLE = "admin"

    WORKSPACE_SHORTCUTS = OWNERS.flat_map do |owner|
      FAMILY_ADMINS.map do |admin|
        {
          operator_email: owner.fetch(:email).downcase,
          workspace_admin_email: admin.fetch(:email).downcase,
          family_name: admin.fetch(:family_name),
          target_role: WORKSPACE_TARGET_ROLE
        }
      end
    end.freeze

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

    class << self
      def bootstrap_workspace_operator?(user)
        return false unless user&.super_admin?

        WORKSPACE_SHORTCUTS.any? { |rule| rule.fetch(:operator_email) == normalized_email(user.email) }
      end

      def bootstrap_workspace_admin?(user)
        workspace_admin_rule_for(user).present?
      end

      def bootstrap_workspace_shortcut_allowed?(impersonator:, impersonated:)
        return false unless bootstrap_workspace_operator?(impersonator)

        workspace_rule = workspace_admin_rule_for(impersonated)
        return false unless workspace_rule

        WORKSPACE_SHORTCUTS.any? do |rule|
          rule.fetch(:operator_email) == normalized_email(impersonator.email) &&
            rule.fetch(:workspace_admin_email) == workspace_rule.fetch(:workspace_admin_email) &&
            rule.fetch(:family_name) == workspace_rule.fetch(:family_name) &&
            rule.fetch(:target_role) == workspace_rule.fetch(:target_role)
        end
      end

      def bootstrap_workspace_shortcut_session?(impersonation_session)
        return false unless impersonation_session

        bootstrap_workspace_shortcut_allowed?(
          impersonator: impersonation_session.impersonator,
          impersonated: impersonation_session.impersonated
        )
      end

      def workspace_picker_options_for(operator)
        return [] unless bootstrap_workspace_operator?(operator)

        workspace_admins_by_email = User.includes(:family)
          .where(email: bootstrap_workspace_admin_emails)
          .index_by { |user| normalized_email(user.email) }

        FAMILY_ADMINS.filter_map do |admin|
          workspace_admin = workspace_admins_by_email[normalized_email(admin.fetch(:email))]
          next unless workspace_admin_rule_for(workspace_admin)

          [ admin.fetch(:family_name), workspace_admin.id ]
        end
      end

      private
        def workspace_admin_rule_for(user)
          return if user.blank?

          workspace_admin_email = normalized_email(user.email)
          definition = FAMILY_ADMINS.find do |admin|
            normalized_email(admin.fetch(:email)) == workspace_admin_email
          end
          return unless definition
          return unless user.role == WORKSPACE_TARGET_ROLE
          return unless user.family&.name == definition.fetch(:family_name)

          {
            workspace_admin_email: workspace_admin_email,
            family_name: definition.fetch(:family_name),
            target_role: WORKSPACE_TARGET_ROLE
          }
        end

        def bootstrap_workspace_admin_emails
          FAMILY_ADMINS.map { |admin| normalized_email(admin.fetch(:email)) }
        end

        def normalized_email(email)
          email.to_s.strip.downcase
        end
    end

    def call
      validate_passwords!

      families = nil
      users = nil

      ActiveRecord::Base.transaction(requires_new: true) do
        acquire_advisory_lock!
        families = upsert_families
        upsert_starter_accounts(families:)
        users = upsert_super_admin_users(primary_family: families.fetch(PRIMARY_FAMILY_NAME))
        users.concat(upsert_family_admin_users(families:))

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
          if family.new_record?
            family.locale = I18n.default_locale.to_s if family.locale.blank?
            family.save!
          end
          family
        end
      end

      def upsert_super_admin_users(primary_family:)
        OWNERS.map do |owner|
          upsert_user(
            email: owner.fetch(:email),
            label: owner.fetch(:label),
            family: primary_family,
            role: :super_admin
          )
        end
      end

      def upsert_family_admin_users(families:)
        FAMILY_ADMINS.map do |admin|
          upsert_user(
            email: admin.fetch(:email),
            label: admin.fetch(:label),
            family: families.fetch(admin.fetch(:family_name)),
            role: :admin
          )
        end
      end

      def upsert_user(email:, label:, family:, role:)
        normalized_email = normalize_email(email)
        password = passwords.fetch(normalized_email)
        user = User.find_or_initialize_by(email: normalized_email)
        existing_preferences = user.persisted? ? owner_preferences(user) : nil

        user.assign_attributes(
          family: family,
          role: role,
          password: password,
          password_confirmation: password,
          onboarded_at: user.onboarded_at || Time.current
        )

        if user.new_record?
          user.assign_attributes(
            first_name: label,
            last_name: nil,
            ui_layout: :dashboard,
            show_sidebar: false,
            show_ai_sidebar: false
          )
        end

        user.save!
        restore_owner_preferences(user, existing_preferences) if existing_preferences
        user
      end

      def upsert_starter_accounts(families:)
        families.each_value do |family|
          next if family.accounts.where(accountable_type: "Depository").exists?

          Account.create_and_sync(
            {
              family: family,
              name: STARTER_EXPENDITURE_ACCOUNT_NAME,
              balance: 0,
              currency: family.currency,
              accountable_type: "Depository",
              accountable_attributes: {}
            },
            skip_initial_sync: true
          )
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
            country: family.country,
            date_format: family.date_format,
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
        bootstrap_users.each do |owner|
          raw_email = owner.fetch(:email)
          email = normalize_email(raw_email)
          password = passwords[email]

          raise ArgumentError, "Missing password for #{raw_email}" if password.blank?

          errors = password_errors(password)
          raise ArgumentError, "Password for #{raw_email} #{errors.join("; ")}" if errors.any?
        end
      end

      def bootstrap_users
        OWNERS + FAMILY_ADMINS
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
