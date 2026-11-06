/**
 * Imported first by each benchmark entry point, so this module evaluates
 * before the engine's own modules: it marks when the page's script started
 * running (after the HTML was parsed and the script compiled).
 */
export const SCRIPT_START_MS = performance.now();

/**
 * Resolves after the next frame has been produced: a task posted from a
 * requestAnimationFrame callback runs once that frame's rendering is done.
 * Falls back after `timeoutMs` when frames are throttled (a hidden WebView
 * produces none), and counts how often that happened.
 */
export let throttledFrames = 0;
export function afterPaint(timeoutMs = 1000): Promise<number> {
  return new Promise((resolve) => {
    let done = false;
    const finish = (throttled: boolean) => {
      if (done) return;
      done = true;
      if (throttled) throttledFrames += 1;
      resolve(performance.now());
    };
    const timer = setTimeout(() => finish(true), timeoutMs);
    requestAnimationFrame(() => {
      const channel = new MessageChannel();
      channel.port1.onmessage = () => {
        clearTimeout(timer);
        finish(false);
      };
      channel.port2.postMessage(null);
    });
  });
}

export const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));
