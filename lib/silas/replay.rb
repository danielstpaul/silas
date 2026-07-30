module Silas
  # Counterfactual replay: the step-wise probe. For each recorded step of a
  # turn, rebuild the exact context the model saw (rows are the source of
  # truth — messages, instructions snapshot, definitions snapshot) and ask a
  # CANDIDATE — a different model, edited instructions, or the recorded
  # responses themselves — what it would have done at that point.
  #
  # Every step is re-conditioned on the RECORDED history, so each comparison
  # is like-with-like and divergence is a trustworthy, first-class output:
  # "agreed through step 1, split on the refund amount" — never a wall of
  # drift. (Trajectory-following replay, where the candidate's own outputs
  # feed forward, deliberately does not live here; see
  # research/a1-demo-transcript.md for why it comes after this form.)
  #
  # READ-ONLY BY CONSTRUCTION: nothing here resolves a tool for execution,
  # touches the Ledger, or writes a row. The only side effect is the
  # candidate adapter's own model call.
  module Replay
    StepProbe = Struct.new(:index, :verdict, :recorded_calls, :candidate_calls,
                           :recorded_text, :candidate_text, :recorded_gates,
                           :candidate_gates, keyword_init: true) do
      def diverged? = verdict == :diverged
      def gate_changed? = recorded_gates.values.sort != candidate_gates.values.sort
    end

    Result = Struct.new(:turn, :candidate_label, :probes, keyword_init: true) do
      def first_divergence = probes.find(&:diverged?)
      def diverged? = !first_divergence.nil?
    end

    module_function

    # candidate: any object responding to #execute_step(context). Defaults to
    # the null replay (the turn's own recorded responses) when no override is
    # given — the soundness check that must always come back byte-identical.
    def call(turn, candidate: nil, model: nil, instructions: nil, from_step: 0)
      candidate ||= model ? Silas.resolved_adapter : Echo.new(turn)
      label = model || (candidate.is_a?(Echo) ? "null replay" : candidate.class.name)

      probes = turn.steps.where(status: "completed", index: from_step..)
                   .order(:index).map do |step|
        probe_step(turn, step, candidate, model: model, instructions: instructions)
      end
      Result.new(turn: turn, candidate_label: label, probes: probes)
    end

    def probe_step(turn, step, candidate, model:, instructions:)
      result = candidate.execute_step(context_for(turn, step, model: model, instructions: instructions))

      # Recorded calls come from the LEDGER rows, not from response_blocks —
      # the invocation rows are canonical (blocks are adapter-shaped and not
      # every adapter mirrors tool calls into them). Candidate calls come from
      # the adapter Result's own tool_calls for the same reason.
      recorded_calls = step.tool_invocations.order(:id)
                           .map { |inv| { "name" => inv.tool_name, "arguments" => inv.arguments } }
      candidate_calls = Array(result.tool_calls)
                        .map { |tc| { "name" => tc.name, "arguments" => (tc.arguments || {}).stringify_keys } }
      StepProbe.new(
        index: step.index,
        verdict: recorded_calls == candidate_calls ? :match : :diverged,
        recorded_calls: recorded_calls, candidate_calls: candidate_calls,
        recorded_text: text_in(step.response_blocks), candidate_text: text_in(result.blocks),
        recorded_gates: gates_for(turn, recorded_calls),
        candidate_gates: gates_for(turn, candidate_calls)
      )
    end

    # Mirrors StepRunner's context assembly minus its side effects: no
    # compaction claim (the original run's rows already exist and
    # MessageBuilder reads them) and no delta broadcasting.
    def context_for(turn, step, model:, instructions:)
      snapshot = turn.definitions_snapshot
      {
        turn: turn,
        index: step.index,
        system: instructions || turn.instructions_snapshot,
        messages: MessageBuilder.call(turn, upto_index: step.index),
        tools: snapshot ? snapshot["tools"] : Silas.tool_definitions,
        model: model || step.model || Silas.agent.model,
        final_answer: snapshot ? snapshot["final_answer"] : Silas.agent.final_answer,
        limits: { max_steps: Silas.agent.max_steps }
      }
    end

    # What the approval machinery WOULD say about each call — evaluated
    # read-only, never creating an invocation. This is where a replay earns
    # its keep: a cheaper model that words things differently is trivia; one
    # whose refund slides under the £25 gate is a governance finding.
    def gates_for(turn, calls)
      calls.to_h do |call|
        [ "#{call['name']}(#{call['arguments'].to_json})", gate_verdict(turn, call) ]
      end
    end

    def gate_verdict(turn, call)
      tool = Silas.tool_resolver.call(call["name"])
      policy = tool.respond_to?(:approval_policy) ? tool.approval_policy : :never
      case policy
      when :never then :ungated
      when :always then :would_park
      when :once then :would_park # read-only probe: assume no prior approval
      when Proc
        policy.call(session: turn.session,
                    input: call["arguments"].with_indifferent_access) == :user_approval ? :would_park : :auto_approved
      else :ungated
      end
    rescue StandardError
      # A candidate can hallucinate a tool the app doesn't have — that is
      # itself a divergence worth naming, not an exception worth raising.
      :unknown_tool
    end

    def text_in(blocks)
      Array(blocks).select { |b| b["type"] == "text" }.map { |b| b["text"] }.join
    end

    # The null candidate: answers every probe with the step's own recorded
    # response. Replaying a turn against Echo must come back byte-identical —
    # if it doesn't, the probe mechanism itself is unsound and nothing built
    # on it can be trusted.
    class Echo
      def initialize(turn)
        @blocks_by_index = turn.steps.where(status: "completed")
                               .pluck(:index, :response_blocks, :stop_reason)
                               .to_h { |i, blocks, stop| [ i, [ blocks, stop ] ] }
      end

      def execute_step(context)
        blocks, stop_reason = @blocks_by_index.fetch(context[:index])
        # Tool calls from the ledger rows — the same canonical source the
        # probe reads for the recorded side, so the null replay compares a
        # thing to itself and any daylight is a probe bug.
        tool_calls = Silas::ToolInvocation.where(turn_id: context[:turn].id)
                                          .joins(:step).where(silas_steps: { index: context[:index] })
                                          .order(:id).map do |inv|
          Adapters::ToolCall.new(id: inv.tool_call_id, name: inv.tool_name, arguments: inv.arguments)
        end
        Adapters::Result.new(blocks: blocks, tool_calls: tool_calls,
                             stop_reason: stop_reason, usage: nil)
      end
    end
  end
end
