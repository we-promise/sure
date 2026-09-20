# Authorization for provider connector controllers.
#
# Replaces a blanket `require_admin!` with a check driven by the provider's
# declared credential scope (see ProviderItemOwnable). A controller opts in by
# naming its item class:
#
#   class PlaidItemsController < ApplicationController
#     include ConnectorAuthorizable
#     connects_provider PlaidItem
#
# Controllers that do not opt in are unaffected and keep their own gating, so
# this is safe to roll out one provider at a time.
module ConnectorAuthorizable
  extend ActiveSupport::Concern

  included do
    class_attribute :connector_item_class, instance_accessor: false
  end

  class_methods do
    def connects_provider(klass)
      self.connector_item_class = klass
    end
  end

  private
    # Gate for creating a new connection. Admins always may; a member may only
    # when the provider's credential is scoped to the single connection they
    # are authenticating. Guests never may -- they are read-only by design.
    def require_connector_create!
      return if Current.user&.admin?
      return if connector_item_class&.member_connectable? && Current.user&.member?

      deny_connector_access!
    end

    # Gate for mutating an existing connection (edit/destroy/sync). Ownership,
    # not just role: a member may manage the connections they added and no
    # others.
    def require_connector_manage!
      return if connector_item.present? && connector_item.manageable_by?(Current.user)

      deny_connector_access!
    end

    def connector_item_class
      self.class.connector_item_class
    end

    # The item loaded by the controller's own `before_action`. Convention over
    # configuration: PlaidItemsController sets @plaid_item.
    def connector_item
      return nil if connector_item_class.nil?

      instance_variable_get(:"@#{connector_item_class.name.underscore}")
    end

    def deny_connector_access!
      message = if connector_item_class&.member_connectable?
        t("shared.require_connector_owner")
      else
        t("shared.require_admin")
      end

      respond_to do |format|
        format.html { redirect_to accounts_path, alert: message }
        format.turbo_stream { head :forbidden }
        format.json { head :forbidden }
        format.any { head :forbidden }
      end
    end
end
