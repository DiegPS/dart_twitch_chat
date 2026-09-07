# dart_twitch_chat

Anonymous, testable Twitch chat for Dart. The package connects directly to
Twitch IRC without an OAuth token, exposes a convenient message stream, and
also preserves the complete IRC event stream for advanced consumers.

## What it provides

- Anonymous `justinfan` connections over Twitch IRC WebSocket.
- `PRIVMSG` content with message and author IDs, server timestamps, colors,
  badges, roles, Bits, first-message and returning-chatter flags, plus the
  anonymous Channel Points `custom-reward-id` tag when Twitch sends it.
- Native Twitch emotes, Twitch GIFs, replies, `/me` actions, shared-chat source
  data, and global plus channel BetterTTV, FrankerFaceZ, and 7TV emotes.
- Every documented `USERNOTICE` kind and its raw `msg-param-*` values.
- Typed deletion, timeout, ban, room-clear, room-state, notice, reconnect,
  capability, user-state, join, part, and numeric events.
- A lossless generic frame and `TwitchRawEvent` fallback for valid commands the
  library does not recognize yet.
- Exact `PING`/`PONG`, fragmented-frame buffering, connection confirmation,
  automatic reconnection, timeouts, and injectable transports.
- JOIN confirmation timeout plus capped exponential reconnect backoff with
  jitter; a socket is not reported connected until JOIN or ROOMSTATE arrives.

The client deliberately requests only `twitch.tv/tags` and
`twitch.tv/commands`. It does **not** request `twitch.tv/membership`: chat data,
moderation, room state, rich notices, and metadata remain available without the
extra JOIN/PART traffic produced by that capability.

## Install

```yaml
dependencies:
  dart_twitch_chat:
    git:
      url: git@github.com:DiegPS/dart_twitch_chat.git
      ref: main
```

## Usage

```dart
import 'package:dart_twitch_chat/dart_twitch_chat.dart';

final client = TwitchChatClient();

final messages = client.messages.listen((message) {
  print('${message.author.name}: ${message.plainText}');
});
final connections = client.connections.listen((update) {
  print(update.state);
});
final failures = client.failures.listen((failure) {
  print('${failure.scope}: ${failure.error}');
});

await client.connect('channel_name');

// Later:
await client.disconnect();
await messages.cancel();
await connections.cancel();
await failures.cancel();
await client.dispose();
```

Channel names may include `#` or `@`; they are normalized to lowercase.
`connect` completes after the WebSocket and JOIN commands are ready. The
`connections` stream reports `connected` only after Twitch confirms the room
with `JOIN` or `ROOMSTATE`.

## Complete event stream

`messages` is the simple, backward-compatible stream. It contains regular chat
plus subscription, resubscription, gift, and anonymous-gift notices. Use
`events` when the application needs everything Twitch sent:

```dart
final events = client.events.listen((event) {
  switch (event) {
    case TwitchMessageEvent(:final message):
      print('${message.id}: ${message.plainText}');
    case TwitchClearMessageEvent(:final targetMessageId):
      print('Delete message $targetMessageId');
    case TwitchClearChatEvent(clearsEntireRoom: true):
      print('Clear the room');
    case TwitchClearChatEvent(:final targetUserId, :final banDuration):
      print('Moderate $targetUserId for $banDuration');
    case TwitchRoomStateEvent(:final slowModeSeconds):
      print('Slow mode: $slowModeSeconds');
    case TwitchUserNoticeEvent(:final notice):
      print('${notice.kind}: ${notice.parameters}');
    case TwitchRawEvent(:final frame):
      print('Unknown ${frame.command}: ${frame.raw}');
    default:
      break;
  }
});
```

Every event owns a `TwitchIrcFrame` containing the original line, unescaped tag
map, prefix, command, positional parameters, and trailing value. New or unknown
data therefore remains available before the package adds a dedicated model.

## Message and notice data

`TwitchChatMessage` includes:

- `id`, `roomId`, server `timestamp`, `clientNonce`, and raw flags.
- Ordered `parts` for text, native/third-party emotes, and Twitch GIFs.
- Author ID, login, display name, color, user type, roles, badge versions, and
  badge metadata.
- Bits, first-message and returning-chatter markers and `/me` action state.
- Typed reply parent/thread data and shared-chat source data.
- `rawTags` and `raw` for forward compatibility.

`TwitchUserNotice` models all currently documented notice kinds, including
subscriptions, gifts, raids, reward gifts, paid upgrades, Bits badge tiers,
shared-chat notices, mod anniversaries, and viewer milestones. Its `parameters`
map preserves every `msg-param-*` value, including values unknown to this
version of the package.

Anonymous IRC does not provide author avatars or authenticated operations such
as sending, deleting, banning, or voting. Those require a separate Twitch API
and credentials, so they are intentionally outside this package's anonymous
scope.

## Optional emotes

Global emotes are loaded independently from BetterTTV, FrankerFaceZ, and 7TV.
Once anonymous IRC supplies `room-id`, the client also loads each provider's
channel catalog. Channel entries override same-named global entries.
Failure or malformed data from one provider never interrupts Twitch chat or
discards results from the others. Failures appear on `failures` with the
`TwitchFailureScope.emotes` scope.

## Testing

```bash
dart test
dart analyze
dart doc --dry-run
```

WebSocket and HTTP transports are injectable. The suite covers connection
confirmation, reconnection, timeouts, fragmented and corrupt data, cleanup,
duplicate avoidance, every modeled IRC command, all documented notice kinds,
rich messages, and optional provider failures without contacting Twitch.

> Twitch's public documentation describes authenticated IRC connections. The
> long-standing `justinfan` anonymous mechanism is used in practice but is not
> a formally guaranteed public contract, so applications should surface
> connection failures cleanly.
