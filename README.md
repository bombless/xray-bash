# xray-bash

Linux/Bash implementation of [`bombless/xray-powershell`](https://github.com/bombless/xray-powershell).

## Features

- subscription download and parsing
- VMess, VLESS and Trojan nodes
- node list / selection / current-node display
- Xray start, stop, restart and status management
- configuration validation with `xray run -test`
- HTTP proxy test for one node or all nodes
- SOCKS5 on `127.0.0.1:10808`
- HTTP proxy on `127.0.0.1:10809`

## Dependencies

`bash`, `curl`, `jq`, `base64`, and `python3` for URI decoding.

Place the Xray executable at `./xray`, or set `XRAY_PATH`.

## Usage

```bash
chmod +x xray.sh
./xray.sh update 'https://example.com/subscription'
./xray.sh list
./xray.sh select 1
./xray.sh current
./xray.sh status
./xray.sh test 1
./xray.sh test
./xray.sh stop
```

The subscription URL can also be stored in `data/subscription-url.txt`, then run `./xray.sh update`.

`NO_START=1 ./xray.sh select 1` updates the configuration without restarting Xray.

> Note: this is a Bash port of the PowerShell implementation, not a byte-for-byte translation. Linux process management, networking checks and URI decoding use native/Linux-compatible tools.
