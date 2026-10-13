import { cli } from '../../zig.mjs';

export const parseRange = (from, to) => cli('parseRange', from, to);
