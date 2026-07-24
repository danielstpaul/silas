module Silas
  # Base class for agent tools. The keyword signature of #call IS the schema:
  #
  #   class Agent::Tools::IssueRefund < Silas::Tool
  #     description "Refund an order."
  #     param :amount, :integer, desc: "Pence"   # optional type refinement
  #     approval :always                          # :never | :once | :always | lambda
  #     transactional!                            # or at_most_once! (default) / idempotent!
  #
  # :once approves ONE (tool, arguments) pair per session — an identical repeat
  # call skips re-approval; different arguments park again. For graded gates
  # (e.g. auto-approve under a threshold) use a lambda:
  #   approval ->(session:, input:) { input[:amount] > 5000 ? :user_approval : :approved }
  #
  #     def call(order_id:, amount:, note: nil)
  #       ...
  #     end
  #   end
  #
  # Tool identity is the FILENAME (app/agent/tools/issue_refund.rb -> "issue_refund"),
  # eve's convention, enforced by the Registry.
  class Tool
    class << self
      def description(text = nil)
        @description = text if text
        @description || ""
      end

      def param(name, type = :string, desc: nil)
        param_refinements[name.to_sym] = { type: type.to_s, desc: desc }
      end

      def approval(policy = nil, &block)
        @approval_policy = block || policy unless policy.nil? && block.nil?
        @approval_policy || :never
      end
      alias approval_policy approval

      def transactional! = @effect_mode = :transactional
      def idempotent!    = @effect_mode = :idempotent
      def at_most_once!  = @effect_mode = :at_most_once

      def effect_mode = @effect_mode || :at_most_once

      def tool_name
        name.demodulize.underscore
      end

      # {name:, description:, input_schema:} — provider-agnostic JSON schema.
      def schema
        validate_signature!
        properties = {}
        required = []
        instance_method(:call).parameters.each do |kind, pname|
          refinement = param_refinements[pname] || {}
          properties[pname.to_s] = { "type" => refinement[:type] || "string" }
          properties[pname.to_s]["description"] = refinement[:desc] if refinement[:desc]
          required << pname.to_s if kind == :keyreq
        end
        {
          "name" => tool_name,
          "description" => description,
          "input_schema" => {
            "type" => "object",
            "properties" => properties,
            "required" => required
          }
        }
      end

      def validate_signature!
        raise Error, "#{name} must define #call" unless method_defined?(:call)

        kinds = instance_method(:call).parameters.map(&:first)
        if kinds.any? { |k| %i[req opt rest].include?(k) }
          raise Error, "#{name}#call must accept keyword arguments only — the signature is the schema"
        end
      end

      private

      def param_refinements
        @param_refinements ||= {}
      end
    end

    # Instance-side delegation so a resolved instance answers the Ledger.
    def approval_policy = self.class.approval_policy
    def effect_mode     = self.class.effect_mode

    # Execution context, set by the Ledger before #call.
    attr_accessor :session

    def call(**)
      raise NotImplementedError, "#{self.class}#call"
    end
  end
end
