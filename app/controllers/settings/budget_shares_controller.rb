class Settings::BudgetSharesController < ApplicationController
  layout "settings"

  def update
    eligible_members = Current.family.users.where.not(id: Current.user.id).where(active: true)

    BudgetShare.transaction do
      sharing_members_params.each do |member_params|
        viewer = eligible_members.find_by(id: member_params[:viewer_id])
        next unless viewer

        share = Current.user.budget_shares_given.find_by(viewer: viewer)
        permission = member_params[:permission].presence

        if permission.in?(BudgetShare::PERMISSIONS)
          if share
            share.update!(permission: permission)
          else
            Current.user.budget_shares_given.create!(viewer: viewer, permission: permission)
          end
        elsif share
          share.destroy!
        end
      end
    end

    redirect_to settings_preferences_path, notice: t(".success")
  end

  private
    def sharing_members_params
      return [] unless params.dig(:budget_shares, :members)

      members = params.require(:budget_shares).permit(
        members: [ :viewer_id, :permission ]
      )[:members]

      members.is_a?(Array) ? members : members&.values || []
    end
end
