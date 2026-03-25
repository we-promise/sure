module AccountAuthorizable
  extend ActiveSupport::Concern

  included do
    include StreamExtensions
  end

  private

    def require_account_permission!(account, level = :write, redirect_path: nil)
      permission = account.permission_for(Current.user)

      allowed = case level
      when :write    then permission.in?([ :owner, :full_control ])
      when :annotate then permission.in?([ :owner, :full_control, :read_write ])
      when :owner    then permission == :owner
      else false
      end

      return true if allowed

      path = redirect_path || account_path(account)
      respond_to do |format|
        format.html { redirect_back_or_to path, alert: t("accounts.not_authorized") }
        format.turbo_stream { stream_redirect_back_or_to(path, alert: t("accounts.not_authorized")) }
      end
      false
    end
end
