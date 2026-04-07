class ImportGusInflationRatesJob < ApplicationJob
  queue_as :scheduled

  def perform(start_year: Date.current.year - 1, end_year: Date.current.year, force: false)
    ImportInflationRatesJob.perform_now(
      start_year:,
      end_year:,
      force:,
      providers: [ "gus_sdp" ]
    )
  end
end
