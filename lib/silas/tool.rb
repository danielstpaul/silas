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
        inherited_setting(:@description) || ""
      end

      def param(name, type = :string, desc: nil)
        own_param_refinements[name.to_sym] = { type: type.to_s, desc: desc }
      end

      def approval(policy = nil, &block)
        @approval_policy = block || policy unless policy.nil? && block.nil?
        inherited_setting(:@approval_policy) || :never
      end
      alias approval_policy approval

      def transactional! = @effect_mode = :transactional
      def idempotent!    = @effect_mode = :idempotent
      def at_most_once!  = @effect_mode = :at_most_once

      def effect_mode = inherited_setting(:@effect_mode) || :at_most_once

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

      # Ruby does NOT inherit class-level instance variables. Without this walk,
      # factoring shared declarations into a base class —
      #
      #   class MoneyTool < Silas::Tool
      #     transactional!
      #     approval :always
      #   end
      #   class IssueRefund < MoneyTool; end
      #
      # — silently drops both in the subclass, and drops them into the LEAST
      # safe defaults: no database transaction (:at_most_once) and no human
      # gate (:never). Silently disarming the two declarations the ledger acts
      # on is the worst failure this DSL could have, so settings resolve up the
      # ancestry: nearest explicit declaration wins.
      def inherited_setting(ivar)
        klass = self
        while klass.respond_to?(:inherited_setting, true)
          value = klass.instance_variable_get(ivar)
          return value unless value.nil?

          klass = klass.superclass
        end
        nil
      end

      def own_param_refinements
        @param_refinements ||= {}
      end

      # Merged down the ancestry so a base class's `param` refinements survive;
      # a subclass redeclaring the same param wins.
      def param_refinements
        return own_param_refinements unless superclass.respond_to?(:param_refinements, true)

        superclass.send(:param_refinements).merge(own_param_refinements)
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
