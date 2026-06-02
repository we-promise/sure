class TagsController < ApplicationController
  before_action :set_tag, only: %i[edit update destroy]

  def index
    @tags = Current.family.tags.alphabetically

    render layout: "settings"
  end

  def new
    @tag = Current.family.tags.new color: Tag::COLORS.sample
  end

  def create
    @tag = Current.family.tags.new(tag_params)

    if @tag.save
      respond_to do |format|
        format.html { redirect_to tags_path, notice: t(".created") }
        format.json { render json: tag_json(@tag), status: :created }
      end
    else
      respond_to do |format|
        format.html { redirect_to tags_path, alert: t(".error", error: @tag.errors.full_messages.to_sentence) }
        format.json { render json: { errors: @tag.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def edit
  end

  def update
    @tag.update!(tag_params)
    redirect_to tags_path, notice: t(".updated")
  end

  def destroy
    @tag.destroy!
    redirect_to tags_path, notice: t(".deleted")
  end

  def destroy_all
    Current.family.tags.destroy_all
    redirect_back_or_to tags_path, notice: t(".all_deleted")
  end

  private

    def set_tag
      @tag = Current.family.tags.find(params[:id])
    end

    def tag_params
      params.require(:tag).permit(:name, :color)
    end

    def tag_json(tag)
      tag.as_json(only: %i[id name color]).merge(
        html: render_to_string(
          partial: "DS/tag_select/option",
          formats: [ :html ],
          locals: { tag: tag, selected: true, view_helpers: helpers }
        )
      )
    end
end
