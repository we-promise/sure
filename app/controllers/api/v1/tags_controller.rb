# frozen_string_literal: true

module Api
  module V1
    # API v1 endpoint for tags
    # Provides full CRUD operations for family tags
    #
    # @example List all tags
    #   GET /api/v1/tags
    #
    # @example Create a new tag
    #   POST /api/v1/tags
    #   { "tag": { "name": "WhiteHouse", "color": "#3b82f6" } }
    #
    class TagsController < BaseController
      before_action -> { authorize_scope!(:read) }, only: %i[index show]
      before_action -> { authorize_scope!(:read_write) }, only: %i[create update destroy]
      before_action :set_tag, only: %i[show update destroy]

      # List all tags belonging to the family
      #
      # @return [Array<Hash>] JSON array of tag objects sorted alphabetically
      def index
        family = current_resource_owner.family
        @tags = family.tags.alphabetically

        render json: @tags.map { |t| tag_json(t) }
      rescue StandardError => e
        Rails.logger.error("API Tags Error: #{e.message}")
        render json: { error: "Failed to fetch tags" }, status: :internal_server_error
      end

      # Get a specific tag by ID
      #
      # @param id [String] The tag ID
      # @return [Hash] JSON tag object
      def show
        render json: tag_json(@tag)
      rescue StandardError => e
        Rails.logger.error("API Tag Show Error: #{e.message}")
        render json: { error: "Failed to fetch tag" }, status: :internal_server_error
      end

      # Create a new tag for the family
      #
      # @param name [String] Tag name (required)
      # @param color [String] Hex color code (optional, auto-assigned if not provided)
      # @return [Hash] JSON tag object with status 201
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

      # Update an existing tag
      #
      # @param id [String] The tag ID
      # @param name [String] New tag name (optional)
      # @param color [String] New hex color code (optional)
      # @return [Hash] JSON tag object
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

      # Delete a tag
      #
      # @param id [String] The tag ID
      # @return [nil] Empty response with status 204
      def destroy
        @tag.destroy!
        head :no_content
      rescue StandardError => e
        Rails.logger.error("API Tag Destroy Error: #{e.message}")
        render json: { error: "Failed to delete tag" }, status: :internal_server_error
      end

      private

        # Find and set the tag from params
        #
        # @raise [ActiveRecord::RecordNotFound] if tag not found
        # @return [Tag] The found tag
        def set_tag
          family = current_resource_owner.family
          @tag = family.tags.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Tag not found" }, status: :not_found
        end

        # Strong parameters for tag creation/update
        #
        # @return [ActionController::Parameters] Permitted parameters
        def tag_params
          params.require(:tag).permit(:name, :color)
        end

        # Serialize a tag to JSON format
        #
        # @param tag [Tag] The tag to serialize
        # @return [Hash] JSON-serializable hash
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
