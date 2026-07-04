---
title: <Concept name>
slug: <kebab-case-id>
stage: lit            # lit | logic | backtest | live-eval | prod
confidence: 0         # 0-100 (soundness given theory + independent literature)
evidence: 0           # 0-100 (strength of OUR OWN measured proof; see pipeline.md)
domains: []           # e.g. [momentum, factor-investing, quantitative-trading]
frameworks: []        # TradeWizz Framework scores it feeds, e.g. [momentum_score]
timeframe: <intraday | swing | position | long-term>
regime: <bull | bear | range | high-vol | all | unknown>
assets: []            # e.g. [us-equities, etf]
updated: <YYYY-MM-DD>
---

## Definition
<One precise sentence. What is it.>

## Purpose
<Why it exists in an investment process.>

## Theory / Why it works
<Mechanism. The causal or statistical reason. Cite real sources.>

## When it works
<Regimes, timeframes, asset classes, conditions.>

## When it fails
<Explicit failure modes. Be specific. This section must never be empty.>

## Strengths
- 

## Weaknesses
- 

## Risk
<What can go wrong for a user relying on it. Drawdown character.>

## Examples
<Concrete, checkable instances.>

## Counterexamples
<Cases where the concept misled. Never omit.>

## Implementation (rule spec)
<Explicit entry / exit / risk / sizing rules — falsifiable and testable.>

## Backtesting ideas
<How to test it with the data we actually have; note data limits.>

## Relationships to other concepts
<Links to sibling atoms: complements, contradicts, subsumes.>

## References
<Real, locatable citations only. Mark anything unverified.>

## Evidence log
<Every measured result, with data window + regime. PENDING until run.>
