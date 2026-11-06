import { EditorError, type EditorController } from './editor/controller';
import {
  type EditorMessageType,
  type EditorToHost,
  type ErrorCode,
  type HostMessageType,
  type LogLevel,
  PROTOCOL_VERSION,
} from './protocol/types';
import { parseMessage } from './protocol/validate';

export type Send = (raw: string) => void;

/**
 * The editor end of the bridge. Every host message is validated before it
 * reaches the controller, and every host request is answered with exactly
 * one `response` (ok, or an error code the host can act on).
 */
export class Bridge {
  private seq = 0;
  private controller: EditorController | null = null;

  constructor(private readonly send: Send) {}

  attach(controller: EditorController): void {
    this.controller = controller;
  }

  emit<K extends EditorMessageType>(type: K, payload: EditorToHost[K]): void {
    this.seq += 1;
    this.send(JSON.stringify({ v: PROTOCOL_VERSION, id: `e${this.seq}`, type, payload }));
  }

  log(level: LogLevel, message: string): void {
    this.emit('editor.log', { level, message: message.slice(0, 4000) });
  }

  receive(raw: unknown): void {
    if (typeof raw !== 'string') {
      this.log('error', 'bridge received a non-string message');
      return;
    }
    const parsed = parseMessage(raw, 'host-to-editor');
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
      this.reject(id, 'internal', 'editor is not ready');
      return;
    }
    try {
      const result = this.controller.handle(type as HostMessageType, payload);
      this.emit('response', result === undefined ? { re: id, ok: true } : { re: id, ok: true, result });
    } catch (error) {
      if (error instanceof EditorError) {
        this.reject(id, error.code, error.message);
      } else {
        this.reject(id, 'internal', error instanceof Error ? error.message : String(error));
      }
    }
  }

  private reject(re: string, code: ErrorCode, message: string): void {
    this.emit('response', { re, ok: false, error: { code, message: message.slice(0, 2000) } });
  }
}
