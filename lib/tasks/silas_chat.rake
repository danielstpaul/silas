namespace :silas do
  desc "Chat with your agent in the terminal (REPL). SESSION=id resumes one; approvals prompt inline."
  task chat: :environment do
    # A REPL wants each turn settled synchronously in this one process before
    # the next prompt — and Rails' dev-default Async adapter is unsafe for Silas
    # (it double-executes continuation retries; Silas warns at boot). Force the
    # synchronous :inline adapter for this process only; production still runs
    # Solid Queue.
    ActiveJob::Base.queue_adapter = :inline
    Silas.config.isolate_steps = false
    Silas::Registry.install!

    session = ENV["SESSION"].present? ? Silas::Session.find(ENV["SESSION"]) : nil
    Silas::Chat.new(session: session).run
  end
end
