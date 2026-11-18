class EmailConfirmationMailer < ApplicationMailer
  # Subject can be set in your I18n file at config/locales/en.yml
  # with the following lookup:
  #
  #   en.email_confirmation_mailer.confirmation_email.subject
  #
  def confirmation_email
    @user = params[:user]
    # Initial sign-up verification has no pending address change.
    prefix = @user.pending_email_change? ? "" : "verify_"
    @subject = prefix.empty? ? t(".subject", product_name: product_name) : t(".verify_subject")
    @body = t(".#{prefix}body")
    @cta = t(".#{prefix}cta")
    @confirmation_url = new_email_confirmation_url(token: @user.generate_token_for(:email_confirmation))

    mail to: @user.email_confirmation_address, subject: @subject
  end
end
