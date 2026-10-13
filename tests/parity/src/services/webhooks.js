import { cli } from '../../zig.mjs';

export const isPrivateIp = ip => cli('isPrivateIp', ip);
