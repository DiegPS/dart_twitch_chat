## 0.3.0

- Load channel-specific BetterTTV, FrankerFaceZ, and 7TV emotes after anonymous
  IRC exposes the room ID.
- Keep global and channel catalogs independent so asynchronous completion
  cannot discard either source.
- Treat every third-party provider as optional and non-blocking.

## 0.2.0

- Add a lossless IRC frame and typed event stream for every anonymous Twitch IRC command.
- Model rich messages, replies, Bits, badges, shared chat, GIFs, actions, and server timestamps.
- Model every documented `USERNOTICE` kind and preserve unknown kinds and parameters.
- Add typed moderation, room-state, notice, reconnect, capability, user-state, join, part, and numeric events.
- Buffer fragmented frames, echo exact `PING` payloads, wait for room confirmation, and reconnect immediately when requested by Twitch.
- Preserve valid unknown commands through `TwitchRawEvent` and report malformed frames as protocol failures.

## 0.1.0

- Extract the anonymous Twitch IRC implementation used by AirStream.
- Parse chat messages, membership notices, roles, badges, and native emotes.
- Load global BetterTTV, FrankerFaceZ, and 7TV emotes.
- Support injectable HTTP and WebSocket transports, timeouts, and reconnection.
