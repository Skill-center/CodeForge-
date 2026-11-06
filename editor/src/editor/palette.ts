import type { Palette } from '../protocol/types';

/**
 * Fallback palette = the app's dark CfColors tokens. The host always sends
 * its own palette (from CfColors, contrast-tested in Dart); this default only
 * serves standalone pages such as the benchmark harness.
 */
export const DEFAULT_PALETTE: Palette = {
  dark: true,
  background: '#0F1115',
  foreground: '#E8EAF0',
  gutterBackground: '#0F1115',
  gutterForeground: '#9AA1B0',
  activeLine: '#161920',
  selection: '#FF7A4540',
  cursor: '#FF7A45',
  matchingBracket: '#39404D',
  searchMatch: '#FBBF2440',
  panelBackground: '#161920',
  border: '#262B35',
  syntax: {
    keyword: '#C792EA',
    string: '#A5D6A7',
    number: '#F78C6C',
    function: '#82AAFF',
    type: '#FFCB6B',
    comment: '#8A93A6',
    operator: '#89DDFF',
  },
};
