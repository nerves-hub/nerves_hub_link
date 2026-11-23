# Devices That Sleep

A device on a battery often can't keep a connection open. It wakes, connects,
does its work and sleeps again. If it doesn't say so first, NervesHub only sees
the connection close and shows the device as offline, the same as one that
lost power. Every wake also counts as a disconnect in its health and in
Insights.

A device that tells NervesHub it is going to sleep is shown as asleep instead,
with when it is due back, and its sleep doesn't count as a disconnect. If it is
late back by more than two minutes or a tenth of the sleep, whichever is
longer, NervesHub shows it as overdue.

## Telling NervesHub

Call `NervesHubLink.going_to_sleep/2` just before the device sleeps:

```elixir
:ok = NervesHubLink.going_to_sleep(mode: :deep, duration_ms: :timer.minutes(5))
# now put the device to sleep
```

It pushes a `sleeping` message on the device channel, closes the connection,
and returns once both are done, or after five seconds if the close is slow, so
the device can sleep straight after.
NervesHub doesn't reply.

Give `:duration_ms` when the device knows how long it will sleep, such as a
timer or an RTC alarm. Leave it out when something else wakes it, such as a
GPIO or a sensor's interrupt: NervesHub shows it as asleep with no time given.
Always send how long, never when: a device that has just woken may not have
its clock set, so NervesHub counts from when the message arrives.

If the device channel isn't joined, `going_to_sleep/2` returns
`{:error, :disconnected}`, sends nothing, and leaves the connection as it was.
The device can still sleep, and NervesHub will show it as offline.

A firmware update in progress isn't stopped by closing the connection. Check
`NervesHubLink.status/0` first if the device shouldn't sleep in the middle of
one.

## Deep or light

NervesHub shows the mode to people and does nothing else with it, so pick the
one that describes what the device does:

- `:deep` (the default) - the device loses what it was running and starts
  again when it wakes, as when it is powered off until an RTC alarm turns it
  back on. It connects on boot as it always does.
- `:light` - the device carries on where it left off, as after a suspend to
  RAM, or when an application only turns its modem off for a while. The
  connection stays closed until the device reconnects.

## Waking up

After `going_to_sleep/2` the connection stays closed. A device that keeps
running through its sleep reconnects with `NervesHubLink.reconnect/1`. Call it
when the device wakes:

```elixir
:ok = NervesHubLink.going_to_sleep(mode: :light, duration_ms: :timer.minutes(5))
suspend_until_woken()
NervesHubLink.reconnect()
```

A device that gave a `:duration_ms` also reconnects on its own once that much
time has passed, in case nothing calls `reconnect/1`. Don't rely on that after
a suspend to RAM: the BEAM's timers may not count the time spent suspended, so
it fires late. A device that gave no duration stays disconnected until
`reconnect/1` is called.

## Older servers

A NervesHub that predates this message logs it as unknown and carries on. The
connection still closes, and the device shows as offline as it did before, so
there is no need to check which version of NervesHub a device is talking to.
