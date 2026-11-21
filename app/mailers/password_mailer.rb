class PasswordMailer < ApplicationMailer
  # Both reset emails share one translated template and differ only in where the
  # link points: the web email opens the browser password form, the mobile email
  # opens the bridge page that launches sureapp://password-reset. Each action
  # supplies its own @reset_url.
  #
  # The token is generated here rather than passed in via params: a token in the
  # mailer's params is serialized into the delivery job's arguments and logged in
  # plaintext.
  def password_reset
    @user = params[:user]
    @reset_url = edit_password_reset_url(token: @user.generate_token_for(:password_reset))

    mail to: @user.email, subject: t(".subject", product_name: product_name)
  end

  def mobile_password_reset
    @user = params[:user]
    @reset_url = mobile_redirect_password_reset_url(token: @user.generate_token_for(:password_reset))

    # Render the shared password_reset template so the mobile email inherits its
    # translations instead of carrying its own copy; its lazy `.key` lookups then
    # resolve under password_mailer.password_reset.
    mail to: @user.email,
         subject: t("password_mailer.password_reset.subject", product_name: product_name),
         template_name: "password_reset"
  end
end
