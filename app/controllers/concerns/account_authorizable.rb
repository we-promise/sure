module AccountAuthorizable
  extend ActiveSupport::Concern

  included do
    include StreamExtensions
  end

  private

    def require_account_permission!(account, level = :write, redirect_path: nil)
      return true if AccountPolicy.new(Current.user, account).permits?(level)

      path = redirect_path || account_path(account)
      respond_to do |format|
        format.html { redirect_back_or_to path, alert: t("accounts.not_authorized") }
        format.turbo_stream { stream_redirect_back_or_to(path, alert: t("accounts.not_authorized")) }
        format.json { render json: { error: t("accounts.not_authorized") }, status: :forbidden }
      end
      false
    end
end
