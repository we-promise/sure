class CategoriesController < ApplicationController
  before_action :set_category, only: %i[edit update destroy]
  before_action :set_categories, only: %i[update edit]
  before_action :set_transaction, only: :create

  def index
    @categories = Current.family.categories.alphabetically.to_a
    @category_groups = Category::Group.for(@categories)
    @category_ids_with_transactions = category_ids_with_transactions(@categories)

    render layout: "settings"
  end

  def new
    @category = Current.family.categories.new color: Category::COLORS.sample
    set_categories
  end

  def merge
    @categories = Current.family.categories.alphabetically

    render layout: turbo_frame_request? ? false : "settings"
  end

  def create
    @category = Current.family.categories.new(category_params)

    if @category.save
      @transaction.update(category_id: @category.id) if @transaction

      flash[:notice] = t(".success")

      redirect_target_url = request.referer || categories_path
      respond_to do |format|
        format.html { redirect_back_or_to categories_path, notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, redirect_target_url) }
      end
    else
      set_categories
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @category.update(category_params)
      flash[:notice] = t(".success")

      redirect_target_url = request.referer || categories_path
      respond_to do |format|
        format.html { redirect_back_or_to categories_path, notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, redirect_target_url) }
      end
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @category.destroy

    redirect_back_or_to categories_path, notice: t(".success")
  end

  def destroy_all
    Current.family.categories.destroy_all
    redirect_back_or_to categories_path, notice: t(".success")
  end

  def bootstrap
    Current.family.categories.bootstrap!

    redirect_back_or_to categories_path, notice: t(".success")
  end

  def perform_merge
    permitted_params = category_merge_params

    if permitted_params[:target_id].present? && Array(permitted_params[:source_ids]).include?(permitted_params[:target_id])
      return redirect_to merge_categories_path, alert: t(".target_selected_as_source")
    end

    target = Current.family.categories.find_by(id: permitted_params[:target_id])
    return redirect_to merge_categories_path, alert: t(".target_not_found") unless target

    sources = Current.family.categories.where(id: permitted_params[:source_ids])
    return redirect_to merge_categories_path, alert: t(".invalid_categories") unless sources.any?

    merger = Category::Merger.new(family: Current.family, target_category: target, source_categories: sources)
    return redirect_to merge_categories_path, alert: t(".no_categories_selected") unless merger.merge!

    redirect_to categories_path, notice: t(".success", count: merger.merged_count)
  rescue Category::Merger::UnauthorizedCategoryError => e
    redirect_to merge_categories_path, alert: e.message
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed => e
    redirect_to merge_categories_path, alert: record_error_message(e)
  end

  private
    def set_category
      @category = Current.family.categories.find(params[:id])
    end

    def set_categories
      @categories = unless @category.parent?
        Current.family.categories.alphabetically.roots.where.not(id: @category.id)
      else
        []
      end
    end

    def set_transaction
      if params[:transaction_id].present?
        @transaction = Current.family.transactions.find(params[:transaction_id])
      end
    end

    def category_params
      params.require(:category).permit(:name, :color, :parent_id, :lucide_icon)
    end

    def category_merge_params
      params.permit(:target_id, source_ids: [])
    end

    def category_ids_with_transactions(categories)
      category_ids = categories.map(&:id)
      return {} if category_ids.empty?

      Current.family.transactions
                    .where(category_id: category_ids)
                    .distinct
                    .pluck(:category_id)
                    .index_with(true)
    end

    def record_error_message(error)
      record = error.respond_to?(:record) ? error.record : nil
      record&.errors&.full_messages&.to_sentence.presence || error.message
    end
end
