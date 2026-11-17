class TradeRepublicMailer < ApplicationMailer
  # Sent to a family admin after the daily login failed for good. It carries
  # no login details, only where to log in by hand.
  def auto_login_failed
    @user = params[:user]
    @settings_url = settings_providers_url(anchor: "trade-republic")

    I18n.with_locale(@user.family.locale) do
      mail(to: @user.email, subject: t(".subject", product_name: product_name))
    end
  end
end
