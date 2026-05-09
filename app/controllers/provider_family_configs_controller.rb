class ProviderFamilyConfigsController < ApplicationController
  before_action :require_admin!
  before_action :set_config, only: [ :update ]

  def create
    @config = Current.family.provider_family_configs.build(config_params)
    if @config.save
      redirect_to settings_providers_path, notice: t("provider.family_configs.saved")
    else
      render :create, status: :unprocessable_entity
    end
  end

  def update
    attrs = config_params
    attrs = attrs.except(:client_secret) if attrs[:client_secret].blank? && @config.client_secret.present?

    if @config.update(attrs)
      redirect_to settings_providers_path, notice: t("provider.family_configs.updated")
    else
      render :update, status: :unprocessable_entity
    end
  end

  def destroy
    Current.family.provider_family_configs.find(params[:id]).destroy
    redirect_to settings_providers_path, notice: t("provider.family_configs.removed")
  end

  private

    def set_config
      @config = Current.family.provider_family_configs.find(params[:id])
    end

    def config_params
      params.require(:provider_family_config).permit(:provider_key, :client_id, :client_secret, :sandbox)
    end
end
