export class EcrError extends Error {
  constructor(message, details = {}) {
    super(message);
    this.name = new.target.name;
    this.details = details;
  }
}

export class EcrNakError extends EcrError {}
export class EcrTimeoutError extends EcrError {}
export class EcrConnectionError extends EcrError {}
export class EcrProtocolError extends EcrError {}
