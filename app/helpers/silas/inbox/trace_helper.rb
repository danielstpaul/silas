module Silas
  module Inbox
    module TraceHelper
      STATUS_CLASS = {
        "queued" => "pill-grey", "running" => "pill-blue pill-pulse",
        "waiting" => "pill-amber", "in_doubt" => "pill-amber",
        "completed" => "pill-green", "failed" => "pill-red", "canceled" => "pill-red",
        # tool-invocation statuses
        "pending" => "pill-grey", "started" => "pill-blue", "declined" => "pill-red",
        "approved" => "pill-green", "required" => "pill-amber", "expired" => "pill-red"
      }.freeze

      def status_pill(status)
        tag.span(status.to_s.tr("_", " "), class: "pill #{STATUS_CLASS[status.to_s] || 'pill-grey'}")
      end

      def step_text(step)
        Array(step.response_blocks).select { |b| b["type"] == "text" }.map { |b| b["text"] }.join.presence
      end

      def pretty_args(hash)
        JSON.pretty_generate(hash || {})
      end

      def cost_label(cost)
        tokens = "#{number_with_delimiter(cost[:input_tokens])} in / #{number_with_delimiter(cost[:output_tokens])} out"
        money = Silas::Inbox::Cost.format(cost[:microcents])
        if cost[:unpriced] || money.nil?
          "#{tokens} · cost unavailable"
        else
          "#{tokens} · #{money}"
        end
      end

      def relative_time(time)
        return "" unless time

        "#{time_ago_in_words(time)} ago"
      end
    end
  end
end
