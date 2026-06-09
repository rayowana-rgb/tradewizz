"""Portfolio Journal — a research diary over the simulated portfolio.

Records a snapshot (score / signal / radar rank / portfolio health) at the time
of a simulated BUY, and the realized return at the time of a simulated SELL. It
NEVER touches the simulation accounting; it is an additive, read-mostly log fed
by a best-effort hook on the simulation order endpoint. No broker contact.
"""
