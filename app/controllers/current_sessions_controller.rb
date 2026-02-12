class CurrentSessionsController < ApplicationController
  def update
    if params[:family_id].present?
      membership = Current.user.memberships.find_by!(family_id: params[:family_id])
      Current.session.update!(family_id: membership.family_id)
      Current.user.update!(family_id: membership.family_id)
      redirect_to root_path
      return
    end

    if session_params[:tab_key].present? && session_params[:tab_value].present?
      Current.session.set_preferred_tab(session_params[:tab_key], session_params[:tab_value])
    end

    head :ok
  end

  private
    def session_params
      params.require(:current_session).permit(:tab_key, :tab_value)
    end
end
