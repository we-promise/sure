class IcostMapsController < ApplicationController
  layout "application"
  skip_before_action :sync_family

  def show
    load_map
  end

  def search
    return head :forbidden if Current.user.guest?
    load_map
    @results = Icost::Geocoder.new.search(params.dig(:icost_location, :query))
    @searched = true
    render :show
  rescue Icost::Geocoder::Error => error
    DebugLogEntry.capture(category: "import", level: "warn", source: self.class.name,
      provider_key: "icost", family: Current.family, message: "iCost place search unavailable",
      metadata: { error_class: error.class.name })
    flash.now[:alert] = t(error.is_a?(Icost::Geocoder::RateLimited) ? "icost_maps.rate_limited" : "icost_maps.search_failed")
    render :show, status: :unprocessable_entity
  end

  def update
    return head :forbidden if Current.user.guest?
    attrs = params.require(:icost_location).permit(:place, :latitude, :longitude)
    IcostRecord.locate_place!(user: Current.user, place: attrs[:place], latitude: attrs[:latitude], longitude: attrs[:longitude])
    redirect_to icost_map_path, notice: t("icost_maps.saved"), status: :see_other
  rescue IcostRecord::ResolutionError
    redirect_to icost_map_path, alert: t("icost_maps.invalid_coordinates"), status: :see_other
  end

  private
    def load_map
      scope = IcostRecord.owned_by(Current.user).where("NOT (resolution ? 'duplicate_of_id')")
      @categories = scope.distinct.pluck(:category_path).map { |path| path.reject(&:blank?).last }.compact.sort.uniq
      scope = scope.where("category_path ->> 1 = :category OR (category_path ->> 1 = '' AND category_path ->> 0 = :category)", category: params[:category]) if params[:category].present?
      @total = scope.count
      @records = scope.order(:recorded_at_text, :id).limit(1000).to_a
      @located = @records.select { |record| record.map_coordinates }
      @approximate_count = @located.count(&:approximate_map_location?)
      @places = @records.reject { |record| record.map_coordinates || record.location_text.blank? }.group_by(&:location_text)
      @place_names = @records.map(&:location_text).compact_blank.uniq.sort
      @category_icons = Current.family.categories.index_by(&:name)
      @selected_place = params.dig(:icost_location, :place).to_s
      @results = []
    end

    def default_breadcrumbs
      [ [ t("breadcrumbs.home"), root_path ], [ t("icost_maps.title"), nil ] ]
    end
end
