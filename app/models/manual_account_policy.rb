class ManualAccountPolicy
  VISIBLE_ACCOUNTABLE_TYPES = %w[Depository Investment Property OtherAsset].freeze
  PLATFORM_OWNER_EMAILS = PlatformBootstrap::MultiCompanyOwners::OWNERS
    .map { |owner| owner.fetch(:email).to_s.strip.downcase }
    .freeze

  class << self
    def visible_accountables(classification: nil)
      VISIBLE_ACCOUNTABLE_TYPES
        .filter_map { |type| Accountable.from_type(type) }
        .select { |klass| classification.blank? || klass.classification == classification }
        .map(&:new)
    end

    def platform_owner?(user)
      return false unless user&.super_admin?

      PLATFORM_OWNER_EMAILS.include?(user.email.to_s.strip.downcase)
    end
  end
end
