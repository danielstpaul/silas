module Silas
  module Eval
    module Assertions
      # Assertions read ONLY the transcript rows; the block runs in this context.
      # They collect failures rather than raising, so one eval reports all misses.
      class Context
        EXECUTED = %w[completed started in_doubt].freeze
        MONEY = /(?<cur>[£$€])\s?(?<amt>\d{1,3}(?:,\d{3})*(?:\.\d+)?|\d+(?:\.\d+)?)/

        attr_reader :failures, :skips

        def initialize(transcript)
          @t = transcript
          @failures = []
          @skips = []
        end

        def assert_tool_called(name, times: nil)
          n = execed(name).size
          check(times ? n == times : n.positive?,
                "expected #{name} called#{" #{times}x" if times}, saw #{n} (#{summary})")
        end

        def assert_no_tool_called(name = nil)
          bad = name ? execed(name) : @t.invocations.select { |i| EXECUTED.include?(i.status) }
          check(bad.empty?, "expected no#{" #{name}" if name} tool execution, saw #{bad.map(&:tool_name)}")
        end

        def assert_tool_arg(name, key, value = :__unset, &pred)
          inv = execed(name).last || @t.invocations_for(name).last
          return check(false, "#{name} was never called") unless inv

          got = inv.arguments[key.to_s]
          ok = pred ? pred.call(got) : got == value
          check(ok, "#{name}.#{key} expected #{pred ? 'predicate' : value.inspect}, got #{got.inspect}")
        end

        def assert_final_matches(matcher)
          check(matcher === @t.final_text, "final answer #{@t.final_text.inspect} does not match #{matcher.inspect}")
        end

        # Structured (final_answer) assertions. With a Hash, expects the whole
        # payload; with key/value, one field; with a block, a predicate over
        # the payload. String keys — the payload is stored jsonb.
        def assert_answer_data(expected = :__unset, key: nil, value: :__unset, &pred)
          data = @t.answer_data
          return check(false, "no structured answer (final_answer schema not set, or turn unfinished)") if data.nil?

          if pred
            check(pred.call(data), "answer_data predicate failed for #{data.inspect}")
          elsif key
            check(data[key.to_s] == value, "answer_data.#{key} expected #{value.inspect}, got #{data[key.to_s].inspect}")
          elsif expected != :__unset
            check(data == expected, "answer_data expected #{expected.inspect}, got #{data.inspect}")
          else
            check(true, nil) # presence alone
          end
        end

        # No-hallucinated-price guard: every money amount in the final answer must
        # trace to a number the agent actually saw (tool results or the user input),
        # allowing pence<->pounds scaling.
        def assert_no_hallucinated_price(allowed: [], scale: [ 1, 100, 0.01 ])
          stated = @t.final_text.scan(MONEY).map { |_c, a| a.delete(",").to_f }
          grounded = grounded_numbers + Array(allowed).map(&:to_f)
          bad = stated.reject { |n| grounded.any? { |g| scale.any? { |s| (g * s - n).abs < 0.005 } } }
          check(bad.empty?, "final answer states ungrounded amount(s) #{bad.inspect}; grounded=#{grounded.sort.inspect}")
        end

        def assert_approved(tool: nil)
          inv = tool ? @t.invocations_for(tool).last : @t.invocations.last
          check(inv&.approval_state == "approved", "expected #{tool || 'an invocation'} approved, state=#{inv&.approval_state.inspect}")
        end

        def assert_parked(tool: nil)
          parked = @t.parked?
          parked &&= @t.invocations_for(tool).any? { |i| i.approval_state == "required" || i.status == "in_doubt" } if tool
          check(parked, "expected turn parked#{" on #{tool}" if tool}, status=#{@t.status}")
        end

        def assert_turn_completed
          check(@t.completed?, "turn not completed (#{@t.status}/#{@t.turn.failure_reason})")
        end

        def assert_turn_failed(reason: nil)
          ok = @t.status == "failed" && (reason.nil? || @t.turn.failure_reason == reason)
          check(ok, "expected failed#{"/#{reason}" if reason}, got #{@t.status}/#{@t.turn.failure_reason}")
        end

        # LLM-graded — opt-in; SKIPS offline (never fails the gate unless SILAS_EVAL_STRICT=1).
        def assert_rubric(criteria)
          unless Grader.available?
            @skips << "assert_rubric skipped (no grader / offline)"
            return check(false, "assert_rubric strict skip (SILAS_EVAL_STRICT)") if ENV["SILAS_EVAL_STRICT"] == "1"

            return
          end
          verdict = Grader.grade(Grader.prompt(@t, criteria))
          check(verdict.start_with?("PASS"), "rubric FAIL: #{verdict}")
        end

        private

        def execed(name) = @t.invocations_for(name).select { |i| EXECUTED.include?(i.status) }
        def summary = @t.invocations.map { |i| "#{i.tool_name}:#{i.status}" }.join(",")
        def check(cond, msg) = (@failures << msg unless cond)

        def grounded_numbers
          nums = []
          walk = lambda do |v|
            case v
            when Numeric then nums << v.to_f
            when Hash    then v.each_value(&walk)
            when Array   then v.each(&walk)
            when String  then v.scan(/\d+(?:\.\d+)?/) { |d| nums << d.to_f }
            end
          end
          @t.results.each(&walk)
          walk.call(@t.input)
          nums
        end
      end
    end
  end
end
