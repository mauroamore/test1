import fs from "node:fs";
import path from "node:path";

export class JsonTransactionLog {
  constructor(filePath = "transactions-log.json") {
    this.filePath = path.resolve(filePath);
  }

  list() {
    if (!fs.existsSync(this.filePath)) return [];
    return JSON.parse(fs.readFileSync(this.filePath, "utf8"));
  }

  append(entry) {
    const entries = this.list();
    entries.push({ ...entry, updatedAt: new Date().toISOString() });
    fs.writeFileSync(this.filePath, JSON.stringify(entries, null, 2));
  }

  update(orderId, patch) {
    const entries = this.list();
    const index = entries.findLastIndex((entry) => entry.orderId === orderId);
    if (index < 0) throw new Error(`Transaction not found: ${orderId}`);
    entries[index] = { ...entries[index], ...patch, updatedAt: new Date().toISOString() };
    fs.writeFileSync(this.filePath, JSON.stringify(entries, null, 2));
  }

  findPending() {
    return this.list().filter((entry) => entry.status === "pending" || entry.status === "uncertain");
  }
}
