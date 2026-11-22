# Cafe Networks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development.

**Goal:** Cafes share one loyalty balance.

## Global Constraints

- Work on the `cafe-networks` branch.

### Task 1: Schema and migration

**Files:**
- Create: `priv/repo/migrations/20261118_networks.exs`

- [x] **Step 1: Write the failing schema tests**

```elixir
# - [ ] this checkbox is inside a fence and must be ignored
test "network" do
end
```

- [x] **Step 2: Run to verify failure**
- [x] **Step 3: Commit**

```bash
git commit -m "Add cafe network schemas: kind, memberships"
```

### Task 2: `Loyalty.Networks` context

- [x] **Step 1: Write the failing tests** (narrative names)
- [ ] **Step 2: Implement**
- [ ] **Step 3: Commit** `feat(networks): found, invite, approve`

### Task 3: Deal resolution at member venues

- [ ] **Step 1: Write the failing tests**
- [ ] **Step 2: Commit** — `"Network card rules: one stamp per cafe per day"`

### Task 4: Full gate

- [ ] **Step 1: Run `mix precommit`.** Expected: 0 failures.
