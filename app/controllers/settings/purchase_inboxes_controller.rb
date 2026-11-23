# The order mailbox: IMAP connection, shop domains and sender authentication for the instance.
class Settings::PurchaseInboxesController < ApplicationController
  layout "settings"

  guard_feature unless: -> { self_hosted? }
  before_action :require_preview_features!
  # The mailbox serves the whole instance: its settings and rejected emails span every family.
  before_action :ensure_instance_settings_manager

  RECENT_REJECTIONS = 20

  def show
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t(".title"), nil ] ]
    @config = PurchaseInbox.config
    @users = manageable_users.includes(:purchase_inbox_routes).order(:created_at)
    @rejections = DebugLogEntry.where(source: "PurchasesMailbox", level: "info").recent.limit(RECENT_REJECTIONS)
  end

  def update
    save_connection_settings
    enable = setting_params.key?(:enabled) ? setting_params[:enabled] == "1" : Setting.purchase_inbox_enabled
    # Checked on every save, so clearing a required field doesn't leave a mailbox that looks on
    # but is never read.
    if enable && !PurchaseInbox.configured?(PurchaseInbox.config.with(enabled: true))
      Setting.purchase_inbox_enabled = false
      return redirect_to settings_purchase_inbox_path, alert: t(".incomplete")
    end
    Setting.purchase_inbox_enabled = enable

    redirect_to settings_purchase_inbox_path, notice: t(".saved")
  end

  def test_connection
    result = PurchaseInbox::Poller.test_connection
    if result[:ok]
      redirect_to settings_purchase_inbox_path, notice: t(".success", count: result[:message_count].to_i,
                                                          hosts: result[:authserv_ids].join(", ").presence || "—")
    else
      redirect_to settings_purchase_inbox_path, alert: t(".failure", error: result[:error])
    end
  end

  private
    def setting_params
      params.fetch(:setting, {}).permit(
        :enabled, :host, :port, :ssl, :username, :password, :folder, :processed_folder,
        :shop_domains, :authserv_id, :require_sender_auth
      )
    end

    def save_connection_settings
      values = setting_params
      Setting.purchase_inbox_host = values[:host].to_s.strip if values.key?(:host)
      Setting.purchase_inbox_port = values[:port].to_i if values[:port].present?
      Setting.purchase_inbox_ssl = values[:ssl] == "1" if values.key?(:ssl)
      Setting.purchase_inbox_username = values[:username].to_s.strip if values.key?(:username)
      Setting.purchase_inbox_password = values[:password] if values[:password].present?
      Setting.purchase_inbox_folder = values[:folder].to_s.strip.presence || "INBOX" if values.key?(:folder)
      Setting.purchase_inbox_processed_folder = values[:processed_folder].to_s.strip if values.key?(:processed_folder)
      Setting.purchase_inbox_authserv_id = values[:authserv_id].to_s.strip.downcase.presence if values.key?(:authserv_id)
      Setting.purchase_inbox_require_sender_auth = values[:require_sender_auth] == "1" if values.key?(:require_sender_auth)
      if values.key?(:shop_domains)
        Setting.purchase_inbox_shop_domains = values[:shop_domains].to_s.split(/[\s,]+/).map(&:downcase).compact_blank.uniq
      end
    end

    def manageable_users
      Current.user.super_admin? ? User.all : Current.family.users
    end

    def ensure_instance_settings_manager
      return if Current.user.admin? && Current.user.manages_instance_settings?

      redirect_to settings_profile_path, alert: t("settings.purchase_inboxes.not_authorized")
    end
end
