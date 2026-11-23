module Family::EmailAlertConnectable
  extend ActiveSupport::Concern

  included do
    has_many :email_alert_items, dependent: :destroy
  end

  def can_connect_email_alert?
    true
  end

  def create_email_alert_item!(item_name: nil)
    email_alert_items.create!(name: item_name.presence || I18n.t("email_alert_items.default_name"))
  end
end
