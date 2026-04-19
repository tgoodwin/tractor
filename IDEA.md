I want to develop an implementation of StrongDM's attractor spec here: https://github.com/strongdm/attractor

I'd like to use Elixir to do so. I am new to elixir.
I will call it Tractor (a play on attractor).

Tractor will support claude, codex, and gemini models. its powered by pipeline definitions, which are DOT graphs. there will also be a web UI to illustrate progress. it should also be fault tolerant. if the pipeline crashes (or a given agent node crashes) it should be able to pick up where it left off.

id like to use yaks: https://github.com/mattwynne/yaks for internal state tracking / todo stuff. yaks can also serve as a mechanism for a pipeline to track things it uncovered during its work that need more investigation but are out of scope for the current pipeline run. it can serve as a collection surface for "findings" that can inform a future pipeline.

id like to use the agentclientprotocol to faciliate communicating with agents from Tractor's elixir orchestration layer. https://github.com/agentclientprotocol/agent-client-protocol


It will have a CLI inspired by that of Kilroy, another strongDM attractor implementation (https://github.com/danshapiro/kilroy):
- `tractor sow` will convert english requirements to a graphviz DOT pipeline
- `tractor validate` will validate graph structure and semantics
- `tractor reap` to execute a DOT pipeline
- `tractor reap --resume` picks up from checkpointed state, defaults to the most recent but supports starting from an arbitrary point in the checkpoint state. this implies some kind of persisted event log.

`tractor sow` should extract requirements from the user. maybe implemented as a skill. part of the requirements should be getting concrete "definitions of done" from the user's goals, as well as defining concrete (i.e. deterministic) feedback mechanisms to verify that those definitions of done have been met. `tractor sow` should thus work with the user to design these feedback loop harnesses and incorporate them into the pipeline design, thus enabling the pipeline to iteratively converge on the correct solution.

`tractor validate` should validate graph structure and semantics

`tractor reap` should also run a pre-flight checklist upfront. maybe this calls `tractor validate` internally. it should also verify that the models are authenticated. we dont want to find out that, e.g. a downstream Gemini node cant execute after 1h of pipeline execution.
