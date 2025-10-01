class ApplicationMailer < ActionMailer::Base
  default from: email_address_with_name(
    ENV.fetch("EMAIL_SENDER", "sender@sure.local"),
    "#{Rails.configuration.x.brand_name} #{Rails.configuration.x.product_name}"
  )
  layout "mailer"

  private
    def product_name
      Rails.configuration.x.product_name
    end

    def brand_name
      Rails.configuration.x.brand_name
    end
end
