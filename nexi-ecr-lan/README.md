# nexi-ecr-lan

Node.js/TypeScript client for Nexi ECR-LAN / ECR17 PosConnector amount exchange.

The default LRC mode is `stxetx`, because the tested SmartPOS PosConnector accepted:

```text
Status 00000000 frame: 02 3030303030303030 30 73 03 3D
```

## Usage

```ts
import { NexiEcrClient } from "nexi-ecr-lan";

const pos = new NexiEcrClient({
  host: "192.168.1.240",
  port: 8081,
  terminalId: "37105051",
  cashRegisterId: "00000001",
  lrcMode: "stxetx"
});

const status = await pos.status();

const payment = await pos.pay({
  amountCents: 1,
  text: "TEST SCAMBIO IMPORTO"
});
const preauth = await pos.preauthorize({
  amountCents: 1,
  text: "TEST PREAUTH"
});

const last = await pos.lastResult();
const reconciled = await pos.reconcileLastResult();
const totals = await pos.totals();
const reversal = await pos.reverseLast({ stan: "000000" });
const close = await pos.closeSession();
const reprint = await pos.reprintTicket();
```

## CLI

```bash
node bin/nexi-ecr-lan.js status
node bin/nexi-ecr-lan.js pay
node bin/nexi-ecr-lan.js preauth - - - - 1
node bin/nexi-ecr-lan.js reprint
node bin/nexi-ecr-lan.js status 192.168.1.240 8081 37105051
node bin/nexi-ecr-lan.js pay 192.168.1.240 8081 37105051 00000001 1
node bin/nexi-ecr-lan.js last-result 192.168.1.240 8081 37105051 00000001
node bin/nexi-ecr-lan.js reconcile
node bin/nexi-ecr-lan.js reverse-last 192.168.1.240 8081 37105051 00000001 000000
node bin/nexi-ecr-lan.js totals 192.168.1.240 8081 37105051 00000001
node bin/nexi-ecr-lan.js close 192.168.1.240 8081 37105051 00000001
node bin/nexi-ecr-lan.js diagnostic
```

## Windows batch files

The package includes ready-to-run `.bat` files that use `nexi-ecr-lan.config.json`:

```text
status.bat
pay-1-cent.bat
pay-custom.bat
pay-safe-1-cent.bat
preauth-1-cent.bat
reprint-ticket.bat
pending.bat
list-log.bat
reconcile.bat
diagnostic.bat
last-result.bat
reverse-last.bat
totals.bat
close-session.bat
```

Defaults are read from `nexi-ecr-lan.config.json` in the current directory, or from the package directory:

```json
{
  "host": "192.168.1.240",
  "port": 8081,
  "terminalId": "37105051",
  "cashRegisterId": "00000001",
  "lrcMode": "stxetx"
}
```

## Implemented

- Terminal status request (`s`)
- Payment request (`P`)
- Pre-authorization request (`p`)
- Reprint ticket request (`R`)
- Last result request (`G`)
- Reversal request (`S`)
- Terminal totals request (`T`)
- Close session request (`C`)
- `ACK` / `NAK` packets
- TCP session exchange
- LRC modes: `stxetx`, `std`, `noetx`, `stx`, `zero`

Financial commands must not be blindly retried after a timeout or dropped connection. If a `pay()` call times out or the process crashes while a payment may be in progress, call `lastResult()` before sending any new financial command.
