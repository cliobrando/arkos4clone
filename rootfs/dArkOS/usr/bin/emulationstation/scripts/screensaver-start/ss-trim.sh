#!/bin/sh
# ES waits for event scripts: hand over to systemd and return at once
sudo -n systemctl start --no-block ss-trim.service
