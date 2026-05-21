extends Interactable
##
## CHART TABLE — the physical anchor for the navigation chart UI
## (Tier 2, T2.3 Slice A).
##
## Mirrors the trade-panel / cargo-panel pattern: the player_controller
## intercepts E-press on a node in the `chart_table` group and opens the
## local `ChartPanel` directly (the UI is full-screen and replicates its
## own mutations through ChartState RPCs). interact() itself is a no-op
## host-side — kept for the prompt contract.
##
## Future hooks:
##   • restrict access via NetworkManager.current_navigator (one chart user
##     at a time) — Slice B / C decision.
##   • drive an interactable hot-zone collider so the navigator's body
##     locks onto the table while it's open (deck-gun pattern).
##

func _ready() -> void:
	prompt_text = "Press E to consult chart"
	add_to_group("chart_table")


## Server-side path is empty by design — the chart UI is opened locally by
## player_controller after the interact key is pressed (the panel itself
## calls into host-validated RPCs on ChartState for any actual mutations).
func interact(_peer_id: int) -> void:
	pass
