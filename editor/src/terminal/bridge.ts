import { NO_RESPONSE, TerminalPageError, type TerminalController } from './controller';
import {
  type HostTerminalType,
  type LogLevel,
  TERMINAL_PROTOCOL_VERSION,
  type TerminalErrorCode,
  type TerminalMessageType,
  type TerminalToHost,
} from './protocol';
import { parseTerminalMessage } from './validate';

export type Send = (raw: string) => void;

/**
 * The terminal page's end of the bridge. Every host message is validated
 * before it reaches the controller. Every request is answered with exactly
 * one `response`, except a `session.write` that the page accepts: its
 * `session.ack` follows once xterm.js has parsed it.
 */
export class TerminalBridge {
  private seq = 0;
  private controller: TerminalController | null = null;

  constructor(private readonly send: Send) {}

  attach(controller: TerminalController): void {
    this.controller = controller;
  }

  emit<K extends TerminalMessageType>(type: K, payload: TerminalToHost[K]): void {
    this.seq += 1;
    this.send(JSON.stringify({ v: TERMINAL_PROTOCOL_VERSION, id: `t${this.seq}`, type, payload }));
  }

  log(level: LogLevel, message: string): void {
    this.emit('terminal.log', { level, message: message.slice(0, 4000) });
  }

  receive(raw: unknown): void {
    if (typeof raw !== 'string') {
      this.log('error', 'bridge received a non-string message');
      return;
    }
    const parsed = parseTerminalMessage(raw, 'host-to-terminal');
    if (!parsed.ok) {
      if (parsed.id !== null) {
        this.reject(parsed.id, parsed.code, parsed.message);
      } else {
        this.log('error', `rejected host message (${parsed.code}): ${parsed.message}`);
      }
      return;
    }
    const { id, type, payload } = parsed.message;
    if (this.controller === null) {
      this.reject(id, 'internal', 'the terminal is not ready');
      return;
    }
    try {
      const result = this.controller.handle(type as HostTerminalType, payload);
      if (result === NO_RESPONSE) return;
      this.emit('response', result === undefined ? { re: id, ok: true } : { re: id, ok: true, result });
    } catch (error) {
      if (error instanceof TerminalPageError) {
        this.reject(id, error.code, error.message);
      } else {
        this.reject(id, 'internal', error instanceof Error ? error.message : String(error));
      }
    }
  }

  private reject(re: string, code: TerminalErrorCode, message: string): void {
    this.emit('response', { re, ok: false, error: { code, message: message.slice(0, 2000) } });
  }
}
