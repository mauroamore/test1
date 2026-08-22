export { encodeControl, encodeFrame, tryDecodePacket, ACK, NAK, STX, ETX, SOH, EOT } from "./codec.js";
export { NexiEcrClient } from "./client.js";
export {
  buildCloseSessionRequest,
  buildLastResultRequest,
  buildPaymentRequest,
  buildPreauthorizationRequest,
  buildReprintTicketRequest,
  buildReversalRequest,
  buildStatusRequest,
  buildTotalsRequest,
  fixedText,
  numeric
} from "./messages.js";
export { computeControlLrc, computeFrameLrc, xorLrc } from "./lrc.js";
export { parseGenericResult, parsePaymentResult, parseStatusResponse, parseTotalsResult } from "./parser.js";
export { EcrSession } from "./session.js";
export { EcrConnectionError, EcrError, EcrNakError, EcrProtocolError, EcrTimeoutError } from "./errors.js";
export { JsonTransactionLog } from "./transaction-log.js";
export { createDiagnosticReport } from "./diagnostics.js";
