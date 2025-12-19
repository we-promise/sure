class SecurityMailer < ApplicationMailer
  def unusual_login
    @user = params[:user]
    @session = params[:session]
    @usual_country_code = params[:usual_country_code]
    @subject = t(".subject", product_name: product_name)

    mail to: @user.email, subject: @subject
  end
end
