class ApplicationMailer < ActionMailer::Base
  default from: email_address_with_name(
    ENV.fetch("EMAIL_SENDER", "sender@sure.local"),
    "#{Rails.configuration.x.brand_name} Finance"
  )
  layout "mailer"

  private
    def brand_name
      Rails.configuration.x.brand_name
    end

    def brand_plus
      Rails.configuration.x.brand_plus
    end
end
