import { browserScheduler, type Scheduler } from './editor/batcher';
import { EditorError, type EditorController } from './editor/controller';
import { type PageRequester, type PendingRequest, RequestError } from './editor/requests';
import {
  type EditorMessageType,
  type EditorToHost,
  type ErrorCode,
  type HostMessageType,
  type LogLevel,
  type PageRequests,
  type PageRequestType,
  type PageResults,
  PROTOCOL_VERSION,
  type ResponsePayload,
} from './protocol/types';
import { parseMessage, validateResult } from './protocol/validate';

export type Send = (raw: string) => void;

interface Pending {
  type: PageRequestType;
  resolve: (result: unknown) => void;
  reject: (error: RequestError) => void;
  timer: unknown;
}

/**
 * The editor end of the bridge. Every host message is validated before it
 * reaches the controller, and every host request is answered with exactly
 * one `response` (ok, or an error code the host can act on).
 *
 * Since Phase 6 W5 the page asks too (`lsp.*`, editor/requests.ts): each
 * request waits for the host's `response`, whose result is checked against
 * the request's type, or times out; a request given up on is cancelled at
 * the host (`lsp.cancel`).
 */
export class Bridge implements PageRequester {
  private seq = 0;
  private controller: EditorController | null = null;
  private readonly pending = new Map<string, Pending>();

  constructor(
    private readonly send: Send,
    private readonly scheduler: Scheduler = browserScheduler,
  ) {}

  attach(controller: EditorController): void {
    this.controller = controller;
  }

  emit<K extends EditorMessageType>(type: K, payload: EditorToHost[K]): void {
    this.post(this.nextId(), type, payload);
  }

  log(level: LogLevel, message: string): void {
    this.emit('editor.log', { level, message: message.slice(0, 4000) });
  }

  request<K extends PageRequestType>(type: K, payload: PageRequests[K], timeoutMs: number): PendingRequest<PageResults[K]> {
    const id = this.nextId();
    const result = new Promise<PageResults[K]>((resolve, reject) => {
      const timer = this.scheduler.set(() => {
        if (this.pending.delete(id)) reject(new RequestError('timeout', `${type} got no answer in time`));
      }, timeoutMs);
      this.pending.set(id, { type, resolve: resolve as (result: unknown) => void, reject, timer });
    });
    this.post(id, type, payload);
    return { id, result };
  }

  cancel(id: string): void {
    const pending = this.pending.get(id);
    if (!pending) return;
    this.pending.delete(id);
    this.scheduler.clear(pending.timer);
    pending.reject(new RequestError('cancelled', `${pending.type} was cancelled`));
    this.emit('lsp.cancel', { re: id });
  }

  /** Requests still waiting for their answer. */
  get waiting(): number {
    return this.pending.size;
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
    if (type === 'response') {
      // An answer to one of the page's requests: nothing answers it.
      this.answer(payload as ResponsePayload);
      return;
    }
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

  private answer(response: ResponsePayload): void {
    const pending = this.pending.get(response.re);
    // Late (timed out or cancelled): dropped.
    if (!pending) return;
    this.pending.delete(response.re);
    this.scheduler.clear(pending.timer);
    if (!response.ok) {
      pending.reject(new RequestError(response.error.code, response.error.message));
      return;
    }
    const problem = validateResult(pending.type, response.result);
    if (problem !== null) {
      this.log('error', `rejected ${pending.type} result: ${problem}`);
      pending.reject(new RequestError('bad_payload', problem));
      return;
    }
    pending.resolve(response.result);
  }

  private nextId(): string {
    this.seq += 1;
    return `e${this.seq}`;
  }

  private post(id: string, type: string, payload: unknown): void {
    this.send(JSON.stringify({ v: PROTOCOL_VERSION, id, type, payload }));
  }

  private reject(re: string, code: ErrorCode, message: string): void {
    this.emit('response', { re, ok: false, error: { code, message: message.slice(0, 2000) } });
  }
}
