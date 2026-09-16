# Per-user ownership for provider connections.
#
# Every provider item table is family-scoped and, historically, carried no
# notion of *who* connected it -- so the only safe gate on the connector
# controllers was a blanket `require_admin!`. That forced a household to choose
# between sharing every connection or giving a member no automation at all.
#
# This concern adds an owner and lets each provider declare whether its
# credential is safe for a non-admin member to supply:
#
#   per_connection -- the credential covers only what the person supplying it
#                     authenticated to (Plaid Link, an exchange API key). A
#                     member connecting their own bank exposes nothing of
#                     anyone else's.
#   tenant_wide    -- one credential enumerates accounts the supplier may not
#                     own (SimpleFIN: a single access_url reads the whole
#                     bridge). Admin-only remains correct.
#
# The default is :tenant_wide, so a provider that has not been classified stays
# admin-only. Opening a provider up must be a deliberate declaration, never an
# oversight.
module ProviderItemOwnable
  extend ActiveSupport::Concern

  CREDENTIAL_SCOPES = %i[per_connection tenant_wide].freeze

  included do
    class_attribute :declared_credential_scope, instance_writer: false, default: :tenant_wide

    belongs_to :owner, class_name: "User", optional: true

    before_validation :assign_default_owner, if: -> { owner_id.blank? }
    validate :owner_belongs_to_family, if: -> { owner_id.present? && family_id.present? }

    scope :owned_by, ->(user) { where(owner_id: user&.id) }
  end

  class_methods do
    # Declares how far this provider's credential reaches. See the module docs.
    def credential_scope(scope)
      scope = scope.to_sym
      unless CREDENTIAL_SCOPES.include?(scope)
        raise ArgumentError, "unknown credential scope #{scope.inspect} (expected one of #{CREDENTIAL_SCOPES.inspect})"
      end

      self.declared_credential_scope = scope
    end

    # May a non-admin member create one of these?
    def member_connectable?
      declared_credential_scope == :per_connection
    end
  end

  def owned_by?(user)
    user.present? && owner_id == user.id
  end

  # Admins keep full oversight of every connection in the family -- this change
  # is purely additive. A member may only manage a connection they own, and
  # only for a provider whose credential is scoped to that connection.
  def manageable_by?(user)
    return false if user.blank?
    return true if user.admin?

    self.class.member_connectable? && owned_by?(user)
  end

  private
    # Mirrors Account#assign_default_owner. Items are usually created in a
    # request (so Current.user is the connector), but the fallback matters for
    # backfills and console work.
    def assign_default_owner
      return if owner.present?

      self.owner =
        if Current.user.present? && Current.user.family_id == family_id
          Current.user
        else
          family&.users&.where(role: "admin")&.order(:created_at, :id)&.first ||
            family&.users&.where(role: "super_admin")&.order(:created_at, :id)&.first
        end
    end

    def owner_belongs_to_family
      return if owner.blank?

      errors.add(:owner, :invalid) unless owner.family_id == family_id
    end
end
