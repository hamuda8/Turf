import { cli } from '../../zig.mjs';

export const normCity = s => cli('normCity', s);
export const coversAddress = (carrier, address) => cli('coversAddress', carrier, address);
