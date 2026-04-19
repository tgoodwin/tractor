defmodule Tractor.ACP.Turn do
  @moduledoc """
  Structured result of one ACP prompt turn.
  """

  defstruct response_text: "",
            agent_message_chunks: [],
            agent_thought_chunks: [],
            tool_calls: [],
            tool_call_updates: [],
            events: []

  @type t :: %__MODULE__{
          response_text: String.t(),
          agent_message_chunks: [map()],
          agent_thought_chunks: [map()],
          tool_calls: [map()],
          tool_call_updates: [map()],
          events: [map()]
        }
end
