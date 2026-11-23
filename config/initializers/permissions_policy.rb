# Be sure to restart your server when you modify this file.
#
# Define an application-wide HTTP permissions policy. For further
# information see: https://developers.google.com/web/updates/2018/06/feature-policy
#
# This app never uses camera/microphone/usb/geolocation/payment/fullscreen
# APIs (verified by grepping app/javascript for their JS entry points), so
# those are locked to :none.
#
# WebAuthn/passkeys (app/javascript/controllers/webauthn_*_controller.js) are
# deliberately NOT restricted here: this Rails version's PermissionsPolicy
# DIRECTIVES list (action_dispatch/http/permissions_policy.rb) doesn't include
# publickey-credentials-get/-create, so there's no directive to set — leaving
# it unlisted keeps the browser default (allowed), which is what passkey
# login/registration needs. Do not add those directive names here; Rails
# raises NoMethodError for any symbol outside its fixed DIRECTIVES map.
#
# Rails only sends this policy as the legacy Feature-Policy header, which
# Firefox and Safari ignore, so the same list also goes out as
# Permissions-Policy (each feature disabled with an empty allowlist).
disabled_features = %i[camera microphone geolocation usb payment fullscreen]

Rails.application.config.permissions_policy do |policy|
  disabled_features.each { |feature| policy.public_send(feature, :none) }
end

Rails.application.config.action_dispatch.default_headers["Permissions-Policy"] =
  disabled_features.map { |feature| "#{feature}=()" }.join(", ")
