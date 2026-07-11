# E8450 documentation

Use this order when working on the Linksys E8450 / MT7622 target:

1. [Hardware and software reference](E8450-hardware-software-reference.md) —
   current hardware facts, validated paths, operating rules, closed work, and
   next investigations.
2. [Building](BUILDING.md) and [flashing](FLASHING.md) — current host
   workflows.
3. [Bridged-offload validation](e8450-bridged-offload-validation.md) and
   [WED breadcrumb harness](WED-breadcrumb-harness-design.md) — active test
   procedures.
4. [Optimization roadmap](OPTIMIZATION-ROADMAP.md) — ranked investigations,
   safety gates, and measurement criteria.
5. [Cache-line audit](cacheline-audit.md) and [UMASH port task](umash-port-task.md)
   — closed investigations retained for evidence and regression context.
6. [Phase 3 patch verdicts](PHASE3-patch-verdicts.md), [project summary](E8450-MT7622-project-summary.md),
   and [Codex handoff](HANDOFF-codex.md) — historical records. They may contain
   superseded conclusions; do not use them as current status without checking
   the hardware/software reference first.

Dates in this directory are evidence timestamps, not guarantees that the
router is still in the same live state. Hardware-changing tests must follow
the operating rules in the current reference and `CLAUDE.md`.
