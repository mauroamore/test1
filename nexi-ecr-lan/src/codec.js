import { computeControlLrc, computeFrameLrc } from "./lrc.js";

export const STX = 0x02;
export const ETX = 0x03;
export const EOT = 0x04;
export const ACK = 0x06;
export const NAK = 0x15;
export const SOH = 0x01;

export function encodeFrame(applicationMessage, lrcMode = "stxetx") {
  const message = Buffer.from(applicationMessage);
  return Buffer.concat([
    Buffer.from([STX]),
    message,
    Buffer.from([ETX, computeFrameLrc(message, lrcMode)])
  ]);
}

export function encodeControl(controlByte) {
  return Buffer.from([controlByte, ETX, computeControlLrc(controlByte)]);
}

export function tryDecodePacket(raw, lrcMode = "stxetx") {
  if (raw.length < 1) return null;

  if ((raw[0] === ACK || raw[0] === NAK) && raw.length >= 3 && raw[1] === ETX) {
    const expected = computeControlLrc(raw[0]);
    return {
      kind: raw[0] === ACK ? "ack" : "nak",
      raw: raw.subarray(0, 3),
      lrcValid: raw[2] === expected
    };
  }

  if (raw[0] === STX) {
    const etxIndex = raw.indexOf(ETX, 1);
    if (etxIndex < 0 || etxIndex + 1 >= raw.length) return null;
    const applicationMessage = raw.subarray(1, etxIndex);
    const expected = computeFrameLrc(applicationMessage, lrcMode);
    return {
      kind: "application",
      raw: raw.subarray(0, etxIndex + 2),
      applicationMessage,
      lrcValid: raw[etxIndex + 1] === expected
    };
  }

  if (raw[0] === SOH) {
    const eotIndex = raw.indexOf(EOT, 1);
    if (eotIndex < 0) return null;
    return { kind: "progress", raw: raw.subarray(0, eotIndex + 1) };
  }

  return { kind: "unknown", raw };
}
