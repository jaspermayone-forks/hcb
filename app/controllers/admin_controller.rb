# frozen_string_literal: true

class AdminController < Admin::BaseController
  def task_size
    starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    size = pending_task params[:task_name].to_sym
    ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    elapsed = ending - starting

    respond_to do |format|
      format.json { render json: { elapsed:, size: } }
      format.html do
        color = size == 0 ? "muted" : "accent"

        render html: helpers.turbo_frame_tag(params[:task_name]) {
          helpers.badge_for size, class: "bg-#{color}"
        }
      end
    end
  end

  def negative_events
    @negative_events = Event.negatives
  end

  def transaction
    @canonical_transaction = CanonicalTransaction.find(params[:id])
    @hcb_code = @canonical_transaction.local_hcb_code

    # potentials
    @potential_donation_payouts = DonationPayout.donation_hcb_code.where(amount: @canonical_transaction.amount_cents)
    @potential_invoice_payouts = InvoicePayout.invoice_hcb_code.where(amount: @canonical_transaction.amount_cents)

    # other
    @canonical_pending_transactions = CanonicalPendingTransaction.unmapped.where(amount_cents: @canonical_transaction.amount_cents)
    @ahoy_events = Ahoy::Event.where("name in (?) and (properties->'canonical_transaction'->>'id')::int = ?", [::SystemEventService::Write::SettledTransactionMapped::NAME, ::SystemEventService::Write::SettledTransactionCreated::NAME], @canonical_transaction.id).order("time desc")

    if @canonical_transaction.memo.include?("WISE INC")
      potential_wise_transfers = WiseTransfer.sent.where(usd_amount_cents: -@canonical_transaction.amount_cents)

      if potential_wise_transfers.one?
        @suggested_wise_mapping = potential_wise_transfers.first
      end
    end

    # Mapping confirm message
    @mapping_confirm_msg = if !@canonical_transaction.local_hcb_code.unknown?
                             "Woaaahaa! 😯 This seems like a transaction that SHOULD NOT be manually mapped! Are you sure you want to do this? 👀"
                           elsif @canonical_transaction.amount_cents.abs >= 5_000_00 # $5k
                             "Are you really really sure you want to map this transaction? 🤔 it seems like a big one :)"
                           end
  end

  def events
    @page = params[:page] || 1
    @per = params[:per] || 100
    @csv_export = params[:format] == "csv"

    @events = filtered_events
    @count = @events.count

    respond_to do |format|
      format.html do
        @events = @events.page(@page).per(@per)
      end
      format.csv { render csv: @events }
    end
  end

  def event_process
    @event = Event.friendly.find(params[:id])
  end

  def event_new
  end

  def event_new_from_airtable
  end

  def event_create
    emails = [params[:organizer_email]].reject(&:empty?)

    ::EventService::Create.new(
      name: params[:name],
      emails:,
      is_signee: params[:is_signee] == "true",
      cosigner_email: params[:cosigner_email].presence,
      include_onboarding_videos: params[:include_videos].to_i == 1,
      country: params[:country],
      point_of_contact_id: params[:point_of_contact_id],
      approved: params[:approved].to_i == 1,
      is_public: params[:is_public].to_i == 1,
      plan: params[:plan],
      tags: params[:tags],
      risk_level: params[:risk_level],
      demo_mode: params[:demo_mode].to_i == 1
    ).run

    redirect_to events_admin_index_path, flash: { success: "Successfully created #{params[:name]}" }
  rescue => e
    redirect_to event_new_admin_index_path, flash: { error: e.message }
  end

  def event_create_from_airtable
    record = ApplicationsTable.find(params[:airtable_record_id])
    application = record.fields
    country = ISO3166::Country.find_country_by_any_name(application["Event Location"])

    tags = []
    tags << EventTag::Tags::ORGANIZED_BY_TEENAGERS if application["TEEN"]

    if ["Robotics", "FIRST/Robotics", "FIRST - Argosy"].include?(application["Org Type"])
      tags << EventTag::Tags::ROBOTICS_TEAM
    end

    event = ::EventService::Create.new(
      name: application["Event Name"],
      country: country&.alpha2,
      point_of_contact_id: current_user.id,
      approved: true,
      tags:,
      demo_mode: true
    ).run

    Flipper.enable_actor(:organizer_position_contracts_2025_01_03, event)

    record["HCB account URL"] = "https://hcb.hackclub.com/#{event.slug}"
    record["HCB ID"] = event.id

    record.save

    redirect_to event_path(event), flash: { success: "Successfully created #{event.name}" }
  rescue => e
    redirect_to event_new_from_airtable_admin_index_path, flash: { error: e.message }
  end

  def event_balance
    @event = Event.friendly.find(params[:id])
    @balance = Rails.cache.fetch("admin_event_balance_#{@event.id}", expires_in: 5.minutes) do
      @event.balance.to_i
    end
    render :event_balance, layout: false
  end

  def event_raised
    @event = Event.friendly.find(params[:id])
    @raised = Rails.cache.fetch("admin_event_raised_#{@event.id}", expires_in: 5.minutes) do
      @event.total_raised.to_i
    end
    render :event_raised, layout: false
  end

  def event_toggle_approved
    @event = Event.find(params[:id])

    state = ::EventService::ToggleApproved.new(@event).run

    redirect_to event_process_admin_path(@event), flash: { success: "Successfully marked as #{state}" }
  rescue => e
    redirect_to event_process_admin_path(@event), flash: { error: e.message }
  end

  def event_reject
    @event = Event.find(params[:id])

    state = ::EventService::Reject.new(@event).run

    redirect_to event_process_admin_path(@event), flash: { success: "Event has been #{state}" }
  rescue => e
    redirect_to event_process_admin_path(@event), flash: { error: e.message }
  end

  def bank_fees
    @page = params[:page] || 1
    @per = params[:per] || 100
    @event_id = params[:event_id].presence

    if @event_id
      @event = Event.find(@event_id)

      relation = @event.bank_fees
    else
      relation = BankFee
    end

    @count = relation.count
    @sum = relation.sum(:amount_cents)

    @bank_fees = relation.page(@page).per(@per).order("bank_fees.created_at desc")
  end

  def users
    @page = params[:page] || 1
    @per = params[:per] || 100
    @q = params[:q].presence
    @access_level = params[:access_level]
    @event_id = params[:event_id].presence
    @referral_program_id = params[:referral_program_id].presence
    @params = params.permit(:page, :per, :q, :access_level, :event_id, :referral_program_id)

    if @event_id
      @event = Event.find(@event_id)

      relation = @event.users
    else
      relation = User.all
    end
    relation = relation.includes(:events).includes(:card_grants)

    if @referral_program_id
      attribution_user_ids = Referral::Attribution.where(referral_program_id: @referral_program_id).pluck(:user_id)
      relation = relation.where(id: attribution_user_ids)
    end

    relation = relation.search_name(@q) if @q
    relation = relation.where(access_level: @access_level) if @access_level.present?

    @count = relation.count

    @users = relation.page(@page).per(@per).order(created_at: :desc)
    @referral_programs = Referral::Program.all

    respond_to do |format|
      format.html do
      end
      format.csv { render csv: @users.includes(:stripe_cards, :emburse_cards) }
    end
  end

  def stripe_cards
    @page = params[:page] || 1
    @per = params[:per] || 20

    @q = params[:q].presence

    @cards = StripeCard.includes(stripe_cardholder: :user).page(@page).per(@per).order("stripe_cards.created_at desc")

    @cards = @cards.joins(stripe_cardholder: :user).where("users.full_name ILIKE :query OR users.email ILIKE :query OR stripe_cards.last4 ILIKE :query", query: "%#{User.sanitize_sql_like(@q)}%") if @q
  end

  def bank_accounts
    relation = BankAccount

    @count = relation.count

    @bank_accounts = relation.all.order("id asc")

  end

  def raw_transactions
    @page = params[:page] || 1
    @per = params[:per] || 100
    @unique_bank_identifier = params[:unique_bank_identifier].presence

    relation = RawCsvTransaction
    relation = relation.where(unique_bank_identifier: @unique_bank_identifier) if @unique_bank_identifier

    @count = relation.count

    @raw_transactions = relation.page(@page).per(@per).order("date_posted desc")
  end

  def raw_transaction_new
  end

  def raw_transaction_create
    ::RawCsvTransactionService::Create.new(
      unique_bank_identifier: params[:unique_bank_identifier],
      date: params[:date],
      memo: params[:memo],
      amount: params[:amount]
    ).run

    redirect_to raw_transactions_admin_index_path, flash: { success: "Success" }
  rescue => e
    redirect_to raw_transaction_new_admin_index_path, flash: { error: e.message }
  end

  def raw_intrafi_transactions
    @page = params[:page] || 1
    @per = params[:per] || 100

    @count = RawIntrafiTransaction.count
    @imported = flash[:imported_transactions] || []
    @raw_imported_file = flash[:file]

    @raw_intrafi_transactions = RawIntrafiTransaction.page(@page).per(@per).order("date_posted desc")
  end

  def raw_intrafi_transactions_import
    file = params[:file].read.force_encoding("UTF-8")

    transactions = []

    CSV.parse(file, headers: true) do |row|
      date_posted, memo, amount = row.to_h.values
      transactions << {
        date_posted: Date.strptime(date_posted, "%m/%d/%Y"),
        memo:,
        amount_cents: (amount.to_f * 100).to_i
      }
    end

    raw_intrafi_transactions = []

    ActiveRecord::Base.transaction do
      transactions.each do |tx|
        date_posted, memo, amount_cents = tx.values_at(:date_posted, :memo, :amount_cents)

        unless RawIntrafiTransaction.where(date_posted:, memo:, amount_cents:).count > 0
          raw_intrafi_transactions << RawIntrafiTransaction.create!(date_posted:, memo:, amount_cents:)
        end
      end
    end

    duplicates = transactions.count - raw_intrafi_transactions.count

    redirect_to raw_intrafi_transactions_admin_index_path, flash: {
      success: "Successfully imported #{raw_intrafi_transactions.count} transactions (#{duplicates} duplicates)",
      imported_transactions: raw_intrafi_transactions.pluck(:id),
      file:
    }
  rescue => e
    redirect_to raw_intrafi_transactions_admin_index_path, flash: { error: e.message }
  end

  def ledger
    @page = params[:page] || 1
    @per = params[:per] || 100
    @q = params[:q].presence
    @amount = params[:amount].presence
    @unmapped = params[:unmapped] != "0"
    @exclude_top_ups = params[:exclude_top_ups] == "1" ? true : nil
    @exclude_spending = params[:exclude_spending] == "1" ? true : nil
    @mapped_by_human = params[:mapped_by_human] == "1" ? true : nil
    @event_id = params[:event_id].presence
    @user_id = params[:user_id].presence

    relation = CanonicalTransaction.left_joins(:canonical_event_mapping)

    if @event_id
      @event = Event.find(@event_id)

      relation = relation.where("canonical_event_mappings.event_id = ?", @event.id)
    end

    if @q
      relation = relation.search_memo(@q)
    end

    if @amount
      if @amount.match /\A\d+\z/
        amount_cents = @amount.to_i
        relation = relation.where("amount_cents = ? or amount_cents = ?", amount_cents, -amount_cents)
      else
        case @amount.delete(" ")
        when ">0", ">=0"
          relation = relation.where("amount_cents >= 0")
        when "<0", "<=0"
          relation = relation.where("amount_cents <= 0")
        end
      end
    end

    relation = relation.unmapped if @unmapped
    relation = relation.where("amount_cents >= 0") if @exclude_spending
    relation = relation.not_stripe_top_up if @exclude_top_ups
    relation = relation.mapped_by_human if @mapped_by_human

    if @user_id
      user = User.find(@user_id)
      sch_sid = user&.stripe_cardholder&.stripe_id
      relation = relation.stripe_transaction
                         .where("raw_stripe_transactions.stripe_transaction->>'cardholder' = ?", sch_sid)
    end

    @count = relation.count

    @canonical_transactions = relation.page(@page).per(@per).order(date: :desc)
  end

  def pending_ledger
    @page = params[:page] || 1
    @per = params[:per] || 100
    @q = params[:q].presence
    @unsettled = params[:unsettled] == "1" ? true : nil
    @event_id = params[:event_id].presence

    if @event_id
      @event = Event.find(@event_id)

      relation = @event.canonical_pending_transactions.includes(:canonical_pending_event_mapping)
    else
      relation = CanonicalPendingTransaction.includes(:canonical_pending_event_mapping)
    end

    if @q
      if @q.to_f.nonzero?
        @q = (@q.to_f * 100).to_i

        relation = relation.where("amount_cents = ? or amount_cents = ?", @q, -@q)
      else
        case @q.delete(" ")
        when ">0", ">=0"
          relation = relation.where("amount_cents >= 0")
        when "<0", "<=0"
          relation = relation.where("amount_cents <= 0")
        else
          relation = relation.search_memo(@q)
        end
      end
    end

    relation = relation.unsettled if @unsettled

    # Preload transaction categories
    relation = relation.preload(:category)

    @count = relation.count

    @canonical_pending_transactions = relation.page(@page).per(@per).order("date desc")
  end

  def ach
    @page = params[:page] || 1
    @per = params[:per] || 20
    @q = params[:q].presence
    @pending = params[:pending] == "1" ? true : nil

    @event_id = params[:event_id].presence

    if @event_id
      @event = Event.find(@event_id)

      relation = @event.ach_transfers.includes(:event)
    else
      relation = AchTransfer.includes(:event)
    end

    if @q
      if @q.to_f.nonzero?
        @q = (@q.to_f * 100).to_i

        relation = relation.where("amount = ? or amount = ?", @q, -@q)
      else
        case @q.delete(" ")
        when ">0", ">=0"
          relation = relation.where("amount >= 0")
        when "<0", "<=0"
          relation = relation.where("amount <= 0")
        else
          relation = relation.search_recipient(@q)
        end
      end
    end

    relation = relation.pending if @pending

    @count = relation.count
    @ach_transfers = relation.page(@page).per(@per).order(
      Arel.sql("aasm_state = 'pending' DESC"),
      "created_at desc"
    )

  end

  def reimbursements
    @page = params[:page] || 1
    @per = params[:per] || 20
    @q = params[:q].presence
    @pending = params[:pending] == "1" ? true : nil

    @event_id = params[:event_id].presence

    if @event_id
      @event = Event.find(@event_id)

      relation = @event.reimbursement_reports.includes(:event).visible
    else
      relation = Reimbursement::Report.includes(:event).visible
    end

    relation = relation.search(@q) if @q

    relation = relation.reimbursement_requested if @pending

    @count = relation.count
    @reports = relation.page(@page).per(@per).order(
      Arel.sql("aasm_state = 'reimbursement_requested' DESC"),
      # Arel.sql("aasm_state = 'draft' ASC"),
      "reimbursement_reports.created_at desc"
    )

  end

  def stripe_card_personalization_designs
    @page = params[:page] || 1
    @per = params[:per] || 20
    @q = params[:q].presence
    @pending = params[:pending] == "1"
    @unlisted = params[:unlisted] == "1"

    @event_id = params[:event_id].presence

    if @event_id
      @event = Event.find(@event_id)

      relation = @event.stripe_card_personalization_designs.includes(:event)
    else
      relation = StripeCard::PersonalizationDesign.includes(:event)
    end

    relation = relation.search(@q) if @q
    relation = relation.under_review if @pending
    relation = relation.unlisted if @unlisted

    @count = relation.count
    relation = relation.page(@page).per(@per).order(
      Arel.sql("stripe_status = 'review' DESC"),
      "stripe_card_personalization_designs.created_at desc"
    )

    @common_designs = StripeCard::PersonalizationDesign.includes(:event).common
    @designs = relation

  end

  def stripe_card_personalization_design_new
  end

  def stripe_card_personalization_design_create
    return unless params[:logo].present?

    ::StripeCardService::PersonalizationDesign::Create.new(
      file: params[:logo],
      color: params[:color].to_sym,
      name: params[:name],
      common: params[:common].to_i == 1,
    ).run

    redirect_to stripe_card_personalization_designs_admin_index_path, flash: { success: "Successfully created #{params[:name]}" }
  end

  def ach_start_approval
    @ach_transfer = AchTransfer.find(params[:id])

  end

  def ach_approve
    ach_transfer = AchTransfer.find(params[:id])
    ach_transfer.approve!(current_user)

    redirect_to ach_start_approval_admin_path(ach_transfer), flash: { success: "Success" }
  rescue Faraday::Error => e
    redirect_to ach_start_approval_admin_path(params[:id]), flash: { error: "Something went wrong: #{e.response_body["message"]}" }
  rescue => e
    redirect_to ach_start_approval_admin_path(params[:id]), flash: { error: e.message }
  end

  def ach_send_realtime
    ach_transfer = AchTransfer.find(params[:id])
    ach_transfer.approve!(current_user, send_realtime: true)

    redirect_to ach_start_approval_admin_path(ach_transfer), flash: { success: "Success - sent in realtime" }
  rescue Faraday::Error => e
    redirect_to ach_start_approval_admin_path(params[:id]), flash: { error: "Something went wrong: #{e.response_body["message"]}" }
  rescue => e
    redirect_to ach_start_approval_admin_path(params[:id]), flash: { error: e.message }
  end

  def ach_reject
    ach_transfer = AchTransfer.find(params[:id])
    ach_transfer.mark_rejected!(current_user)
    ach_transfer.local_hcb_code.comments.create(content: params[:comment], user: current_user, action: :rejected_transfer) if params[:comment]

    redirect_to ach_start_approval_admin_path(ach_transfer), flash: { success: "Success" }
  rescue => e
    redirect_to ach_start_approval_admin_path(params[:id]), flash: { error: e.message }
  end

  def disbursement_process
    @disbursement = Disbursement.find(params[:id])

  end

  def disbursement_approve
    disbursement = Disbursement.find(params[:id])

    disbursement.approve_by_admin(current_user)

    redirect_to disbursement_process_admin_path(disbursement), flash: { success: "Success" }
  rescue => e
    Rails.error.report(e)
    redirect_to disbursement_process_admin_path(params[:id]), flash: { error: e.message }
  end

  def disbursement_reject
    disbursement = Disbursement.find(params[:id])

    disbursement.mark_rejected!(current_user)

    disbursement.local_hcb_code.comments.create(content: params[:comment], user: current_user, action: :rejected_transfer) if params[:comment]

    redirect_to disbursement_process_admin_path(disbursement), flash: { success: "Success" }
  rescue => e
    Rails.error.report(e)
    redirect_to disbursement_process_admin_path(params[:id]), flash: { error: e.message }
  end

  def checks
    @page = params[:page] || 1
    @per = params[:per] || 20
    @q = params[:q].presence
    @in_transit = params[:in_transit] == "1" ? true : nil

    @event_id = params[:event_id].presence

    if @event_id
      @event = Event.find(@event_id)

      relation = @event.checks.includes(lob_address: :event)
    else
      relation = Check.includes(lob_address: :event)
    end

    if @q
      if @q.to_f.nonzero?
        @q = (@q.to_f * 100).to_i

        relation = relation.where("amount = ? or amount = ?", @q, -@q)
      else
        case @q.delete(" ")
        when ">0", ">=0"
          relation = relation.where("amount >= 0")
        when "<0", "<=0"
          relation = relation.where("amount <= 0")
        else
          relation = relation.search_recipient(@q)
        end
      end
    end

    relation = relation.in_transit if @in_transit

    @count = relation.count
    @checks = relation.page(@page).per(@per).order(
      Arel.sql("aasm_state = 'pending' DESC"),
      "created_at desc"
    )

  end

  def increase_checks
    @page = params[:page] || 1
    @per = params[:per] || 20
    @checks = IncreaseCheck.page(@page).per(@per).order(
      Arel.sql("aasm_state = 'pending' DESC"),
      "created_at desc"
    )

  end

  def increase_check_process
    @check = IncreaseCheck.find(params[:id])

  end

  def paypal_transfers
    @page = params[:page] || 1
    @per = params[:per] || 20
    @q = params[:q].presence
    @event_id = params[:event_id].presence

    @paypal_transfers = PaypalTransfer.all

    @paypal_transfers = @paypal_transfers.search_recipient(@q) if @q

    @paypal_transfers.where(event_id: @event_id) if @event_id

    @paypal_transfers = @paypal_transfers.page(@page).per(@per).order(
      Arel.sql("aasm_state = 'pending' DESC"),
      "created_at desc"
    )

  end

  def paypal_transfer_process
    @paypal_transfer = PaypalTransfer.find(params[:id])

  end

  def wires
    @page = params[:page] || 1
    @per = params[:per] || 20
    @q = params[:q].presence
    @event_id = params[:event_id].presence

    @wires = Wire.all

    @wires = @wires.search_recipient(@q) if @q

    @wires.where(event_id: @event_id) if @event_id

    @wires = @wires.page(@page).per(@per).order(
      Arel.sql("aasm_state = 'pending' DESC"),
      "created_at desc"
    )

  end

  def wise_transfers
    @page = params[:page] || 1
    @per = params[:per] || 20
    @q = params[:q].presence
    @event_id = params[:event_id].presence
    @status = WiseTransfer.aasm.states.collect(&:name).include?(params[:status]&.to_sym) ? params[:status] : nil

    @wise_transfers = WiseTransfer.all

    @wise_transfers = @wise_transfers.search_recipient(@q) if @q

    @wise_transfers = @wise_transfers.where(event_id: @event_id) if @event_id
    @wise_transfers = @wise_transfers.where(aasm_state: @status) if @status

    @wise_transfers = @wise_transfers.page(@page).per(@per).order(
      Arel.sql("aasm_state = 'pending' DESC"),
      Arel.sql("aasm_state = 'approved' DESC"),
      "created_at desc"
    )
  end

  def wire_process
    @wire = Wire.find(params[:id])
  end

  def wise_transfer_process
    @wise_transfer = WiseTransfer.find(params[:id])
  end

  def donations
    @page = params[:page] || 1
    @per = params[:per] || 20
    @q = params[:q].presence
    @ip_address = params[:ip_address].presence
    @user_agent = params[:user_agent].presence
    @deposited = params[:deposited] == "1" ? true : nil
    @in_transit = params[:in_transit] == "1" ? true : nil
    @failed = params[:failed] == "1" ? true : nil
    @missing_payout = params[:missing_payout] == "1" ? true : nil
    @missing_fee_reimbursement = params[:missing_fee_reimbursement] == "1" ? true : nil

    @event_id = params[:event_id].presence

    if @event_id
      @event = Event.find(@event_id)

      relation = @event.donations.includes(:event)
    else
      relation = Donation.includes(:event)
    end

    if @q
      if @q.to_f.nonzero?
        @q = (@q.to_f * 100).to_i

        relation = relation.where("amount = ? or amount = ?", @q, -@q)
      else
        relation = relation.search_name(@q)
      end
    end

    relation = relation.where(ip_address: @ip_address) if @ip_address
    relation = relation.where("user_agent ILIKE ?", "%#{Donation.sanitize_sql_like(@user_agent)}%") if @user_agent
    relation = relation.deposited if @deposited
    relation = relation.in_transit if @in_transit
    relation = relation.failed if @failed
    relation = relation.missing_payout if @missing_payout
    relation = relation.missing_fee_reimbursement if @missing_fee_reimbursement

    @count = relation.count
    @donations = relation.page(@page).per(@per).order("created_at desc")

  end

  def recurring_donations
    @active = params[:active] == "1" ? true : nil
    @canceled = params[:canceled] == "1" ? true : nil

    @event_id = params[:event_id].presence

    relation = RecurringDonation.includes(:event).where.not(stripe_status: [:incomplete, :incomplete_expired])

    relation = relation.active if @active
    relation = relation.canceled if @canceled

    relation = relation.where(event_id: @event_id) if @event_id

    @donations = relation.page(params[:page]).per(20).order(created_at: :desc)

  end

  def disbursements
    @page = params[:page] || 1
    @per = params[:per] || 20
    @q = params[:q].presence
    @reviewing = params[:reviewing] == "1" ? true : nil
    @pending = params[:pending] == "1" ? true : nil
    @processing = params[:processing] == "1" ? true : nil

    @event_id = params[:event_id].presence

    if @event_id
      @event = Event.find(@event_id)

      relation = @event.disbursements.includes(:event)
    else
      relation = Disbursement.includes(:event)
    end

    if @q
      if @q.to_f.nonzero?
        @q = (@q.to_f * 100).to_i

        relation = relation.where("amount = ? or amount = ?", @q, -@q)
      else
        relation = relation.search_name(@q)
      end
    end

    relation = relation.pending if @pending
    relation = relation.reviewing if @reviewing
    relation = relation.processing if @processing

    @count = relation.count
    @disbursements = relation.page(@page).per(@per).order(
      Arel.sql("aasm_state = 'reviewing' DESC"),
      "created_at desc"
    )

  end

  def disbursement_new
    redirect_to new_disbursement_path
  end

  def hcb_codes
    @params = params.permit(:page, :per, :q, :has_receipt, :start_date, :end_date)
    @page = @params[:page] || 1
    @per = @params[:per] || 20
    @q = @params[:q].presence
    @has_receipt = @params[:has_receipt]
    @start_date = @params[:start_date]
    @end_date = @params[:end_date]

    relation = HcbCode

    relation = relation.where("hcb_codes.hcb_code ILIKE ?", "%#{@q}%") if @q
    relation = relation.receipt_required.missing_receipt if @has_receipt == "no"
    relation = relation.has_receipt_or_marked_no_or_lost if @has_receipt == "yes"
    relation = relation.lost_receipt if @has_receipt == "lost"

    begin
      relation = relation.where("hcb_codes.created_at >= ?", Date.strptime(@start_date, "%Y-%m-%d").beginning_of_day) if @start_date.present?
      relation = relation.where("hcb_codes.created_at <= ?", Date.strptime(@end_date, "%Y-%m-%d").end_of_day) if @end_date.present?
    rescue Date::Error
      flash[:error] = "Invalid date."
    end

    @count = relation.count
    @hcb_codes = relation.order("hcb_codes.created_at desc")

    respond_to do |format|
      format.html do
        @hcb_codes = @hcb_codes.page(@page).per(@per)
      end
      format.csv { render csv: @hcb_codes }
    end
  end

  def invoices
    @page = params[:page] || 1
    @per = params[:per] || 20
    @q = params[:q].presence
    @open = params[:open] == "1" ? true : nil
    @paid = params[:paid] == "1" ? true : nil
    @missing_payout = params[:missing_payout] == "1" ? true : nil
    @missing_fee_reimbursement = params[:missing_fee_reimbursement] == "1" ? true : nil
    @past_due = params[:past_due] == "1" ? true : nil
    @voided = params[:voided] == "1" ? true : nil

    @event_id = params[:event_id].presence

    if @event_id
      @event = Event.find(@event_id)

      relation = @event.invoices
    else
      relation = Invoice
    end

    if @q
      if @q.to_f.nonzero?
        @q = (@q.to_f * 100).to_i

        relation = relation.where("amount_due = ? or amount_due = ?", @q, -@q)
      else
        relation = relation.search_description(@q)
      end
    end

    relation = relation.open_v2 if @open
    relation = relation.paid_v2 if @paid
    relation = relation.missing_payout if @missing_payout
    relation = relation.missing_fee_reimbursement if @missing_fee_reimbursement
    relation = relation.past_due if @past_due
    relation = relation.void_v2 if @voided


    @count = relation.count
    @invoices = relation.page(@page).per(@per).order(created_at: :desc)

  end

  def invoice_process
    @invoice = Invoice.find(params[:id])

  end

  def invoice_mark_paid
    @invoice = Invoice.open.find(params[:id])

    ::InvoiceService::MarkPaid.new(
      invoice_id: @invoice.id,
      reason: params[:reason],
      attachment: params[:attachment],
      user: current_user
    ).run

    redirect_to invoices_admin_index_path, flash: { success: "Success" }
  end

  def sponsors
    @page = params[:page] || 1
    @per = params[:per] || 20
    @q = params[:q].presence

    @event_id = params[:event_id].presence

    if @event_id
      @event = Event.find(@event_id)

      relation = @event.sponsors
    else
      relation = Sponsor
    end

    relation = relation.search_name(@q) if @q

    @count = relation.count
    @sponsors = relation.page(@page).per(@per).order("created_at desc")

  end

  def google_workspaces
    @page = params[:page] || 1
    @per = params[:per] || 20
    @q = params[:q].presence
    @needs_ops_review = params[:needs_ops_review] == "1" ? true : nil
    @configuring = params[:configuring] == "1" ? true : nil
    @verification_error = params[:verification_error] == "1" ? true : nil
    @revocation_present = params[:revocation_present] == "1" ? true : nil
    @pending_deletion = params[:pending_deletion] == "1" ? true : nil

    @event_id = params[:event_id].presence

    if @event_id
      @event = Event.find(@event_id)

      relation = @event.g_suites
    else
      relation = GSuite.includes(:event)
    end

    relation = relation.search_domain(@q) if @q
    relation = relation.needs_ops_review if @needs_ops_review
    relation = relation.configuring if @configuring
    relation = relation.verification_error if @verification_error
    relation = relation.where.associated(:revocation) if @revocation_present
    relation = relation.joins(:revocation).where(revocation: { aasm_state: "revoked" }) if @pending_deletion

    @count = relation.count
    @g_suites = relation.page(@page).per(@per).order("g_suites.created_at desc")

  end

  def google_workspace_process
    @g_suite = GSuite.find(params[:id])
  end

  def google_workspace_approve
    @g_suite = GSuite.find(params[:id])

    has_existing_key = @g_suite.verification_key.present?

    GSuite::SetVerificationKeyJob.perform_later(@g_suite.id)

    redirect_to google_workspace_process_admin_path(@g_suite), flash: { success: "#{has_existing_key ? 'Updated verification key' : 'Approved'} (it may take a few seconds for the dashboard to reflect this change)" }
  end

  def google_workspace_verify
    @g_suite = GSuite.find(params[:id])

    GSuiteService::Verify.new(g_suite_id: @g_suite.id).run

    redirect_to google_workspace_process_admin_path(@g_suite), flash: { success: "Verification in progress. It may take a few minutes for this domain to reflect an updated verification status." }
  end

  def google_workspaces_verify_all
    GSuite::VerifyAllJob.perform_later

    redirect_to google_workspaces_admin_index_path, flash: { success: "Verification in progress. It may take a few minutes for domains to reflect updated verification statuses." }
  end

  def google_workspace_update
    @g_suite = GSuite.find(params[:id])

    @g_suite = GSuiteService::Update.new(
      g_suite_id: @g_suite.id,
      domain: @g_suite.domain,
      verification_key: params[:verification_key],
      dkim_key: params[:dkim_key]
    ).run

    redirect_to google_workspace_process_admin_path(@g_suite), flash: { success: "Success" }
  end

  def google_workspace_toggle_revocation_immunity
    @g_suite = GSuite.find(params[:id])

    if @g_suite.update(immune_to_revocation: !@g_suite.immune_to_revocation)
      flash[:success] = "Revocation immunity was successfully updated."
    else
      flash[:error] = "Revocation immunity could not be updated."
    end
    redirect_to google_workspace_process_admin_path(@g_suite)
  end

  def set_event
    @canonical_transaction = ::CanonicalTransactionService::SetEvent.new(canonical_transaction_id: params[:id], event_id: params[:event_id], user: current_user).run

    redirect_to transaction_admin_path(@canonical_transaction)
  rescue => e
    redirect_to transaction_admin_path(params[:id]), flash: { error: e.message }
  end

  def set_event_multiple_transactions
    ActiveRecord::Base.transaction do
      params.each do |key, value|
        next unless value == "1" && CanonicalTransaction.find(key)

        begin
          @canonical_transaction = ::CanonicalTransactionService::SetEvent.new(
            canonical_transaction_id: key,
            event_id: params[:event_id],
            user: current_user
          ).run
        rescue => e
          return redirect_to ledger_admin_index_path, flash: { error: e.message }
        end
      end
    end
    redirect_back fallback_location: ledger_admin_index_path
  end

  def set_paypal_transfer
    ActiveRecord::Base.transaction do
      paypal_transfer = PaypalTransfer.find(params[:paypal_transfer_id])

      canonical_transaction = CanonicalTransactionService::SetEvent.new(
        canonical_transaction_id: params[:id],
        event_id: paypal_transfer.event.id,
        user: current_user
      ).run

      CanonicalPendingTransactionService::Unsettle.new(canonical_pending_transaction: paypal_transfer.canonical_pending_transaction).run

      CanonicalPendingTransactionService::Settle.new(
        canonical_transaction:,
        canonical_pending_transaction: paypal_transfer.canonical_pending_transaction
      ).run!

      canonical_transaction.update!(hcb_code: paypal_transfer.hcb_code, transaction_source_type: "PaypalTransfer", transaction_source_id: paypal_transfer.id)

      paypal_transfer.mark_deposited!

      redirect_to transaction_admin_path(canonical_transaction)
    end
  rescue => e
    redirect_to transaction_admin_path(params[:id]), flash: { error: e.message }
  end

  def set_wire
    ActiveRecord::Base.transaction do
      wire = Wire.find(params[:wire_id])

      canonical_transaction = CanonicalTransactionService::SetEvent.new(
        canonical_transaction_id: params[:id],
        event_id: wire.event.id,
        user: current_user
      ).run

      CanonicalPendingTransactionService::Settle.new(
        canonical_transaction:,
        canonical_pending_transaction: wire.canonical_pending_transaction
      ).run!

      canonical_transaction.update!(hcb_code: wire.hcb_code, transaction_source_type: "Wire", transaction_source_id: wire.id)

      wire.mark_deposited!

      redirect_to transaction_admin_path(canonical_transaction)
    end
  rescue => e
    redirect_to transaction_admin_path(params[:id]), flash: { error: e.message }
  end

  def set_wise_transfer
    ActiveRecord::Base.transaction do
      wise_transfer = WiseTransfer.find(params[:wise_transfer_id])

      canonical_transaction = CanonicalTransactionService::SetEvent.new(
        canonical_transaction_id: params[:id],
        event_id: wise_transfer.event.id,
        user: current_user
      ).run

      CanonicalPendingTransactionService::Settle.new(
        canonical_transaction:,
        canonical_pending_transaction: wise_transfer.canonical_pending_transaction
      ).run!

      canonical_transaction.update!(hcb_code: wise_transfer.hcb_code, transaction_source_type: "WiseTransfer", transaction_source_id: wise_transfer.id)

      wise_transfer.mark_deposited!

      redirect_to transaction_admin_path(canonical_transaction)
    end
  rescue => e
    redirect_to transaction_admin_path(params[:id]), flash: { error: e.message }
  end

  def audit
    @topups = StripeService::Topup.list[:data]
  end

  def bookkeeping
  end

  def request_balance_export
    ExportJob.perform_later(export_id: Export::Event::Balances.create(requested_by: current_user, end_date: params[:end_date].presence).id)
    flash[:success] = "We've emailed you an export of all HCB organizations' balances."
    redirect_back(fallback_location: root_path)
  end

  def balances
    @start_date = params[:start_date].present? ? Date.parse(params[:start_date]) : nil
    @end_date = params[:end_date].present? ? Date.parse(params[:end_date]) : nil
    @monthly_breakdown = params[:monthly_breakdown] || false

    if @start_date && @end_date && @start_date > @end_date
      flash[:info] = "Do you really want the Start Date to be after the End Date?"
    end

    @events = filtered_events

    render_balance = ->(event, type) {
      ApplicationController.helpers.render_money(event.send(type, start_date: @start_date, end_date: @end_date))
    }

    render_monthly_revenue = ->(event, year, month) {
      key = Date.new(year, month, 1).strftime("%Y-%m")
      ApplicationController.helpers.render_money(
        @monthly_revenue.dig(event.id, key) || 0
      )
    }

    # Must be wrapped in lambdas
    template = [
      ["ID", ->(e) { e.id }],
      [:organization, ->(e) { e.name }],
      [:current_balance, ->(e) { render_balance.call(e, :balance_v2_cents) }],
      [:total_expenses, ->(e) { render_balance.call(e, :settled_outgoing_balance_cents) }],
      [:total_income, ->(e) { render_balance.call(e, :settled_incoming_balance_cents) }]
    ]

    unless @monthly_breakdown
      template.append([:start_date, ->(_) { @start_date }])
      template.append([:end_date, ->(_) { @end_date }])
    end

    if @monthly_breakdown
      template.concat(
        [
          [:tags, ->(e) { e.event_tags.pluck(:name).join(",") }],
          [:joined, ->(e) { (e.activated_at || e.created_at).strftime("%Y-%m-%d") }],
        ]
      )
      @monthly_revenue =
        begin
          sql_query = CanonicalTransaction.joins(:canonical_event_mapping)
                                          .where("canonical_transactions.amount_cents > ?", 0)
                                          .group("canonical_event_mappings.event_id, date_trunc('month', canonical_transactions.created_at)")
                                          .select("date_trunc('month', canonical_transactions.created_at) AS month,
                               COALESCE(SUM(canonical_transactions.amount_cents), 0) AS revenue,
                               canonical_event_mappings.event_id AS event_id")
                                          .to_sql
          ActiveRecord::Base.connection.exec_query(sql_query).each_with_object({}) do |item, result|
            result[item["event_id"]] ||= {}
            result[item["event_id"]][item["month"].strftime("%Y-%m")] = item["revenue"].to_i
          end
        end
      monthly_revenue_columns = (2018..Date.current.year).flat_map do |year|
        (1..12).take_while { |month| (year == Date.current.year && month <= Date.current.month) || year < Date.current.year }
               .map { |month| ["#{Date::ABBR_MONTHNAMES[month]} #{year} Income", ->(e) { render_monthly_revenue.call(e, year, month) }] }
      end

      template.concat(monthly_revenue_columns.reverse)
    end

    serializer = ->(event) do
      template.to_h.transform_values do |field|
        field.call(event)
      end
    end

    @data = @events.map { |event| serializer.call(event) }
    header_syms = template.transpose.first
    @headers = header_syms.map { |h| h.is_a?(String) ? h : h.to_s.titleize(keep_id_suffix: true) }
    @rows = @data.map { |d| d.values }
    @count = @rows.count

    respond_to do |format|
      format.html do
      end

      filename = "balances_#{Time.now.strftime("%Y_%m_%d %H_%M_%S")}"

      format.csv do
        require "csv"

        csv = Enumerator.new do |y|
          y << ::CSV::Row.new(header_syms, ["", "Report generated on #{Time.now.in_time_zone('Eastern Time (US & Canada)').strftime("%Y-%m-%d at %l:%M %p %Z")}"], true).to_s
          y << ::CSV::Row.new(header_syms, @headers, true).to_s

          @rows.each do |row|
            y << ::CSV::Row.new(header_syms, row).to_s
          end
        end

        stream_data("text/csv", "#{filename}.csv", csv)
      end

      format.json do
        stream_data("application/json", "#{filename}.json", @data.to_json, false)
      end

    end
  end

  def hq_receipts
    @page = params[:page] || 1
    @per = params[:per] || 20
    @users = User.where(id: Event.omitted.includes(:users).flat_map(&:users).map(&:id)).page(@page).per(@per).order(created_at: :desc)

  end

  def account_numbers
    @page = params[:page] || 1
    @per = params[:per] || 20
    @q = params[:q].presence
    @event_id = params[:event_id].presence
    @account_number_type = params[:account_number_type].presence # default/nil = show all, 1 = deposit only, 2 = spend + deposit

    relation = Column::AccountNumber.includes(:event)

    if @event_id
      relation = relation.where(event_id: @event_id)
    end

    if @account_number_type == "1"
      relation = relation.where(deposit_only: true)
    elsif @account_number_type == "2"
      relation = relation.where(deposit_only: false)
    end

    relation = relation.where(account_number: @q) if @q

    @count = relation.count
    @account_numbers = relation.page(@page).per(@per).order("events.id desc")

  end

  def email
    @message = Ahoy::Message.find(params[:message_id])
  end

  def email_html
    @message_id = params[:message_id]

    respond_to do |format|
      format.html { render html: Ahoy::Message.find(@message_id).html_content.html_safe } # rubocop:disable Rails/OutputSafety
    end
  end

  def emails
    @page = params[:page] || 1
    @per = params[:per] || 100
    @q = params[:q].presence
    @user_id = params[:user_id]
    @to = params[:to].presence

    messages = Ahoy::Message.all
    messages = messages.where(user: User.find(@user_id)) if @user_id.present?
    messages = messages.where(to: @to) if @to
    messages = messages.search_subject(@q) if @q

    @count = messages.count

    @messages = messages.page(@page).per(@per).order(sent_at: :desc)
  end

  def unknown_merchants
    @merchants = Rails.cache.fetch("admin_unknown_merchants", expires_in: 12.hours) do
      RawStripeTransaction.all.group_by { |rst| rst.stripe_transaction["merchant_data"]["network_id"] }.map do |network_id, rsts|
        memos = rsts.map do |rst|
          {
            memo: rst.stripe_transaction["merchant_data"]["name"],
            url: rst.stripe_transaction["merchant_data"]["url"],
            authorization: rst.stripe_authorization_id
          }
        end.uniq { |memo| memo[:memo] }

        memos = memos.map do |memo|
          memo[:occurrences] = memos.count { |m| m[:memo] == memo[:memo] }

          memo
        end.sort_by{ |memo| memo[:occurrences] }

        {
          network_id:,
          memos:,
          total_transactions: rsts.count,
        }
      end.reject { |data| data[:total_transactions] < 30 || YellowPages::Merchant.lookup(network_id: data[:network_id]).in_dataset? }.sort_by { |data| data[:total_transactions] }.reverse
    end
  end

  def merchant_memo_check
    @data = YellowPages::Merchant.merchants.map do |network_id, merchant|
      {
        yp_name: merchant[:name],
        yp_network_id: network_id,
        memos: RawStripeTransaction
          .where("stripe_transaction->'merchant_data'->>'network_id' = ?", network_id)
          .pluck(Arel.sql("distinct(stripe_transaction->'merchant_data'->'name')"))
      }
    end
  end

  def employees
    @page = params[:page] || 1
    @per = params[:per] || 20
    @employees = Employee.all.page(@page).per(@per).order(
      Arel.sql("aasm_state = 'onboarding' DESC"),
      "employees.created_at desc"
    )
  end

  def employee_payments
    @page = params[:page] || 1
    @per = params[:per] || 20
    @payments = Employee::Payment.all.page(@page).per(@per)
  end

  def my_ip
    render json: {
      remote_ip: request.remote_ip,
      ip: request.ip,
      forwarded_for: request.headers["HTTP_X_FORWARDED_FOR"],
      forwarded_port: request.headers["HTTP_X_FORWARDED_PORT"],
      forwarded_proto: request.headers["HTTP_X_FORWARDED_PROTO"],
    }
  end

  def referral_programs
    @referral_programs = Referral::Program.all.order(created_at: :desc)
  end

  def referral_program_create
    @referral_program = Referral::Program.new(name: params[:name])

    if @referral_program.save
      redirect_to referral_programs_admin_index_path, flash: { success: "Referral program created successfully." }
    else
      flash[:error] = @referral_program.errors.full_messages.to_sentence
      redirect_to referral_programs_admin_index_path
    end
  end

  def active_teenagers_leaderboard
  end

  private

  def stream_data(content_type, filename, data, download = true)
    headers["Content-Type"] = content_type
    headers["Content-disposition"] = "#{download ? 'attachment; ' : ''}filename=#{filename}"
    headers["X-Accel-Buffering"] = "no"
    headers.delete("Content-Length")

    response.status = 200
    self.response_body = data
  end

  def filtered_events(events: Event.all)
    @q = params[:q].presence
    @demo_mode = params[:demo_mode].presence || "full" # full accounts only by default
    @engaged = params[:engaged] == "1" # unchecked by default
    @pending = params[:pending] == "0" ? nil : true # checked by default
    @unapproved = params[:unapproved] == "0" ? nil : true # checked by default
    @approved = params[:approved] == "0" ? nil : true # checked by default
    @rejected = params[:rejected] == "0" ? nil : true # checked by default
    @transparent = params[:transparent].presence || "both" # both by default
    @omitted = params[:omitted].presence || "both" # both by default
    @funded = params[:funded].presence || "both" # both by default
    @hidden = params[:hidden].presence || "both" # both by default
    @active = params[:active].presence || "both" # both by default
    @organized_by = params[:organized_by].presence || "anyone"
    @tagged_with = params[:tagged_with].presence || "anything"
    @risk_level = params[:risk_level].presence || "any"
    @point_of_contact_id = params[:point_of_contact_id].presence || "all"
    @plan = params[:plan].presence || "all"
    if params[:country] == 9999.to_s
      @country = 9999
    else
      @country = params[:country].presence || "all"
    end
    @activity_since_date = params[:activity_since]
    @sort_by = params[:sort_by].presence || "date_desc"

    relation = events

    # Omit orgs if they were created after the end date
    relation = relation.where("events.created_at <= ?", @end_date) if @end_date
    relation = relation.search_name(@q) if @q
    relation = relation.engaged if @engaged
    relation = relation.transparent if @transparent == "transparent"
    relation = relation.not_transparent if @transparent == "not_transparent"
    relation = relation.omitted if @omitted == "omitted"
    relation = relation.not_omitted if @omitted == "not_omitted"
    relation = relation.hidden if @hidden == "hidden"
    relation = relation.not_hidden if @hidden == "not_hidden"
    relation = relation.active if @active == "active"
    relation = relation.inactive if @hidden == "inactive"
    relation = relation.funded if @funded == "funded"
    relation = relation.not_funded if @funded == "not_funded"
    relation = relation.organized_by_hack_clubbers if @organized_by == "hack_clubbers"
    relation = relation.organized_by_teenagers if @organized_by == "teenagers"
    relation = relation.not_organized_by_teenagers if @organized_by == "adults"
    relation = relation.demo_mode if @demo_mode == "demo"
    relation = relation.not_demo_mode if @demo_mode == "full"
    relation = relation.includes(:event_tags)
    relation = relation.where(event_tags: { id: @tagged_with }) unless @tagged_with == "anything"
    case @risk_level
    when "any"
      # don't filter
    when "unset"
      relation = relation.where(risk_level: nil)
    else
      relation = relation.where(risk_level: @risk_level)
    end
    relation = relation.where(id: events.joins(:canonical_transactions).where("canonical_transactions.date >= ?", @activity_since_date)) if @activity_since_date.present?
    if @plan != "all"
      relation = relation.where(id: events.joins("LEFT JOIN event_plans on event_plans.event_id = events.id")
                         .where("event_plans.aasm_state = 'active' AND event_plans.type = ?", @plan))
    end
    relation = relation.where(point_of_contact_id: @point_of_contact_id) if @point_of_contact_id != "all"
    if @country == 9999
      relation = relation.where.not(country: "US")
    elsif @country != "all"
      relation = relation.where(country: @country)
    end

    states = []
    states << "pending" if @pending
    states << "unapproved" if @unapproved
    states << "approved" if @approved
    states << "rejected" if @rejected
    relation = relation.where("events.aasm_state in (?)", states)

    # Sorting
    case @sort_by
    when "balance_asc"
      relation = @csv_export ? relation.sort_by(&:balance_v2_cents) : Kaminari.paginate_array(relation.sort_by(&:balance_v2_cents))
    when "balance_desc"
      relation = @csv_export ? relation.sort_by(&:balance_v2_cents).reverse! : Kaminari.paginate_array(relation.sort_by(&:balance_v2_cents).reverse!)
    else # Default sort is "date_desc"
      relation = relation.reorder(Arel.sql("COALESCE(events.activated_at, events.created_at) desc"))
    end
  end

  include StaticPagesHelper # for airtable_info

  def airtable_task_size(task_name)
    info = airtable_info[task_name]

    client = Faraday.new do |c|
      c.response :json
      c.response :raise_error
      c.authorization :Bearer, Credentials.fetch(:AIRTABLE)
    end

    task = client.get("https://api.airtable.com/v0/#{info[:id]}/#{info[:table]}", info[:query]).body["records"]
    task.size
  rescue => e
    Rails.error.report(e)
    9999 # return something invalidly high to get the ops team to report it
  end

  def pending_identity_vault_verifications_task_size
    client = Faraday.new do |c|
      c.response :json
      c.response :raise_error
    end

    client.get("https://identity.hackclub.com/api/v1/hcb").body["pending"] || 0
  end

  def hackathons_task_size
    hackathons = Faraday
                 .new(ssl: { verify: false }) { |c| c.response :json }
                 .get("https://dash.hackathons.hackclub.com/api/v1/stats/hackathons")
                 .body

    hackathons.dig("status", "pending", "meta", "count")
  rescue => e
    Rails.error.report(e)
    9999
  end

  def pending_task(task_name)
    @pending_tasks ||= {}
    @pending_tasks[task_name] ||= begin
      case task_name
      when :pending_hackathons_airtable
        hackathons_task_size
      when :pending_bank_applications_airtable
        airtable_task_size :bank_applications
      when :pending_onboard_id_airtable
        airtable_task_size :onboard_id
      when :pending_stickers_airtable
        airtable_task_size :stickers
      when :pending_onepassword_airtable
        airtable_task_size :onepassword
      when :pending_domains_airtable
        airtable_task_size :domains
      when :pending_pvsa_airtable
        airtable_task_size :pvsa
      when :pending_theeventhelper_airtable
        airtable_task_size :theeventhelper
      when :pending_wire_transfers_airtable
        airtable_task_size :wire_transfers
      when :pending_disputed_transactions_airtable
        airtable_task_size :disputed_transactions
      when :pending_feedback_airtable
        airtable_task_size :feedback
      when :pending_google_workspace_waitlist_airtable
        airtable_task_size :google_workspace_waitlist
      when :pending_boba_airtable
        airtable_task_size :boba
      when :pending_you_ship_we_ship_airtable
        airtable_task_size :you_ship_we_ship
      when :pending_identity_vault_verifications
        pending_identity_vault_verifications_task_size
      when :emburse_card_requests
        EmburseCardRequest.under_review.size
      when :emburse_transactions
        EmburseTransaction.under_review.size
      when :checks
        # Check.pending.size + Check.unfinished_void.size
        0
      when :ach_transfers
        AchTransfer.pending.size
      when :negative_events
        Event.negatives.size
      when :fee_reimbursements
        FeeReimbursement.unprocessed.size
      when :emburse_transfers
        EmburseTransfer.under_review.size
      when :g_suite_accounts
        GSuiteAccount.under_review.size
      when :transactions
        Transaction.needs_action.size
      when :disbursements
        Disbursement.pending.size
      when :organizer_position_deletion_requests
        OrganizerPositionDeletionRequest.under_review.size
      else
        # failed to get task size
      end
    end

    @pending_tasks[task_name]
  end

  def pending_tasks
    # This method could take upwards of 10 seconds. USE IT SPARINGLY
    pending_task :pending_hackathons_airtable
    pending_task :pending_bank_applications_airtable
    pending_task :pending_onboard_id_airtable
    pending_task :pending_stickers_airtable
    pending_task :pending_onepassword_airtable
    pending_task :pending_domains_airtable
    pending_task :pending_pvsa_airtable
    pending_task :pending_theeventhelper_airtable
    pending_task :pending_feedback_airtable
    pending_task :wire_transfers
    pending_task :paypal_transfers
    pending_task :disputed_transactions_airtable
    pending_task :emburse_card_requests
    pending_task :checks
    pending_task :ach_transfers
    pending_task :negative_events
    pending_task :fee_reimbursements
    pending_task :emburse_transfers
    pending_task :emburse_transactions
    pending_task :g_suite_accounts
    pending_task :transactions
    pending_task :disbursements
    pending_task :organizer_position_deletion_requests

    @pending_tasks
  end

end
