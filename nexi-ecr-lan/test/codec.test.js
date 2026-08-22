import assert from "node:assert/strict";
import { test } from "node:test";
import { encodeControl, encodeFrame, tryDecodePacket } from "../src/codec.js";
import {
  buildCloseSessionRequest,
  buildLastResultRequest,
  buildPaymentRequest,
  buildPreauthorizationRequest,
  buildReprintTicketRequest,
  buildReversalRequest,
  buildStatusRequest,
  buildTotalsRequest
} from "../src/messages.js";

test("encodes SmartPOS-compatible status request with stxetx LRC", () => {
  const frame = encodeFrame(buildStatusRequest("00000000"), "stxetx");
  assert.equal(frame.toString("hex").toUpperCase(), "0230303030303030303073033D");
});

test("encodes preauthorization request as 167 byte application message", () => {
  const message = buildPreauthorizationRequest({
    terminalId: "37105051",
    cashRegisterId: "00000001",
    amountCents: 1,
    text: "TEST PREAUTH"
  });

  assert.equal(message.length, 167);
  assert.equal(message.subarray(0, 10).toString("ascii"), "371050510p");
  assert.equal(message.subarray(10, 18).toString("ascii"), "00000001");
  assert.equal(message.subarray(23, 31).toString("ascii"), "00000001");
});

test("encodes reprint ticket request", () => {
  assert.equal(buildReprintTicketRequest({ terminalId: "37105051" }).toString("ascii"), "371050510R000000000000");
  assert.equal(buildReprintTicketRequest({ terminalId: "37105051", printOnEcr: true, ticketType: "service" }).toString("ascii"), "371050510R110000000000");
});

test("decodes real status response from SmartPOS", () => {
  const raw = Buffer.from("06037A0233373130353035313073303030303030303030303331303732363231323232535953454D5620203230340338", "hex");
  const ack = tryDecodePacket(raw.subarray(0, 3), "stxetx");
  const response = tryDecodePacket(raw.subarray(3), "stxetx");

  assert.equal(ack?.kind, "ack");
  assert.equal(response?.kind, "application");
  assert.equal(response?.applicationMessage.toString("ascii"), "371050510s000000000031072621222SYSEMV  204");
});

test("encodes payment request as 167 byte application message", () => {
  const message = buildPaymentRequest({
    terminalId: "37105051",
    cashRegisterId: "00000001",
    amountCents: 1,
    text: "TEST SCAMBIO IMPORTO"
  });
  const frame = encodeFrame(message, "stxetx");

  assert.equal(message.length, 167);
  assert.equal(message.subarray(0, 10).toString("ascii"), "371050510P");
  assert.equal(message.subarray(10, 18).toString("ascii"), "00000001");
  assert.equal(message.subarray(23, 31).toString("ascii"), "00000001");
  assert.equal(frame[0], 0x02);
  assert.equal(frame[frame.length - 2], 0x03);
});

test("encodes ACK control packet", () => {
  assert.equal(encodeControl(0x06).toString("hex").toUpperCase(), "06037A");
});

test("builds operational command messages", () => {
  assert.equal(buildLastResultRequest({ terminalId: "37105051", cashRegisterId: "1" }).toString("ascii"), "371050510G000000010000");
  assert.equal(buildReversalRequest({ terminalId: "37105051", cashRegisterId: "1" }).toString("ascii"), "371050510S0000000100000000");
  assert.equal(buildTotalsRequest({ terminalId: "37105051", cashRegisterId: "1" }).toString("ascii"), "371050510T0000000100000000");
  assert.equal(buildCloseSessionRequest({ terminalId: "37105051", cashRegisterId: "1" }).toString("ascii"), "371050510C0000000100000000");
});
