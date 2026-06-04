class CurrentSessionsController < ApplicationController
  def update
    if session_params[:tab_key].present? && session_params[:tab_value].present?
      Current.session.set_preferred_tab(session_params[:tab_key], session_params[:tab_value])
    end

    if session_params[:active_family_id].present?
      family = Current.user.available_families.find { |candidate| candidate.id.to_s == session_params[:active_family_id].to_s }
      Current.session.set_active_family_id(family.id) if family
    end

    respond_to do |format|
      format.html { redirect_back fallback_location: root_path }
      format.json { head :ok }
      format.any { head :ok }
    end
  end

  private
    def session_params
      params.require(:current_session).permit(:tab_key, :tab_value, :active_family_id)
    end
end
