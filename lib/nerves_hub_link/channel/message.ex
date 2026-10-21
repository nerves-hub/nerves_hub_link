# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Channel.Message do
  @moduledoc """
  One message on a Phoenix channel, in either direction.

  The five fields are the Phoenix socket envelope, in the order the wire
  format carries them: `[join_ref, ref, topic, event, payload]`.

  `ref` identifies a message the device sent so the server's reply can be
  matched to it. A message the server sends on its own carries no `ref`.
  `join_ref` names the join a message belongs to, which lets the server tell
  messages for the current join from ones left over from a previous one.
  """

  @type t :: %__MODULE__{
          topic: String.t(),
          event: String.t(),
          payload: term(),
          ref: String.t() | nil,
          join_ref: String.t() | nil
        }

  defstruct [:topic, :event, :payload, :ref, :join_ref]
end
