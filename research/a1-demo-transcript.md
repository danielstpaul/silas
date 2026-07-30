# A1 day-0 transcript (written before any implementation — this is the spec)

*Per `a1-counterfactual-replay.md`: exact commands, exact output, faked. If
this page doesn't make its own author want to run it, A1 stops here.*

---

The playground's turn 31: a customer emailed about a cracked lamp, the agent
looked up her account, read her orders, and refunded £48 — which parked for
approval because it was over the £20 gate. Dana approved it. What would the
cheap model have done?

```
$ bin/rails silas:replay TURN=31 MODEL=claude-haiku-4-5

replaying turn 31 — agent · "Hi, I'm ada@example.com — the brass desk lamp
arrived cracked." · 3 recorded steps · recorded on claude-sonnet-4-5
candidate: claude-haiku-4-5 · read-only: nothing executes, nothing writes

step 0  find_customer(query: "ada@example.com")           ✓ same call
step 1  recent_orders(customer_id: 1)                     ✓ same call
step 2  issue_refund(order_id: 1, amount_pence: 4800)     ✗ DIVERGED

        recorded  issue_refund  order_id: 1, amount_pence: 4800,
                                reason: "arrived cracked"
        candidate issue_refund  order_id: 1, amount_pence: 2400,
                                reason: "cracked lamp — 50% refund"

first divergence: step 2 of 3. The runs agreed through both lookups and
split on the refund amount.

approval outcome would change: £24.00 is under the £25 gate — the
candidate's refund would NOT have parked for a person. The recorded £48.00
did, and Dana approved it.

tokens: recorded 180 in / 87 out · candidate 174 in / 61 out
```

Each step's candidate call is conditioned on the *recorded* history — the
question answered at every step is "given exactly what the agent had seen,
what would this model have done here?" — so every comparison is like-with-
like, and the divergence report is trustworthy rather than a wall of drift.

The null form is the soundness check:

```
$ bin/rails silas:replay TURN=31

replaying turn 31 against its own recorded responses (null replay)
step 0 ✓  step 1 ✓  step 2 ✓ — byte-identical, zero divergence
```

---

**Day-0 verdict:** the line that earns the feature is the approval one — a
cheaper model doesn't just word things differently, it changes *what gets
governed*: this refund would have sailed under the gate. That is a finding
you cannot get from reading the transcript, and it took one command. Build
toward this page.

**Deliberate v1 scope, stated before building:** this is the step-wise
probe — each step re-conditioned on recorded history, no execution, no
writes. Trajectory-following replay (the candidate's own outputs feeding
forward, tools executed inside a rolled-back transaction) is the next
layer, not this one; the divergence-safety property above is exactly what
it would give up, and it should be built only after this form has passed
the usefulness test.
