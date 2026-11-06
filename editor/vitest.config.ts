import { defineConfig } from 'vitest/config';

export default defineConfig({
  define: { __ENGINE_VERSION__: JSON.stringify('test') },
  test: {
    environment: 'happy-dom',
    include: ['test/**/*.test.ts', 'test/**/*.test.mjs'],
  },
});
