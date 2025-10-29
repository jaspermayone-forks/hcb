# frozen_string_literal: true

# == Schema Information
#
# Table name: reimbursement_reports
#
#  id                         :bigint           not null, primary key
#  aasm_state                 :string
#  conversion_rate            :float            default(1.0), not null
#  currency                   :string           default("USD"), not null
#  deleted_at                 :datetime
#  expense_number             :integer          default(0), not null
#  invite_message             :text
#  maximum_amount_cents       :integer
#  name                       :text
#  reimbursed_at              :datetime
#  reimbursement_approved_at  :datetime
#  reimbursement_requested_at :datetime
#  rejected_at                :datetime
#  submitted_at               :datetime
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#  event_id                   :bigint
#  invited_by_id              :bigint
#  reviewer_id                :bigint
#  user_id                    :bigint           not null
#
# Indexes
#
#  index_reimbursement_reports_on_event_id       (event_id)
#  index_reimbursement_reports_on_invited_by_id  (invited_by_id)
#  index_reimbursement_reports_on_reviewer_id    (reviewer_id)
#  index_reimbursement_reports_on_user_id        (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (event_id => events.id)
#  fk_rails_...  (invited_by_id => users.id)
#  fk_rails_...  (user_id => users.id)
#
module Reimbursement
  class Report < ApplicationRecord
    include ::Shared::AmpleBalance

    include PublicIdentifiable
    set_public_id_prefix :rmr

    belongs_to :user

    belongs_to :event, optional: true

    validate do
      unless draft? || event.present?
        errors.add(:base, "non-draft reports must belong to an event")
      end
    end

    validates :name, no_urls: true, if: ->(report){ report.from_public_reimbursement_form? }

    belongs_to :inviter, class_name: "User", foreign_key: "invited_by_id", optional: true, inverse_of: :created_reimbursement_reports
    belongs_to :reviewer, class_name: "User", optional: true, inverse_of: :assigned_reimbursement_reports

    has_paper_trail ignore: :expense_number

    monetize :maximum_amount_cents, allow_nil: true
    monetize :amount_to_reimburse_cents, allow_nil: true, with_model_currency: :currency
    monetize :amount_cents, as: "amount", allow_nil: true, with_model_currency: :currency
    validates :maximum_amount_cents, numericality: { greater_than: 0 }, allow_nil: true
    has_many :expenses, foreign_key: "reimbursement_report_id", inverse_of: :report, dependent: :delete_all
    has_one :payout_holding, inverse_of: :report
    alias_attribute :report_name, :name
    attribute :name, :string, default: -> { "Expenses from #{Time.now.strftime("%B %e, %Y")}" }

    scope :search, ->(q) { joins("LEFT JOIN users AS u2 on u2.id = reimbursement_reports.user_id").where("u2.full_name ILIKE :query OR reimbursement_reports.name ILIKE :query", query: "%#{User.sanitize_sql_like(q)}%") }
    scope :pending, -> { where(aasm_state: ["draft", "submitted", "reimbursement_requested"]) }
    scope :to_calculate_total, -> { where.not(aasm_state: ["rejected"]) }
    scope :visible, -> { joins(:user).where.not(user: { full_name: nil }, invited_by_id: nil) }
    # view https://github.com/hackclub/hcb/issues/8486 for context behind this scope

    include AASM
    include Commentable
    include Hashid::Rails

    include PublicActivity::Model
    tracked owner: proc{ |controller, record| controller&.current_user }, recipient: proc { |controller, record| record.user }, event_id: proc { |controller, record| record.event&.id }, only: [:create]

    include TouchHistory

    broadcasts_refreshes_to ->(report) { report.was_touched? ? :_noop : report }

    acts_as_paranoid

    after_create_commit do
      ReimbursementMailer.with(report: self).invitation.deliver_later if inviter != user
      Reimbursement::OneDayReminderJob.set(wait: 1.day).perform_later(self) if Flipper.enabled?(:reimbursement_reminders_2025_01_21, user)
      Reimbursement::SevenDaysReminderJob.set(wait: 7.days).perform_later(self) if Flipper.enabled?(:reimbursement_reminders_2025_01_21, user)
    end

    aasm timestamps: true do
      state :draft, initial: true
      state :submitted
      state :reimbursement_requested
      state :reimbursement_approved
      state :reimbursed
      state :rejected
      state :reversed

      event :mark_submitted do
        transitions from: [:draft, :reimbursement_requested], to: :submitted do
          guard do
            user.payout_method.present? && event && !exceeds_maximum_amount? && !below_minimum_amount? &&
              expenses.any? && !missing_receipts? && !event.financially_frozen? && expenses.none? { |e| e.amount.zero? } &&
              !mismatched_currency? && payout_method_allowed?
          end
        end
        after do
          if team_review_required?
            ReimbursementMailer.with(report: self).review_requested.deliver_later
            create_activity(key: "reimbursement_report.review_requested", owner: user, recipient: reviewer.presence || event, event_id: event.id)
          else
            expenses.pending.each do |expense|
              expense.mark_approved!
            end
            self.mark_reimbursement_requested!
          end
        end
      end

      event :mark_reimbursement_requested do
        transitions from: :submitted, to: :reimbursement_requested do
          guard do
            expenses.approved.count > 0 && amount_to_reimburse > 0 && (!maximum_amount_cents || currency != "USD" || expenses.approved.sum(:amount_cents) <= maximum_amount_cents) && event && (currency != "USD" || Shared::AmpleBalance.ample_balance?(amount_to_reimburse_cents, event)) && !event.financially_frozen?
          end
        end
        after do
          # Reimbursement::NightlyJob.perform_later
        end
      end

      event :mark_reimbursement_approved do
        transitions from: :reimbursement_requested, to: :reimbursement_approved do
          guard do
            expenses.approved.count > 0 && amount_to_reimburse > 0 && (!maximum_amount_cents || currency != "USD" || expenses.approved.sum(:amount_cents) <= maximum_amount_cents) && (currency != "USD" || Shared::AmpleBalance.ample_balance?(expenses.approved.sum(:amount_cents), event)) && !event.financially_frozen?
          end
        end
        after do
          ReimbursementMailer.with(report: self).reimbursement_approved.deliver_later
          create_activity(key: "reimbursement_report.approved", owner: user)
          reimburse!
        end
      end

      event :mark_rejected do
        transitions from: [:draft, :submitted, :reimbursement_requested], to: :rejected
        after do |skip_mailer: false|
          ReimbursementMailer.with(report: self).rejected.deliver_later unless skip_mailer
        end
      end

      event :mark_draft do
        transitions from: [:submitted, :reimbursement_requested, :rejected], to: :draft
      end

      event :mark_reimbursed do
        transitions from: :reimbursement_approved, to: :reimbursed
      end

      event :mark_reversed do
        transitions from: :reimbursed, to: :reversed
      end
    end

    def status_text
      return "Review Requested" if submitted?
      return "Processing" if reimbursement_requested?
      return "⚠️ Processing" if reimbursed? && payout_holding&.failed?
      return "In Transit" if reimbursement_approved?
      return "In Transit" if reimbursed? && !payout_holding.sent?
      return "Canceled" if reversed?

      aasm_state.humanize.titleize
    end

    def admin_status_text
      return "HCB Review Requested" if reimbursement_requested?
      return "Organizers Reviewing" if submitted?

      status_text
    end

    def status_color
      return "muted" if draft?
      return "info" if submitted?
      return "error" if rejected?
      return "purple" if reimbursement_requested?
      return "warning" if reimbursed? && payout_holding&.failed? || reversed?
      return "success" if reimbursement_approved? || reimbursed?

      return "primary"
    end

    def status_description
      return "Review requested from #{event.name}" if submitted?
      return "HCB is reviewing this report" if reimbursement_requested?

      nil
    end

    def initiated_transfer_text
      if payout_holding&.payout_transfer.is_a?(IncreaseCheck)
        return "mailed"
      end

      return "initiated"
    end

    def transfer_text
      case payout_holding&.payout_transfer
      when AchTransfer
        return "ACH transfer"
      when PaypalTransfer
        return "PayPal transfer"
      when IncreaseCheck
        return "check"
      when WiseTransfer
        return "Wise transfer"
      when Wire
        return "international wire"
      end

      return "transfer"
    end

    def locked?
      !draft?
    end

    def unlockable?
      submitted? || reimbursement_requested?
    end

    def closed?
      reimbursement_approved? || reimbursed? || rejected? || reversed?
    end

    def amount_cents
      return amount_to_reimburse_cents if reimbursement_requested? || reimbursement_approved? || reimbursed?

      expenses.to_sum.sum(:amount_cents)
    end

    def amount_to_reimburse_cents
      return [expenses.approved.to_sum.sum(:amount_cents), maximum_amount_cents].min if maximum_amount_cents && currency == "USD"

      expenses.approved.to_sum.sum(:amount_cents)
    end

    def fees_charged_cents
      expenses.approved.where(type: Reimbursement::Expense::Fee.name).sum(:amount_cents)
    end

    def last_reimbursement_requested_by
      last_user_change_to(aasm_state: "reimbursement_requested")
    end

    def last_reimbursement_approved_by
      last_user_change_to(aasm_state: "reimbursement_approved")
    end

    def last_rejected_by
      last_user_change_to(aasm_state: "rejected")
    end

    def comment_recipients_for(comment)
      users = []
      users += self.comments.map(&:user)
      users += self.comments.flat_map(&:mentioned_users)
      users << self.user
      users += User.where(id: self.versions.pluck(:whodunnit))

      if comment.admin_only?
        users << self.event.point_of_contact if self.event
        return users.uniq.select(&:auditor?).reject(&:no_threads?).excluding(comment.user).collect(&:email_address_with_name)
      end

      users.uniq.excluding(comment.user).reject(&:no_threads?).collect(&:email_address_with_name)
    end

    def comment_mentionable(current_user: nil)
      users = []
      users += self.comments.includes(:user).map(&:user)
      users += self.comments.flat_map(&:mentioned_users)
      users += self.event.users if self.event
      users << self.user

      users.uniq
    end

    def comment_mailer_subject
      return "New comment on #{self.name}."
    end

    def initial_draft?
      draft? && submitted_at.nil?
    end

    def team_review_required?
      !event.users.include?(user) || !OrganizerPosition.role_at_least?(user, event, :manager) || (event.reimbursements_require_organizer_peer_review && event.users.size > 1)
    end

    def reimbursement_confirmation_message
      return nil if expenses.pending.none?

      "#{expenses.pending.count} #{"expense".pluralize(expenses.pending.count)} #{expenses.pending.count == 1 ? "hasn't" : "haven't"} been approved; if you continue, #{expenses.pending.count == 1 ? "it" : "these"} will not be reimbursed."
    end

    def missing_receipts?
      expenses.complete.with_receipt.count != expenses.count
    end

    def mismatched_currency?
      user.payout_method.present? && currency != user.payout_method.currency
    end

    def exceeds_maximum_amount?
      maximum_amount_cents && amount_cents > maximum_amount_cents && currency == "USD"
    end

    def below_minimum_amount?
      user.payout_method.is_a?(User::PayoutMethod::Wire) && amount_cents < event.minimum_wire_amount_cents
    end

    def from_public_reimbursement_form?
      invited_by_id.nil?
    end

    def wise_transfer_quote_amount
      @wise_transfer_quote_amount ||= WiseTransfer.generate_quote(amount)
    rescue
      Money.from_cents(0)
    end

    def wise_transfer_quote_without_fees_amount
      @wise_transfer_quote_without_fees_amount ||= WiseTransfer.generate_detailed_quote(amount)[:without_fees_usd_amount]
    rescue
      Money.from_cents(0)
    end

    def wise_transfer_may_exceed_balance?
      !::Shared::AmpleBalance.ample_balance?(wise_transfer_quote_amount.cents, event)
    end

    def convert_to_wise_transfer!(as: User.system_user)
      raise "Can only convert reports in 'Reimbursement Requested' state" unless reimbursement_requested?

      account_holder =
        if user.payout_method.respond_to?(:account_holder)
          user.payout_method.account_holder.presence
        end

      ActiveRecord::Base.transaction do
        wise_transfer = WiseTransfer.create!(
          user: as,
          event:,
          amount:,
          currency:,
          payment_for: name,
          recipient_name: account_holder || user.full_name,
          recipient_email: user.email,
          address_city: user.payout_method.address_city,
          address_line1: user.payout_method.address_line1,
          address_line2: user.payout_method.address_line2,
          address_postal_code: user.payout_method.address_postal_code,
          address_state: user.payout_method.address_state,
          bank_name: user.payout_method.bank_name,
          recipient_country: user.payout_method.recipient_country,
          recipient_information: user.payout_method.recipient_information,
        )

        comments.create!(content: "Converted to Wise transfer by @#{as.email} for processing: #{Rails.application.routes.url_helpers.hcb_code_url(wise_transfer.local_hcb_code)}", user: User.system_user)
        wise_transfer.local_hcb_code.comments.create!(content: "Created from reimbursement report #{Rails.application.routes.url_helpers.reimbursement_report_url(hashid)}", user: User.system_user)

        expenses.each do |expense|
          expense.receipts.each do |receipt|
            ::ReceiptService::Create.new(
              receiptable: wise_transfer.local_hcb_code,
              uploader: as,
              attachments: [receipt.file.blob],
              upload_method: :duplicate
            ).run!
          end
        end

        mark_rejected!(skip_mailer: true)

        wise_transfer
      end
    end

    private

    def last_user_change_to(...)
      user_id = versions.where_object_changes_to(...).last&.whodunnit

      user_id && User.find(user_id)
    end

    def reimburse!
      expense_payouts = []

      expenses.approved.each do |expense|
        expense_payouts << Reimbursement::ExpensePayout.create!(amount_cents: -(expense.amount_cents * expense.conversion_rate).floor, event: expense.report.event, expense:)
      end

      return if expense_payouts.empty?

      Reimbursement::PayoutHolding.create!(
        expense_payouts:,
        amount_cents: expense_payouts.sum { |payout| -payout.amount_cents },
        report: self
      )

      mark_reimbursed!
    end

    def payout_method_allowed?
      user.payout_method.present? && !user.payout_method.unsupported?
    end

  end
end
