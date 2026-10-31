# Writes PROPOSALS, never classifications. A proposal changes nothing a user
# sees until a person approves it; see Security::ClassificationProposal.
class Assistant::Function::SuggestSecurityClassification < Assistant::Function
  class << self
    def name
      "suggest_security_classification"
    end

    def description
      <<~INSTRUCTIONS
        Use this to propose asset class, sub-class, sector and region for securities
        the user holds that are not classified yet.

        This records a PROPOSAL for the user to review and approve. It does not
        classify anything. Nothing you send here changes a figure the user sees
        until they approve it.

        Propose only what you can justify from the instrument itself -- its name,
        ticker, exchange and type. Say why in `rationale`, for the person who
        reviews the proposal. Leave a field out rather than guessing it: a
        proposal that only names the region is more useful than one that invents
        an asset class. A sub-class needs its asset class beside it.

        If the user holds the same ticker on more than one exchange, name the
        exchange in `exchange_operating_mic`; otherwise the entry is skipped.

        Securities the user has already classified by hand, or locked, are skipped
        and reported back in `skipped`.

        Example:

        ```
        suggest_security_classification({
          proposals: [
            {
              ticker: "VWRA",
              asset_class: "equity",
              asset_sub_class: "etf",
              rationale: "Accumulating global equity ETF; no single region."
            }
          ]
        })
        ```
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "proposals" ],
      properties: {
        proposals: {
          type: "array",
          description: "One entry per security to propose a classification for",
          minItems: 1,
          items: {
            type: "object",
            properties: {
              ticker: { type: "string", description: "Ticker of a security the user holds" },
              exchange_operating_mic: { type: "string", description: "The listing's exchange MIC; needed only when the ticker is held on more than one exchange" },
              asset_class: { enum: Security::ASSET_CLASSES },
              asset_sub_class: { enum: Security::ASSET_SUB_CLASSES, description: "Only together with asset_class" },
              sector: { type: "string", description: "Free text, as the data providers supply it" },
              region: { enum: Security::REGION_KEYS },
              rationale: { type: "string", description: "Why, in one sentence, for the user to read" }
            },
            required: [ "ticker" ]
          }
        }
      }
    )
  end

  def call(params = {})
    recorded = 0
    skipped = []

    Array(params["proposals"]).each do |entry|
      unless entry.is_a?(Hash)
        skipped << { ticker: nil, reason: "each proposal must be an object" }
        next
      end

      ticker = entry["ticker"].to_s
      mic = entry["exchange_operating_mic"].presence
      # Resolved within the user's own holdings rather than across the whole
      # `securities` table. This tool is registered in `function_classes`, which
      # also serves `/mcp`, so an external caller must not be able to queue a
      # proposal against an instrument this user does not hold.
      #
      # A ticker is unique per exchange only, so the same ticker held on two
      # exchanges is two securities. Picking one would attach the proposal to
      # whichever row the database returned, and approval would classify the
      # wrong global security.
      matches = held_securities.select { |s| s.ticker.casecmp?(ticker) }
      matches = matches.select { |s| s.exchange_operating_mic.to_s.casecmp?(mic) } if mic

      if matches.empty?
        skipped << { ticker: ticker, reason: "not held by this family" }
        next
      elsif matches.size > 1
        exchanges = matches.map(&:exchange_operating_mic).compact.sort.join(", ")
        skipped << { ticker: ticker, reason: "held on more than one exchange (#{exchanges}); name one in exchange_operating_mic" }
        next
      end

      security = matches.first

      # Mapped once, so a field cannot be added to the check and not to the
      # write.
      attributes = {
        asset_class: entry["asset_class"], asset_sub_class: entry["asset_sub_class"],
        sector: entry["sector"].presence, region: entry["region"],
        rationale: entry["rationale"].presence
      }

      proposal = Security::ClassificationProposal.new(security: security, family: family, **attributes)

      unless proposal.valid?
        skipped << { ticker: ticker, reason: proposal.errors.full_messages.to_sentence }
        next
      end

      begin
        Security::ClassificationProposal.propose!(security: security, family: family, **attributes)
        recorded += 1
      rescue ActiveRecord::RecordInvalid => e
        # The pre-check makes this unlikely, not impossible: `propose!` updates
        # an existing row, and a validation that depends on persisted state can
        # refuse there. One security the assistant cannot record must not cost
        # the user the rest of the batch.
        skipped << { ticker: ticker, reason: e.record.errors.full_messages.to_sentence }
      end
    end

    { recorded: recorded, skipped: skipped }
  end

  private
    # Holdings in accounts this user may see, so the tool cannot reveal or act
    # on a position held only in another member's private account.
    def held_securities
      @held_securities ||= Security.where(
        id: Holding.where(account_id: user.accessible_accounts.visible.select(:id)).select(:security_id)
      ).to_a
    end
end
