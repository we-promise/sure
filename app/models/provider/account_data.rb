# Account synchronization includes bank, brokerage and cryptocurrency sources.
# Registry selection and shared ingestion own activation; defining an adapter does
# not establish a connection or migrate existing records.
module Provider::AccountData
  class Error < StandardError; end
  class NotImplementedError < Error; end
  class UnsupportedCapability < Error; end
  class InvalidResponse < Error; end
  class StaleWriter < Error; end
  class IncompletePage < Error; end
  class DeferredPage < IncompletePage
    attr_reader :resume_at

    def initialize(resume_at:)
      @resume_at = resume_at
      super("Provider data is being prepared; sync will resume")
    end
  end
  class BudgetExhausted < IncompletePage; end
  class PaginationRestartRequired < Error
    attr_reader :generation_id, :start_cursor

    def initialize(generation_id:, start_cursor:)
      @generation_id, @start_cursor = generation_id, start_cursor
      super("Transaction pagination must restart from its committed cursor")
    end
  end
end
