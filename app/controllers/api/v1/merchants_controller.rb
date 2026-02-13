# frozen_string_literal: true

module Api
  module V1
    class MerchantsController < BaseController
      before_action -> { authorize_scope!(:read) }, only: %i[index show]
      before_action -> { authorize_scope!(:read_write) }, only: %i[create update destroy]
      before_action :set_merchant, only: %i[show update destroy]

      def index
        family = current_resource_owner.family

        family_merchant_ids = family.merchants.select(:id)
        provider_merchant_ids = family.transactions.select(:merchant_id)

        @merchants = Merchant
          .where(id: family_merchant_ids)
          .or(Merchant.where(id: provider_merchant_ids, type: "ProviderMerchant"))
          .distinct
          .alphabetically

        render json: @merchants.map { |m| merchant_json(m) }
      end

      def show
        render json: merchant_json(@merchant)
      end

      def create
        family = current_resource_owner.family
        @merchant = family.merchants.new(merchant_params)

        if @merchant.save
          render json: merchant_json(@merchant), status: :created
        else
          render json: { error: @merchant.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      end

      def update
        if @merchant.update(merchant_params)
          render json: merchant_json(@merchant)
        else
          render json: { error: @merchant.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      end

      def destroy
        @merchant.destroy!
        head :no_content
      end

      private

        def set_merchant
          family = current_resource_owner.family
          @merchant = family.merchants.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Merchant not found" }, status: :not_found
        end

        def merchant_params
          params.require(:merchant).permit(:name, :color, :website_url)
        end

        def merchant_json(merchant)
          {
            id: merchant.id,
            name: merchant.name,
            type: merchant.type,
            color: merchant.color,
            logo_url: merchant.logo_url,
            website_url: merchant.website_url,
            created_at: merchant.created_at.iso8601,
            updated_at: merchant.updated_at.iso8601
          }
        end
    end
  end
end
