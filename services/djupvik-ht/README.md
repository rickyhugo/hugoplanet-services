# djupvik-ht

MQTT client service for receiving sensor data from Shelly BLU H&T devices.

## Building

```sh
zig build
```

## Running

```sh
zig build run
```

## Configuration

Environment variables:

| Variable    | Default     | Description          |
| ----------- | ----------- | -------------------- |
| `MQTT_HOST` | `localhost` | MQTT broker hostname |
| `MQTT_PORT` | `1883`      | MQTT broker port     |

Other settings can be adjusted in the `Config` struct in `src/main.zig`.

## Features

- QoS 1 subscription with proper PUBACK handling
- Automatic reconnection on connection loss
- Keepalive/ping monitoring
- Exhaustive error handling with detailed logging
