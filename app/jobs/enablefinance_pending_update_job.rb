# Confirms stale Enable Banking pending transactions as a daily fallback.
#
# Primary mechanism: The importer's C5 logic detects silently settled
# transactions in real-time during each sync by comparing stored pending
# entries against the bank's current PDNG feed.
#
# This job is the safety net: if syncs have not run for a while, any
# Enable Banking pending transaction older than the configured threshold
# (default: 2 days, per PSD2 settlement norms) is auto-confirmed by
# clearing its pending flag.
class EnablefinancePendingUpdateJob < ApplicationJob
  queue_as :scheduled

  def perform
    items_processed = 0
    total_confirmed = 0

    EnableBankingItem.active.find_each do |item|
      result = item.confirm_stale_pending_transactions!
      items_processed += 1
      total_confirmed += result[:total_confirmed]
    rescue => e
      Rails.logger.error(
        "EnablefinancePendingUpdateJob - Failed for item #{item.id}: #{e.message}"
      )
    end

    if total_confirmed > 0
      Rails.logger.info(
        "EnablefinancePendingUpdateJob - Confirmed #{total_confirmed} stale pending " \
        "transaction(s) across #{items_processed} item(s)"
      )
    end
  end
end
