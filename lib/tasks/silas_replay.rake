namespace :silas do
  desc "Counterfactual replay: TURN=<id> [MODEL=<registry id>] [INSTRUCTIONS=<file>] [FROM=<step>]"
  task replay: :environment do
    turn = Silas::Turn.find(ENV.fetch("TURN") { abort "usage: silas:replay TURN=<id> [MODEL=…] [INSTRUCTIONS=<file>] [FROM=…]" })
    instructions = ENV["INSTRUCTIONS"] && File.read(ENV["INSTRUCTIONS"])

    result = Silas::Replay.call(turn,
                                model: ENV["MODEL"],
                                instructions: instructions,
                                from_step: ENV.fetch("FROM", 0).to_i)

    recorded_on = turn.steps.where(status: "completed").distinct.pluck(:model).compact.join(", ")
    puts "replaying turn #{turn.id} — #{turn.session.agent_name} · #{turn.input.truncate(70).inspect}"
    puts "candidate: #{result.candidate_label}#{" · recorded on #{recorded_on}" if recorded_on.present?} · read-only: nothing executes, nothing writes"
    puts

    result.probes.each do |probe|
      if probe.diverged?
        puts "step #{probe.index}  ✗ DIVERGED"
        puts "        recorded  #{probe.recorded_calls.map { |c| "#{c['name']} #{c['arguments'].to_json}" }.join('; ').presence || '(text only)'}"
        puts "        candidate #{probe.candidate_calls.map { |c| "#{c['name']} #{c['arguments'].to_json}" }.join('; ').presence || '(text only)'}"
      else
        calls = probe.recorded_calls.map { |c| "#{c['name']} #{c['arguments'].to_json}" }.join("; ")
        puts "step #{probe.index}  ✓ same call#{"s" if probe.recorded_calls.size > 1}  #{calls.presence || '(text only)'}" \
             "#{'  · wording differs' if probe.recorded_text != probe.candidate_text}"
      end
      next unless probe.gate_changed?

      puts "        ⚠ approval outcome would change: recorded #{probe.recorded_gates.values.tally} → candidate #{probe.candidate_gates.values.tally}"
    end

    puts
    if (first = result.first_divergence)
      puts "first divergence: step #{first.index} of #{result.probes.size}."
    else
      puts "zero divergence — the candidate makes every recorded call identically."
    end
  end
end
