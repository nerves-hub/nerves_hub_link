# Socket benchmark: main vs refactor/remove-slipstream

Both sides run `bench/socket_bench.exs`, unchanged between them, five times each.
The script stands up a websocket server that answers a join and a heartbeat and
counts what it is sent, points the library's socket at it over loopback, and
measures what the socket costs.

- main at `3367ac9` (slipstream 1.3.0), PR at `9dceaea`
- Elixir 1.20.5 / OTP 29, macOS, loopback, no TLS
- 2,000 pushes device to server, 2,000 messages server to device
- Figures are medians of five runs; ranges given where they moved

Reductions are the headline rather than wall time. They count work actually
done, they do not move with what else the machine is doing, and on a device CPU
time is battery.

## Results

| | main | this PR | change |
|---|---|---|---|
| Processes holding the connection | 2 | 1 | −1 |
| Processes in all (incl. shared DNS helpers) | 6 | 3 | −3 |
| Process memory, settled | 23,624 B | 14,680 B | **−38%** |
| Process memory, the named connection processes | 12,040 B | 8,952 B | −26% |
| Time to connected and joined | 54.2 ms | 42.2 ms | **−22%** |
| Reductions per push, device to server | 589 | 354 | **−40%** |
| Wall for 2,000 pushes | 42.4 ms | 21.6 ms | −49% |
| Reductions per message, server to device | 503 | 383 | **−24%** |
| Wall for 2,000 messages | 21.1 ms | 21.0 ms | — |
| Modules in a device build | +53 | — | **−53** |
| BEAM files in a device build, stripped | +220 KB | — | **−220 KB** |

### The processes

main runs six, this PR runs three:

```
main                                               this PR
NervesHubLink.Socket            5,960 B            NervesHubLink.Socket     8,952 B
Slipstream.Connection           6,080 B
:timer                          3,016 B
(unnamed)                       2,840 B
inet_gethost_native             2,808 B            inet_gethost_native      2,808 B
(its port owner)                2,920 B            (its port owner)         2,920 B
```

The two `inet_gethost_native` processes are the BEAM's hostname resolver, shared
with everything else on the device, and they are identical on both sides. Of
what is left, only two are named: `NervesHubLink.Socket` and
`Slipstream.Connection`, 12,040 B against this PR's 8,952 B. This PR's single
process is larger on its own, which it should be - it holds the connection that
main keeps in a second process.

`:timer` is there for the heartbeat. Slipstream asks stdlib's timer server for a
repeating interval as the channel connects:

```elixir
{:ok, tref} =
  :timer.send_interval(
    state.config.heartbeat_interval_msec,
    command(%Commands.SendHeartbeat{})
  )
```

so on main that process is running because the socket connected. It is a single
shared server, though, so a device whose firmware reaches for `:timer` anywhere
else would be running it regardless - which is why it is listed above rather
than charged to the socket. This branch schedules its own heartbeat with
`Process.send_after/3` and schedules the next only once the current one has been
sent, and BEAM timers live in the scheduler rather than in a process.

I have not identified the sixth, unnamed process and have not attributed it. The
settled total of 23,624 B against 14,680 B is measured the same way on both
sides and needs none of this apportioning.

### The device build

`slipstream` is a runtime dependency on main and pulls `telemetry` with it. On
this branch `telemetry` survives only under `bandit`, which is `only: :test`, so
neither reaches a device:

```
main            slipstream 46 modules   436 KB unstripped
                telemetry   7 modules    64 KB unstripped
                            53 modules   492 KB unstripped, 220 KB stripped
```

A Nerves release strips debug info, so 220 KB is the figure that matters, before
squashfs compresses it.

## What the numbers do not say

- **The inbound wall time is identical** because it is bounded by the server
  writing 2,000 frames down loopback, not by the device reading them. Only the
  reductions column says anything there.
- **Memory before collection is higher on this PR**: ~702 KB against ~491 KB
  after 4,000 messages, read before any GC. That is transient garbage in one
  bigger heap rather than two smaller ones, and it collects back to less than
  main holds. Both figures swing widely with when the GC last ran (main
  477–741 KB, this PR 438–704 KB), so treat the direction, not the size.
- **One host, loopback, no TLS.** A device on a cellular link with TLS has
  entirely different absolute numbers. The per-message CPU ratio should hold,
  since nothing in it depends on the transport.
- `send_update_status/2` is a cast, so the outbound figure covers encoding and
  the socket write, and stops at the server having the frame.
- The outbound wall time on main landed on either ~42 ms or ~63 ms across runs,
  which smells like scheduling between its two processes. The reduction count
  was steady at 589 either way.

## An aside the benchmark turned up

The script has to stand a stub under the name `NervesHubLink.UpdateManager`.
Without one, on main the socket dies on connect:

```
** (stop) exited in: GenServer.call(NervesHubLink.UpdateManager, :currently_downloading_uuid, 5000)
   ** (EXIT) no process
   lib/nerves_hub_link/socket.ex:232: NervesHubLink.Socket.handle_connect/1
```

That is the sibling-restart fix in this PR, met by accident: on this branch the
same call is wrapped and logs a warning instead.
