# dart_twitch_chat

Anonymous, testable Twitch chat for Dart. It connects directly to Twitch IRC,
requires no OAuth token, and exposes typed messages while preserving the raw IRC
data for forward compatibility.

This first release intentionally reproduces the Twitch behavior extracted from
AirStream. Broader Twitch coverage will be added separately after the migration
is proven stable.

## Features

- Anonymous `justinfan` connection to Twitch IRC over WebSocket.
- IRC tags and commands capabilities.
- `PRIVMSG` chat messages.
- Subscription, resubscription, and gift `USERNOTICE` events.
- Broadcaster, moderator, subscriber, founder, and VIP roles.
- Badge kinds and versions.
- Twitch native emotes with Unicode-safe ranges.
- Global BetterTTV, FrankerFaceZ, and 7TV emotes.
- Automatic reconnect, connection timeout, and `PING`/`PONG` handling.
- Injectable WebSocket and HTTP transports for deterministic tests.
- Original IRC line and tag map on every message.

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

final messageSubscription = client.messages.listen((message) {
  print('${message.author.name}: ${message.plainText}');
});

final connectionSubscription = client.connections.listen((update) {
  print(update.state);
});

final failureSubscription = client.failures.listen((failure) {
  print('${failure.scope}: ${failure.error}');
});

await client.connect('channel_name');

// Later:
await client.disconnect();
await messageSubscription.cancel();
await connectionSubscription.cancel();
await failureSubscription.cancel();
await client.dispose();
```

Channel names may be passed with or without `#` and are normalized to lowercase.

## Message model

`TwitchChatMessage` exposes:

- `id`, `timestamp`, and ordered text/emote `parts`.
- Author display name, login, color, badges, and derived roles.
- Membership event kind and cumulative subscription months.
- `rawTags` and `raw`, so consumers can inspect data not typed yet.

Anonymous IRC does not provide author avatars. Fetching avatars or channel
metadata requires a different public/API source and is deliberately outside this
baseline release.

## Optional emotes

Global emotes are requested independently from BetterTTV, FrankerFaceZ, and 7TV.
A timeout, malformed response, or HTTP error from one provider does not interrupt
chat and does not discard successful results from the others. Such failures are
reported through `TwitchChatClient.failures` with the `emotes` scope.

## Testing

```bash
dart test
dart analyze
```

The socket factory and HTTP client are injectable, so connection, timeout,
reconnection, protocol, corrupt response, and cleanup behavior can be tested
without contacting Twitch or third-party services.
