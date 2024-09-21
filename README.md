## node_exporter hosts up script

This is a quick and dirty script to check if a host that runs node_exporter can ping other hosts  

The main goal of this script is to check VPN peer availability from the host.

## Setup

Download file `hosts_up.sh`:

```
cd /usr/local/bin && curl -OL https://raw.githubusercontent.com/netinvent/node_exporter_hosts_up/main/hosts_up.sh && chmod +x /usr/local/bin/hosts_up.sh
```

Create file `/etc/hosts_up.conf` containing the following
Change hosts to whatever you need

```
#/usr/bin/env bash

# hosts_up.sh configuration file
# see https://github.com/netinvent/node_exporter_hosts_up

# Operations are run in parallel
# Keep in mind that PING_INTERVAL * RETRIES * TIMEOUT should not exceed your prometheus scrape interval
PING_INTERVAL=.2
PING_RETRIES=3
PING_TIMEOUT=2

NODE_EXPORTER_TEXT_COLLECTOR_DIR="/var/lib/node_exporter/textfile_collector"
PROM_FILE="hosts_up.prom"
LOG_FILE=""
#LOG_FILE="/var/log/hosts_up.log" # Optional log file



declare -a ping_hosts=(kernel.org 1.1.1.1 9.9.9.9 linux.org)
```

## Create a cron entry with the following

```
echo "* * * * * root /usr/local/bin/hosts_up.sh --config=/etc/hosts_up.conf
```

## node_exporter remarks

Note that node_exporter needs to have plugin `text_collector` enabled.  
You can check your systemd service file which should look like
```
ExecStart=/usr/local/bin/node_exporter --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
```