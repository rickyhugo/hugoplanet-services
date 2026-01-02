docker run \
  -p 1883:1883 \
  -v "$PWD"/mosquitto/config:/mosquitto/config:ro \
  -v "$PWD"/mosquitto/data:/mosquitto/data:rw \
  -v "$PWD"/mosquitto/log:/mosquitto/log:rw \
  eclipse-mosquitto:2
