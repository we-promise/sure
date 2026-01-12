# frozen_string_literal: true

# app/controllers/api/v1/tags_controller.rb
# API v1 endpoint for tags
# Full CRUD operations for family tags

module Api
  module V1
    class TagsController < BaseController
      before_action :ensure_read_scope, only: %i[ index show ]
      before_action :ensure_write_scope, only: %i[ create update destroy ]
      before_action :set_tag, only: %i[ show update destroy ]

      # GET /api/v1/tags
      # Returns all tags belonging to the family
      def index
        family = current_resource_owner.family
        @tags = family.tags.alphabetically

        render json: @tags.map { |t| tag_json(t) }
      rescue StandardError => e
        Rails.logger.error("API Tags Error: #{e.message}")
        render json: { error: "Failed to fetch tags" }, status: :internal_server_error
      end

      # GET /api/v1/tags/:id
      def show
        render json: tag_json(@tag)
      end

      # POST /api/v1/tags
      # Creates a new tag for the family
      def create
        family = current_resource_owner.family
        @tag = family.tags.new(tag_params)

        # Assign random color if not provided
        @tag.color ||= Tag::COLORS.sample

        if @tag.save
          render json: tag_json(@tag), status: :created
        else
          render json: { error: @tag.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      rescue StandardError => e
        Rails.logger.error("API Tag Create Error: #{e.message}")
        render json: { error: "Failed to create tag" }, status: :internal_server_error
      end

      # PATCH/PUT /api/v1/tags/:id
      def update
        if @tag.update(tag_params)
          render json: tag_json(@tag)
        else
          render json: { error: @tag.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      rescue StandardError => e
        Rails.logger.error("API Tag Update Error: #{e.message}")
        render json: { error: "Failed to update tag" }, status: :internal_server_error
      end

      # DELETE /api/v1/tags/:id
      def destroy
        @tag.destroy
        head :no_content
      rescue StandardError => e
        Rails.logger.error("API Tag Destroy Error: #{e.message}")
        render json: { error: "Failed to delete tag" }, status: :internal_server_error
      end

      private

        def set_tag
          family = current_resource_owner.family
          @tag = family.tags.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Tag not found" }, status: :not_found
        end

        def tag_params
          params.require(:tag).permit(:name, :color)
        end

        def tag_json(tag)
          {
            id: tag.id,
            name: tag.name,
            color: tag.color,
            created_at: tag.created_at,
            updated_at: tag.updated_at
          }
        end
    end
  end
end
