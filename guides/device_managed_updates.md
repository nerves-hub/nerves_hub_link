# Device-Managed Updates

By default a device takes firmware whenever its deployment group sends it. Some
devices should not: a machine mid-cycle, a vehicle in motion, a device whose
owner has been given a say over when it restarts.

A device-managed device chooses *when* it takes firmware. It does not choose
*what* — its deployment group still decides that. And it can never stop itself
being reachable: only an operator can turn a device's updates off entirely.

## The three modes

`NervesHubLink.update_mode/1` reports how NervesHub is treating this device.

| Mode | What it means |
| --- | --- |
| `:automatic` | The deployment group sends firmware on its own schedule. The default. |
| `:device_managed` | The device asks for firmware itself, whenever suits it. |
| `:off` | The device takes no firmware except a manual push from an operator. |

The mode lives on NervesHub, not here. That is deliberate: it survives a reboot
without this library persisting anything, an operator can see and change it, and
`update_mode/1` always reports what NervesHub actually has rather than what this
device last wanted.

It returns `nil` until NervesHub says. A server too old to know about update
modes never will, and the device goes on taking updates exactly as before — so
treat `nil` as "not device managed", never as an error.

## Asking for an update

Two calls, and they are deliberately separate.

```elixir
case NervesHubLink.check_for_update() do
  {:ok, %{available?: true, firmware_meta: meta}} ->
    Logger.info("firmware #{meta["version"]} is waiting")

  {:ok, %{available?: false}} ->
    :nothing_to_do

  {:error, reason} ->
    Logger.warning("could not check for firmware: #{inspect(reason)}")
end
```

`check_for_update/1` is allowed in every mode, `:off` included. It is read-only,
so a frozen device can still tell its user an update exists and an administrator
needs to act. It reports metadata and **no URL**.

```elixir
NervesHubLink.start_update()
```

`start_update/1` is the one that fetches the firmware, and returns `:ok` once
NervesHub has sent it. From there the update proceeds exactly as one the
deployment group pushed, reporting through your `NervesHubLink.Client`.

The split matters. Firmware URLs are signed and time limited, so a device that
checked at 02:00 and updated at 04:00 would find a dead link. The URL is fetched
at the moment it is going to be used.

### Being told to wait

Deployment groups pace their rollouts, and a device asking for firmware takes a
slot in that pacing like any other update. A fleet that all wakes at 03:00 local
would otherwise walk straight past it.

```elixir
case NervesHubLink.start_update() do
  :ok -> :updating
  {:error, {:busy, minutes}} -> reschedule_in(minutes)
  {:error, reason} -> Logger.warning("update refused: #{inspect(reason)}")
end
```

Treat `{:busy, minutes}` as "not now" rather than "not ever", and do not retry
sooner than it says.

`{:error, :updating}` means this device is already applying firmware; there is
nothing to do but wait.

## Choosing the mode from the device

A device may move itself between `:automatic` and `:device_managed`, and only
once an operator has allowed it:

```elixir
if NervesHubLink.managed_updates_allowed?() do
  NervesHubLink.set_update_mode(:device_managed)
end
```

`managed_updates_allowed?/1` is off until an operator turns it on for this
device in NervesHub. Ask before offering the choice, rather than offering a
switch NervesHub will refuse.

A device can never set `:off`. That would let a device stop its own updates and
leave nobody able to fix it remotely, so it stays an operator's decision.

`set_update_mode/2` returns `{:error, :not_permitted}` when the operator has not
allowed it, and `{:error, :disconnected}` when there is no connection to ask
over. The change is not queued — an application that needs to converge should
re-assert it when the connection comes back:

```elixir
defmodule MyApp.NervesHubLinkClient do
  use NervesHubLink.Client

  @impl NervesHubLink.Client
  def connected() do
    if MyApp.Settings.automatic_updates?() do
      NervesHubLink.set_update_mode(:automatic)
    else
      NervesHubLink.set_update_mode(:device_managed)
    end

    :ok
  end
end
```

Re-asserting is safe to repeat, so this is the simplest way to keep a
user-facing switch and NervesHub in step.

## Putting it together

A device that updates only in its own maintenance window:

```elixir
defmodule MyApp.UpdateWindow do
  use GenServer

  require Logger

  @check_interval :timer.minutes(30)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    {:ok, %{}, {:continue, :schedule}}
  end

  @impl GenServer
  def handle_continue(:schedule, state) do
    Process.send_after(self(), :maybe_update, @check_interval)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:maybe_update, state) do
    if MyApp.safe_to_restart?() do
      case NervesHubLink.check_for_update() do
        {:ok, %{available?: true}} -> apply_update()
        _ -> :ok
      end
    end

    {:noreply, state, {:continue, :schedule}}
  end

  defp apply_update() do
    case NervesHubLink.start_update() do
      :ok ->
        Logger.info("firmware update started")

      {:error, {:busy, minutes}} ->
        # The deployment group is at its concurrent update limit.
        Process.send_after(self(), :maybe_update, :timer.minutes(minutes))

      {:error, reason} ->
        Logger.warning("firmware update refused: #{inspect(reason)}")
    end
  end
end
```

Note what this does *not* do: it never decides which firmware to install, and it
never turns updates off. Both remain with the deployment group and the operator,
which is what keeps a fleet of these devices recoverable.

## Requirements

Device-managed updates need a NervesHub that supports them, and are negotiated
by `device_api_version`, which this library reports as `2.4.0`. Against an older
server the calls in this guide return errors and `update_mode/1` stays `nil`;
nothing else changes, and the device keeps taking updates as it always did.
