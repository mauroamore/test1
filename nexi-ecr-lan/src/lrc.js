/**
 * @typedef {"std" | "noetx" | "stxetx" | "stx" | "zero"} LrcMode
 */

export function xorLrc(bytes, start = 0x7f) {
  let lrc = start;
  for (const byte of bytes) lrc ^= byte;
  return lrc & 0xff;
}

/** @param {Uint8Array} applicationMessage @param {LrcMode} [mode] */
export function computeFrameLrc(applicationMessage, mode = "stxetx") {
  switch (mode) {
    case "noetx":
      return xorLrc(applicationMessage);
    case "stxetx":
      return xorLrc(Buffer.concat([Buffer.from([0x02]), applicationMessage, Buffer.from([0x03])]));
    case "stx":
      return xorLrc(Buffer.concat([Buffer.from([0x02]), applicationMessage]));
    case "zero":
      return xorLrc(Buffer.concat([applicationMessage, Buffer.from([0x03])]), 0x00);
    case "std":
    default:
      return xorLrc(Buffer.concat([applicationMessage, Buffer.from([0x03])]));
  }
}

export function computeControlLrc(controlByte) {
  return xorLrc(Buffer.from([controlByte, 0x03]));
}
