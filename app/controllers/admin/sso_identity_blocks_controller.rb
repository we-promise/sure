# frozen_string_literal: true

module Admin
  class SsoIdentityBlocksController < Admin::BaseController
    def destroy
      block = SsoIdentityBlock.find(params[:id])
      SsoIdentityBlock.transaction do
        SsoAuditLog.log_identity_unblocked!(block: block, actor: Current.user, request: request)
        block.destroy!
      end
      redirect_to admin_users_path, notice: t(".success")
    end
  end
end
