export function parseStatusResponse(applicationMessage) {
  const raw = applicationMessage.toString("ascii");
  return {
    terminalId: raw.slice(0, 8),
    messageCode: raw.slice(9, 10),
    raw
  };
}

export function parsePaymentResult(applicationMessage) {
  const raw = applicationMessage.toString("ascii");
  const resultCode = raw.length >= 12 ? raw.slice(10, 12) : undefined;
  return {
    terminalId: raw.slice(0, 8),
    messageCode: raw.slice(9, 10),
    resultCode,
    ok: resultCode === "00",
    description: resultCode === "01" ? raw.slice(12, 36).trim() : undefined,
    stan: raw.length >= 65 ? raw.slice(59, 65) : undefined,
    actionCode: raw.length >= 74 ? raw.slice(71, 74) : undefined,
    raw
  };
}

export function parseGenericResult(applicationMessage) {
  const raw = applicationMessage.toString("ascii");
  const resultCode = raw.length >= 12 ? raw.slice(10, 12) : undefined;
  return {
    terminalId: raw.slice(0, 8),
    messageCode: raw.slice(9, 10),
    resultCode,
    ok: resultCode === "00",
    description: resultCode === "01" ? raw.slice(12, 36).trim() : undefined,
    raw
  };
}

export function parseTotalsResult(applicationMessage) {
  const raw = applicationMessage.toString("ascii");
  const resultCode = raw.length >= 12 ? raw.slice(10, 12) : undefined;
  return {
    terminalId: raw.slice(0, 8),
    messageCode: raw.slice(9, 10),
    resultCode,
    ok: resultCode === "00",
    eftPosTotalCents: resultCode === "00" ? Number.parseInt(raw.slice(12, 28), 10) : undefined,
    hostTotalCents: resultCode === "00" && raw.length >= 44 ? Number.parseInt(raw.slice(28, 44), 10) : undefined,
    description: resultCode === "01" ? raw.slice(12, 31).trim() : undefined,
    raw
  };
}
