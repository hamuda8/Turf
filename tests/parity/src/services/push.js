import { cli } from '../../zig.mjs';

export const encryptPayload = (plaintext, keys, testing = {}) => cli('encryptPayload', plaintext, keys, testing);
