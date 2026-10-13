import { cli } from '../../zig.mjs';

export const rowToBody = (row, merchant) => cli('rowToBody', row, merchant);
