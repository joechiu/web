# Tool4 Validation Flow

## Outcomes

- B = BLOCK
- R = REVIEW_REQUIRED
- W = WARNING
- P = PASS
- C = CLEAR
- E = ESCALATE
- S = SKIPPED

## Preview / PV behavior

### Initial run

`preview_status = ""`

Flow starts at:

`INPUTS -> 2.0 FAST RULE VALIDATOR`

### Preview CLEAR

`preview_status = C`

Fast Rule is skipped:

`INPUTS -> 2.1 CONFIGURABLE RULES -> 3 -> 4`

### Preview ESCALATE

`preview_status = E`

Fast Rule runs and produces E:

`INPUTS -> 2.0 -> E -> 2.1 S -> 3 S -> 4 E`

### Fast R

Fast Rule produces:

`R`

The flow returns:

`REVIEW_REQUIRED`

with:

`Awaiting for Pre-Validation Human Review`

The external PV application reviews the case.

If PV returns C, rerun the flow with:

`preview_status = C`

If PV returns E, rerun the flow with:

`preview_status = E`

## Hard stop

Fast B/E:

`2.0 -> B/E -> 2.1 S -> 3 S -> 4 -> FAIL REPORT`

## Important Node 3 rule

Configurable Rules do not control whether Node 3 independently validates
the draft.

Therefore:

- Fast P + Config B -> Node 3 still executes
- Fast P + Config R -> Node 3 still executes
- Fast P + Config W -> Node 3 still executes
- Fast P + Config E -> Node 3 still executes

The Decision Router combines the resulting findings and applies:

`B > E > R > W > P`
