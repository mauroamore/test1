export function buildStatusRequest(terminalId) {
  return ascii(`${numeric(terminalId, 8)}0s`);
}

export function buildPaymentRequest(request) {
  const amount = request.amountCents;
  if (!Number.isInteger(amount) || amount < 1 || amount > 99999999) {
    throw new RangeError("amountCents must be an integer between 1 and 99999999");
  }

  const paymentType = request.paymentType ?? "generic";
  const paymentTypeCode = paymentType === "debit" ? "1" : paymentType === "credit" ? "2" : "0";
  const cardPresent = request.cardPresent === false ? "1" : "0";
  const text = fixedText(request.text ?? "", 128);

  return ascii(
    numeric(request.terminalId, 8) +
      "0" +
      "P" +
      numeric(request.cashRegisterId, 8) +
      "0" +
      "00" +
      cardPresent +
      paymentTypeCode +
      amount.toString().padStart(8, "0") +
      text +
      "00000000"
  );
}

export function buildPreauthorizationRequest(request) {
  const amount = request.amountCents;
  if (!Number.isInteger(amount) || amount < 1 || amount > 99999999) {
    throw new RangeError("amountCents must be an integer between 1 and 99999999");
  }

  const paymentType = request.paymentType ?? "generic";
  const paymentTypeCode = paymentType === "debit" ? "1" : paymentType === "credit" ? "2" : paymentType === "other" ? "3" : "0";
  const cardPresent = request.cardPresent === true ? "1" : "0";
  const text = fixedText(request.text ?? "", 128);

  return ascii(
    numeric(request.terminalId, 8) +
      "0" +
      "p" +
      numeric(request.cashRegisterId, 8) +
      flag(request.additionalData ?? false) +
      "00" +
      cardPresent +
      paymentTypeCode +
      amount.toString().padStart(8, "0") +
      text +
      "00000000"
  );
}

export function buildReprintTicketRequest({ terminalId, printOnEcr = false, ticketType = "financial" }) {
  const ticketTypeCode = ticketType === "service" ? "1" : "0";
  return ascii(numeric(terminalId, 8) + "0" + "R" + flag(printOnEcr) + ticketTypeCode + "0000000000");
}

export function buildLastResultRequest({ terminalId, cashRegisterId = "00000001", additionalData = false }) {
  return ascii(numeric(terminalId, 8) + "0" + "G" + numeric(cashRegisterId, 8) + flag(additionalData) + "000");
}

export function buildReversalRequest({ terminalId, cashRegisterId = "00000001", stan = "000000", additionalData = false, requireSameCard = false }) {
  return ascii(
    numeric(terminalId, 8) +
      "0" +
      "S" +
      numeric(cashRegisterId, 8) +
      numeric(stan, 6) +
      flag(additionalData) +
      flag(requireSameCard)
  );
}

export function buildTotalsRequest({ terminalId, cashRegisterId = "00000001", additionalData = false }) {
  return ascii(numeric(terminalId, 8) + "0" + "T" + numeric(cashRegisterId, 8) + flag(additionalData) + "0000000");
}

export function buildCloseSessionRequest({ terminalId, cashRegisterId = "00000001", additionalData = false }) {
  return ascii(numeric(terminalId, 8) + "0" + "C" + numeric(cashRegisterId, 8) + flag(additionalData) + "0000000");
}

export function numeric(value, length) {
  const digits = String(value).replace(/\D/g, "") || "0";
  return digits.padStart(length, "0").slice(-length);
}

export function fixedText(value, length) {
  const normalized = String(value).replace(/[^\x20-\x7e]/g, " ");
  return normalized.slice(0, length).padStart(length, " ");
}

function ascii(value) {
  return Buffer.from(value, "ascii");
}

function flag(value) {
  return value ? "1" : "0";
}
