import { cli } from '../zig.mjs';

export const code128Svg = text => cli('code128Svg', text);
