# Doorkeeper's refresh grant at /oauth/token builds the new token from the old
# one's client, owner and scopes, so a mobile app token refreshed there would
# lose its device and survive MobileDevice#revoke_all_tokens!. The new token
# names the one it replaces in previous_refresh_token, so it takes the device
# from there.
module MobileDeviceTokenLineage
  extend ActiveSupport::Concern

  included do
    before_create :inherit_mobile_device, if: -> { mobile_device_id.nil? && previous_refresh_token.present? }
  end

  private
    def inherit_mobile_device
      previous = self.class.where(refresh_token: previous_refresh_token)
      return if previous.where.not(mobile_device_id: nil).none?

      # MobileDevice#issue_token! revokes the device's tokens under this lock,
      # so a refresh racing a new sign-in either lands before the revocation
      # and is revoked with the rest, or sees the old token revoked here.
      User.lock.find_by(id: resource_owner_id)
      self.mobile_device_id, revoked_at = previous.pick(:mobile_device_id, :revoked_at)
      self.revoked_at ||= revoked_at
    end
end

Rails.application.config.to_prepare do
  Doorkeeper::AccessToken.include(MobileDeviceTokenLineage) unless Doorkeeper::AccessToken.include?(MobileDeviceTokenLineage)
end
