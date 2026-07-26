# Cancellation

Cancel means *a person stopped it* — in the UI it renders as a lamp going out
(quiet, dashed), not a failure. Under the hood there are exactly two cases,
decided by whether anything is live:

## Parked or queued: settles immediately

A turn with no live execution — held on an approval, a question, a budget
breach, or still queued — cancels synchronously:

- status → `canceled`, finished stamp set;
- every pending approval on the turn is **expired** with the cancel reason
  recorded as its denial — so a later `approve!` can't zombie-resume a turn
  someone already killed.

## Running: honored at the next step boundary

A turn a worker is actively executing gets **flagged**
(`cancel_requested_at`), and the loop honors the flag at the next step
boundary. The in-flight model call completes and its step commits first —
aborting mid-step would forfeit paid tokens and create an in-doubt tool window
for nothing. That's why the inbox button says *"honored at the next step
boundary."*

If the process crashes between the flag and the boundary, the resume sees the
flag and cancels then. A cancel landing later than intended is still a correct
cancel — this is the same benign wall-clock non-determinism as the budget
timeout.

## Surfaces

```ruby
turn.cancel!                    # => :canceled or :cancel_requested
```

- **Inbox**: the cancel button on an active turn.
- **API**: `POST /silas/api/v1/turns/:id/cancel`.

Canceling raises if the turn is already terminal. The session stays usable —
`session.continue(input: "…")` starts a fresh turn after a canceled one.
