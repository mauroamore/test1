import net from "node:net";
import { ACK, encodeControl, encodeFrame, tryDecodePacket } from "./codec.js";
import { EcrConnectionError, EcrTimeoutError } from "./errors.js";

export class EcrSession {
  constructor(options) {
    this.options = options;
    this.lrcMode = options.lrcMode ?? "stxetx";
  }

  async exchange(applicationMessage, options = {}) {
    const socket = await this.connect();
    const packets = [];
    const timeoutMs = options.timeoutMs ?? this.options.responseTimeoutMs ?? 30_000;

    try {
      socket.write(encodeFrame(applicationMessage, this.lrcMode));

      while (true) {
        const packet = await readPacket(socket, this.lrcMode, timeoutMs);
        packets.push(packet);

        if (packet.kind === "nak") return packets;
        if (packet.kind === "application") {
          if (options.acknowledgeApplicationResponse ?? true) socket.write(encodeControl(ACK));
          return packets;
        }
      }
    } finally {
      socket.destroy();
    }
  }

  connect() {
    return new Promise((resolve, reject) => {
      const socket = net.createConnection({ host: this.options.host, port: this.options.port });
      const timer = setTimeout(() => {
        socket.destroy();
        reject(new EcrTimeoutError("ECR connection timeout"));
      }, this.options.connectTimeoutMs ?? 5_000);

      socket.once("connect", () => {
        clearTimeout(timer);
        resolve(socket);
      });
      socket.once("error", (error) => {
        clearTimeout(timer);
        reject(new EcrConnectionError(error.message, { cause: error }));
      });
    });
  }
}

function readPacket(socket, lrcMode, timeoutMs) {
  return new Promise((resolve, reject) => {
    let buffer = Buffer.alloc(0);
    const timer = setTimeout(cleanupReject, timeoutMs, new EcrTimeoutError("ECR response timeout"));

    function cleanup() {
      clearTimeout(timer);
      socket.off("data", onData);
      socket.off("error", cleanupReject);
      socket.off("close", onClose);
    }

    function cleanupReject(error) {
      cleanup();
      reject(error);
    }

    function onClose() {
      cleanupReject(new EcrConnectionError("ECR socket closed before a complete packet"));
    }

    function onData(chunk) {
      buffer = Buffer.concat([buffer, chunk]);
      const packet = tryDecodePacket(buffer, lrcMode);
      if (packet) {
        cleanup();
        resolve(packet);
      }
    }

    socket.on("data", onData);
    socket.once("error", cleanupReject);
    socket.once("close", onClose);
  });
}
