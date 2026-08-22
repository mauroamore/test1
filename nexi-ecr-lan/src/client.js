import {
  buildCloseSessionRequest,
  buildLastResultRequest,
  buildPaymentRequest,
  buildPreauthorizationRequest,
  buildReprintTicketRequest,
  buildReversalRequest,
  buildStatusRequest,
  buildTotalsRequest
} from "./messages.js";
import { parseGenericResult, parsePaymentResult, parseStatusResponse, parseTotalsResult } from "./parser.js";
import { EcrSession } from "./session.js";
import { EcrConnectionError, EcrNakError, EcrProtocolError, EcrTimeoutError } from "./errors.js";
import { JsonTransactionLog } from "./transaction-log.js";

export class NexiEcrClient {
  constructor(options) {
    this.options = options;
  }

  async status() {
    const session = new EcrSession(this.options);
    const packets = await session.exchange(buildStatusRequest(this.options.terminalId), { timeoutMs: 10_000 });
    const application = packets.find((packet) => packet.kind === "application");
    if (!application) throw new Error(`Status did not return application response: ${packets.at(-1)?.kind ?? "none"}`);
    return parseStatusResponse(application.applicationMessage);
  }

  async pay(request) {
    const session = new EcrSession(this.options);
    const packets = await session.exchange(
      buildPaymentRequest({
        ...request,
        terminalId: this.options.terminalId,
        cashRegisterId: request.cashRegisterId ?? this.options.cashRegisterId ?? "00000001"
      }),
      { timeoutMs: this.options.responseTimeoutMs ?? 120_000 }
    );
    const application = packets.findLast((packet) => packet.kind === "application");
    if (!application) throw new Error(`Payment did not return application response: ${packets.at(-1)?.kind ?? "none"}`);
    return parsePaymentResult(application.applicationMessage);
  }

  async paySafe({ orderId, amountCents, text = "", cashRegisterId } = {}) {
    if (!orderId) throw new Error("orderId is required for paySafe");
    if (!Number.isInteger(amountCents) || amountCents < 1) throw new Error("amountCents must be an integer >= 1");
    const log = new JsonTransactionLog(this.options.transactionLogPath);
    const pending = log.findPending();
    if (pending.length > 0) {
      throw new EcrProtocolError("There are pending/uncertain transactions; reconcile with lastResult before paying", { pending });
    }

    log.append({
      orderId,
      amountCents,
      terminalId: this.options.terminalId,
      cashRegisterId: cashRegisterId ?? this.options.cashRegisterId ?? "00000001",
      status: "pending",
      createdAt: new Date().toISOString()
    });

    try {
      const result = await this.pay({ amountCents, text, cashRegisterId });
      log.update(orderId, { status: result.ok ? "approved" : "declined", result });
      return result;
    } catch (error) {
      if (error instanceof EcrTimeoutError || error instanceof EcrConnectionError || error instanceof EcrProtocolError) {
        log.update(orderId, { status: "uncertain", error: error.message });
      } else {
        log.update(orderId, { status: "failed", error: error instanceof Error ? error.message : String(error) });
      }
      throw error;
    }
  }

  async reconcileLastResult() {
    const log = new JsonTransactionLog(this.options.transactionLogPath);
    const pending = log.findPending();
    const result = await this.lastResult();

    if (pending.length === 0) {
      return { reconciled: false, reason: "no pending transactions", result };
    }

    const entry = pending.at(-1);
    log.update(entry.orderId, {
      status: result.ok ? "approved" : "declined",
      reconciledAt: new Date().toISOString(),
      result
    });

    return { reconciled: true, orderId: entry.orderId, result };
  }

  async lastResult(options = {}) {
    const application = await this.exchangeForApplication(
      buildLastResultRequest({
        terminalId: this.options.terminalId,
        cashRegisterId: options.cashRegisterId ?? this.options.cashRegisterId ?? "00000001",
        additionalData: options.additionalData ?? false
      }),
      30_000
    );
    return parsePaymentResult(application);
  }

  async preauthorize(request) {
    const application = await this.exchangeForApplication(
      buildPreauthorizationRequest({
        ...request,
        terminalId: this.options.terminalId,
        cashRegisterId: request.cashRegisterId ?? this.options.cashRegisterId ?? "00000001"
      }),
      this.options.responseTimeoutMs ?? 120_000
    );
    return parsePaymentResult(application);
  }

  async reprintTicket(options = {}) {
    const application = await this.exchangeForApplication(
      buildReprintTicketRequest({
        terminalId: this.options.terminalId,
        printOnEcr: options.printOnEcr ?? false,
        ticketType: options.ticketType ?? "financial"
      }),
      30_000
    );
    return parseGenericResult(application);
  }

  async reverseLast(options = {}) {
    const application = await this.exchangeForApplication(
      buildReversalRequest({
        terminalId: this.options.terminalId,
        cashRegisterId: options.cashRegisterId ?? this.options.cashRegisterId ?? "00000001",
        stan: options.stan ?? "000000",
        additionalData: options.additionalData ?? false,
        requireSameCard: options.requireSameCard ?? false
      }),
      120_000
    );
    return parsePaymentResult(application);
  }

  async totals(options = {}) {
    const application = await this.exchangeForApplication(
      buildTotalsRequest({
        terminalId: this.options.terminalId,
        cashRegisterId: options.cashRegisterId ?? this.options.cashRegisterId ?? "00000001",
        additionalData: options.additionalData ?? false
      }),
      30_000
    );
    return parseTotalsResult(application);
  }

  async closeSession(options = {}) {
    const application = await this.exchangeForApplication(
      buildCloseSessionRequest({
        terminalId: this.options.terminalId,
        cashRegisterId: options.cashRegisterId ?? this.options.cashRegisterId ?? "00000001",
        additionalData: options.additionalData ?? false
      }),
      60_000
    );
    return parseGenericResult(application);
  }

  async exchangeForApplication(applicationMessage, timeoutMs) {
    const session = new EcrSession(this.options);
    const packets = await session.exchange(applicationMessage, { timeoutMs });
    const last = packets.at(-1);
    if (last?.kind === "nak") throw new EcrNakError("POS returned NAK", { packet: last });
    const application = packets.findLast((packet) => packet.kind === "application");
    if (!application) throw new EcrProtocolError(`Command did not return application response: ${last?.kind ?? "none"}`, { packets });
    return application.applicationMessage;
  }
}
