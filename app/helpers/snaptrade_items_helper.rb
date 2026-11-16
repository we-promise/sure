module SnaptradeItemsHelper
  # Where an unauthorized SnapTrade item should be sent to get authorized.
  #
  # Both grants end with the same access token, so the choice is purely about
  # what the deployment can run: the browser redirect needs a confidential
  # client (client secret) and a registered redirect URI, while the device flow
  # needs only the public client id. Prefer the redirect when it is available,
  # since it is the shorter path for the user.
  def snaptrade_authorize_path(item_id: nil, accountable_type: nil, return_to: nil)
    query = {
      item_id: item_id.presence,
      accountable_type: accountable_type.presence,
      return_to: return_to.presence
    }.compact

    if Provider::Snaptrade.authorization_code_configured?
      oauth_authorize_snaptrade_items_path(query)
    else
      oauth_device_authorize_snaptrade_items_path(query)
    end
  end

  # The redirect flow leaves the app entirely, and a cross-origin redirect
  # cannot render inside a Turbo frame; the device flow is a page we render
  # ourselves, so it belongs in the drawer.
  def snaptrade_authorize_frame
    Provider::Snaptrade.authorization_code_configured? ? "_top" : "drawer"
  end
end
